#if canImport(SwiftUI)
import Foundation
import SwiftUI
import NovelKit

#if canImport(Security)
import Security
#endif

/// Keychain wrapper so the AI API key never lands in a plain JSON file.
enum Keychain {
    static let service = "com.yang.NovelReader"

    static func set(_ value: String, for account: String) {
        #if canImport(Security)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
        #endif
    }

    static func get(_ account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
        #else
        return nil
        #endif
    }

    static func delete(_ account: String) {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}

enum SearchState: Equatable {
    case idle
    case searching(String)
    case finished(count: Int, failed: [String])
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var books: [Book] = []
    @Published var sources: [BookSource] = []
    @Published var searchState: SearchState = .idle
    @Published var searchResults: [SearchResult] = []
    @Published var banner: (text: String, isError: Bool)?

    let store: LibraryStore
    private var client: HTTPClient

    init(store: LibraryStore = LibraryStore()) {
        self.store = store

        var loaded = AppSettings()
        loaded.ai.apiKey = Keychain.get("ai.apiKey") ?? ""
        // Settings are loaded asynchronously in bootstrap(); this placeholder only
        // carries the API key so the first launch is not blocked by disk IO.
        _settings = Published(initialValue: loaded)
        self.client = HTTPClient(settings: loaded.network)
    }

    var engine: SourceEngine {
        SourceEngine(client: client) { [weak self] message in
            Task { @MainActor in
                self?.showBanner(message, isError: false)
            }
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        var loaded = await store.loadSettings()
        loaded.ai.apiKey = Keychain.get("ai.apiKey") ?? ""
        settings = loaded
        client = HTTPClient(settings: loaded.network)
        books = await store.loadBooks()
        sources = await store.loadSources()

        if sources.isEmpty {
            sources = [BuiltinContent.sampleSource] + BuiltinContent.presetSources
            await store.saveSources(sources)
            await store.setFlag("presetSourcesSeeded")
            await store.setFlag(BuiltinContent.presetVersionFlag)
        } else {
            if !(await store.isFlagSet("presetSourcesSeeded")) {
                // Fill in presets exactly once, for installs that predate them.
                let existing = Set(sources.map(\.id))
                let missing = BuiltinContent.presetSources.filter { !existing.contains($0.id) }
                if !missing.isEmpty {
                    sources.append(contentsOf: missing)
                    await store.saveSources(sources)
                }
                await store.setFlag("presetSourcesSeeded")
                await store.setFlag(BuiltinContent.presetVersionFlag)
            }
            await migratePresetsIfNeeded()
        }
        if books.isEmpty {
            await seedSampleBook()
        }
        Task { await repairBooksAfterPresetMigration() }
    }

    /// Presets are replaced when the bundled set changes (for example when a
    /// site starts hiding chapters behind a paywall). Sources the user imported
    /// themselves have random IDs and are never touched.
    private func migratePresetsIfNeeded() async {
        guard !(await store.isFlagSet(BuiltinContent.presetVersionFlag)) else { return }

        // Preset IDs are reused across generations (an old build's "b5200" and
        // this build's "得奇" share `…-001`), so replace by ID instead of
        // assuming an ID match means the source is still correct.
        sources.removeAll { BuiltinContent.isPresetID($0.id) }
        sources.append(contentsOf: BuiltinContent.presetSources)

        await store.saveSources(sources)
        await store.setFlag(BuiltinContent.presetVersionFlag)
    }

    /// Books added from a preset keep only the source's ID and the detail URL,
    /// so when a preset is swapped for a different site those shelf entries end
    /// up pointing at a dead host. Re-resolve them against the new preset,
    /// matching by title (and author when known) so progress survives.
    ///
    /// Runs once per preset generation, in the background: it only touches
    /// books whose host no longer matches their source.
    private func repairBooksAfterPresetMigration() async {
        let flag = "presetBooksRepairedV2"
        guard !(await store.isFlagSet(flag)) else { return }

        for book in books {
            guard BuiltinContent.isPresetID(book.sourceID),
                  let source = sources.first(where: { $0.id == book.sourceID }),
                  let staleHost = URL(string: book.detailURL)?.host,
                  let sourceHost = URL(string: source.baseURL)?.host,
                  staleHost != sourceHost else { continue }

            let matches = (try? await engine.search(keyword: book.name, source: source)) ?? []
            guard let hit = matches.first(where: { result in
                guard result.name == book.name else { return false }
                guard !book.author.isEmpty, !result.author.isEmpty else { return true }
                return result.author.contains(book.author) || book.author.contains(result.author)
            }) else { continue }

            _ = try? await switchSource(of: book, to: hit)
        }

        await store.setFlag(flag)
    }

    private func seedSampleBook() async {
        guard let sourceIndex = sources.firstIndex(where: { $0.id == BuiltinContent.sampleSourceID }) else { return }
        sources[sourceIndex].enabled = true
        await store.saveSources(sources)

        let book = BuiltinContent.sampleBook
        books = [book]
        await store.saveBooks(books)
        await store.saveChapters(BuiltinContent.sampleChapters, bookID: book.id)
        for (index, chapter) in BuiltinContent.sampleChapters.enumerated() {
            if let text = BuiltinContent.content(forChapterAt: index) {
                await store.saveContent(
                    ChapterContent(chapterURL: chapter.url, text: TextProcessing.cleanupChapterText(text)),
                    bookID: book.id
                )
            }
        }
    }

    // MARK: - Settings

    func saveSettings() {
        var persisted = settings
        persisted.ai.apiKey = ""
        if settings.ai.apiKey.isEmpty {
            Keychain.delete("ai.apiKey")
        } else {
            Keychain.set(settings.ai.apiKey, for: "ai.apiKey")
        }
        let snapshot = persisted
        Task { await store.saveSettings(snapshot) }
        client.update(settings: settings.network)
    }

    // MARK: - Sources

    @discardableResult
    func importSources(fromJSON text: String) -> (added: Int, warnings: [String]) {
        do {
            let result = try LegadoImporter.importSources(fromJSON: text)
            var existingURLs = Set(sources.map { $0.baseURL })
            var added = 0
            for var source in result.sources {
                if existingURLs.contains(source.baseURL) {
                    // Refresh the existing entry instead of duplicating the site.
                    if let index = sources.firstIndex(where: { $0.baseURL == source.baseURL }) {
                        source.id = sources[index].id
                        source.isBuiltIn = sources[index].isBuiltIn
                        sources[index] = source
                    }
                } else {
                    sources.append(source)
                    existingURLs.insert(source.baseURL)
                    added += 1
                }
            }
            persistSources()
            return (added, result.warnings)
        } catch {
            return (0, [error.localizedDescription])
        }
    }

    @discardableResult
    func importSources(from data: Data) -> (added: Int, warnings: [String]) {
        do {
            let result = try LegadoImporter.importSources(from: data)
            var existingURLs = Set(sources.map { $0.baseURL })
            var added = 0
            for var source in result.sources {
                if existingURLs.contains(source.baseURL) {
                    if let index = sources.firstIndex(where: { $0.baseURL == source.baseURL }) {
                        source.id = sources[index].id
                        source.isBuiltIn = sources[index].isBuiltIn
                        sources[index] = source
                    }
                } else {
                    sources.append(source)
                    existingURLs.insert(source.baseURL)
                    added += 1
                }
            }
            persistSources()
            return (added, result.warnings)
        } catch {
            return (0, [error.localizedDescription])
        }
    }

    func upsert(_ source: BookSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        persistSources()
    }

    func deleteSource(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        persistSources()
    }

    func toggleSourceEnabled(_ source: BookSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].enabled.toggle()
        persistSources()
    }

    private func persistSources() {
        let snapshot = sources
        Task { await store.saveSources(snapshot) }
    }

    func source(for book: Book) -> BookSource? {
        sources.first { $0.id == book.sourceID }
    }

    // MARK: - Search

    func search(_ keyword: String) async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        searchState = .searching(query)
        searchResults = []

        let available = sources.filter { $0.enabled && $0.type == .text && ($0.canSearch || $0.isBuiltIn) }
        let active = settings.searchAllSources ? available : Array(available.prefix(1))
        guard !active.isEmpty else {
            searchState = .failed("没有可用的书源，请先在「书源」里导入")
            return
        }

        var collected: [SearchResult] = []
        var failures: [String] = []

        await withTaskGroup(of: (String, Result<[SearchResult], Error>).self) { group in
            for source in active {
                let engine = self.engine
                group.addTask {
                    if source.isBuiltIn {
                        let sample = BuiltinContent.sampleBook
                        if sample.name.contains(query) || sample.author.contains(query) {
                            let result = SearchResult(
                                sourceID: source.id,
                                sourceName: source.name,
                                name: sample.name,
                                author: sample.author,
                                intro: sample.intro,
                                detailURL: sample.detailURL
                            )
                            return (source.name, .success([result]))
                        }
                        return (source.name, .success([]))
                    }
                    do {
                        let results = try await engine.search(keyword: query, source: source)
                        return (source.name, .success(results))
                    } catch {
                        return (source.name, .failure(error))
                    }
                }
            }

            for await (name, result) in group {
                switch result {
                case .success(let results): collected.append(contentsOf: results)
                case .failure: failures.append(name)
                }
            }
        }

        // Prefer exact / prefix title matches.
        collected.sort { lhs, rhs in
            let lhsExact = lhs.name == query ? 0 : (lhs.name.contains(query) ? 1 : 2)
            let rhsExact = rhs.name == query ? 0 : (rhs.name.contains(query) ? 1 : 2)
            if lhsExact != rhsExact { return lhsExact < rhsExact }
            return lhs.name < rhs.name
        }
        searchResults = collected
        searchState = .finished(count: collected.count, failed: failures)
    }

    // MARK: - Shelf

    func bookOnShelf(for result: SearchResult) -> Book? {
        books.first { $0.sourceID == result.sourceID && $0.detailURL == result.detailURL }
    }

    func addToShelf(_ result: SearchResult) async throws -> Book {
        if let existing = bookOnShelf(for: result) { return existing }
        guard let source = sources.first(where: { $0.id == result.sourceID }) else {
            throw SourceError.notFound("找不到对应的书源")
        }

        var book: Book
        var chapters: [Chapter] = []

        if source.isBuiltIn {
            book = BuiltinContent.sampleBook
            chapters = BuiltinContent.sampleChapters
        } else {
            book = try await engine.fetchBookDetail(result, source: source)
            chapters = try await engine.fetchChapters(book: book, source: source)
        }

        if let existing = books.first(where: { $0.sourceID == book.sourceID && $0.detailURL == book.detailURL }) {
            return existing
        }

        books.append(book)
        let snapshot = books
        let chapterSnapshot = chapters
        let bookID = book.id
        Task {
            await store.saveBooks(snapshot)
            await store.saveChapters(chapterSnapshot, bookID: bookID)
        }
        return book
    }

    func removeFromShelf(_ book: Book) {
        books.removeAll { $0.id == book.id }
        let snapshot = books
        Task {
            await store.saveBooks(snapshot)
            await store.clearChapterCache(bookID: book.id)
        }
    }

    func updateProgress(bookID: UUID, chapterIndex: Int, chapterTitle: String, characterOffset: Int = 0) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].progress = ReadingProgress(
            chapterIndex: chapterIndex,
            characterOffset: characterOffset,
            chapterTitle: chapterTitle,
            updatedAt: Date()
        )
        books[index].lastReadAt = Date()
        let snapshot = books
        Task { await store.saveBooks(snapshot) }
    }

    // MARK: - Reading

    func chapters(for book: Book, forceReload: Bool = false) async throws -> [Chapter] {
        if !forceReload, let cached = await store.loadChapters(bookID: book.id), !cached.isEmpty {
            return cached
        }
        guard let source = sources.first(where: { $0.id == book.sourceID }) else {
            throw SourceError.notFound("书源已被删除，无法加载目录")
        }
        let chapters: [Chapter]
        if source.isBuiltIn {
            chapters = BuiltinContent.sampleChapters
        } else {
            chapters = try await engine.fetchChapters(book: book, source: source)
        }
        await store.saveChapters(chapters, bookID: book.id)
        return chapters
    }

    func chapterContent(book: Book, chapter: Chapter) async throws -> ChapterContent {
        if let cached = await store.loadContent(bookID: book.id, chapterURL: chapter.url) {
            return cached
        }
        let content: ChapterContent
        if chapter.url.hasPrefix("local://") {
            let index = chapter.index
            guard let text = BuiltinContent.content(forChapterAt: index) else {
                throw SourceError.emptyContent("示例章节不存在")
            }
            content = ChapterContent(chapterURL: chapter.url, text: TextProcessing.cleanupChapterText(text))
        } else {
            guard let source = sources.first(where: { $0.id == book.sourceID }) else {
                throw SourceError.notFound("书源已被删除")
            }
            content = try await engine.fetchContent(book: book, chapter: chapter, source: source)
        }
        await store.saveContent(content, bookID: book.id)
        return content
    }

    func aiClean(_ content: ChapterContent, task: AIPrompt.ChapterTask, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ChapterContent {
        guard settings.ai.isUsable else { throw AIError.notConfigured }
        let client = AIClient(configuration: settings.ai)
        let cleaned = try await client.cleanChapter(
            content.text,
            instruction: task,
            customInstruction: settings.ai.customInstruction,
            progress: progress
        )
        let result = ChapterContent(
            chapterURL: content.chapterURL,
            text: TextProcessing.cleanupChapterText(cleaned),
            cleaned: true
        )
        return result
    }

    func persistContent(_ content: ChapterContent, for book: Book) {
        let bookID = book.id
        Task { await store.saveContent(content, bookID: bookID) }
    }

    func summarizeIntro(_ book: Book) async -> String? {
        guard settings.ai.isUsable, !book.intro.isEmpty else { return nil }
        let client = AIClient(configuration: settings.ai)
        let system = "你是一个图书简介整理助手。把用户给的小说简介整理成 3-5 句通顺的中文，去掉广告和网址，不要剧透结局，不要添加原文没有的信息。只输出整理后的简介。"
        return try? await client.chat(system: system, user: book.intro)
    }

    // MARK: - Switching sources

    /// Searches every other enabled source for the same book, so a chapter that
    /// the current site refuses to serve can be read somewhere else.
    func alternatives(for book: Book) async -> [SearchResult] {
        let query = book.name
        guard !query.isEmpty else { return [] }
        let candidates = sources.filter { $0.enabled && $0.type == .text && $0.canSearch && $0.id != book.sourceID && !$0.isBuiltIn }

        var collected: [SearchResult] = []
        await withTaskGroup(of: [SearchResult].self) { group in
            for source in candidates {
                let engine = self.engine
                group.addTask {
                    (try? await engine.search(keyword: query, source: source)) ?? []
                }
            }
            for await results in group {
                collected.append(contentsOf: results)
            }
        }

        // Keep only plausible matches: same title, and the same author when the
        // current book knows its author.
        let author = book.author.trimmingCharacters(in: .whitespaces)
        let matches = collected.filter { result in
            guard result.name == query || result.name.contains(query) || query.contains(result.name) else { return false }
            guard !author.isEmpty, !result.author.isEmpty else { return true }
            return result.author.contains(author) || author.contains(result.author)
        }
        // Prefer exact titles, then shorter (less decorated) ones.
        return matches.sorted { lhs, rhs in
            let lhsExact = lhs.name == query ? 0 : 1
            let rhsExact = rhs.name == query ? 0 : 1
            if lhsExact != rhsExact { return lhsExact < rhsExact }
            return lhs.name.count < rhs.name.count
        }
    }

    /// Checks that `result` can really serve the chapter the reader is on.
    ///
    /// A search hit is not enough: paywalled mirrors (bqg6 and friends) show up
    /// in results and in the table of contents, then answer with
    /// "内容正在获取中，稍候重试" instead of prose. Switching there just moves
    /// the problem, so probe the body before offering the source.
    func canReadChapter(_ result: SearchResult, of book: Book, chapterTitle: String?) async -> Bool {
        guard let source = sources.first(where: { $0.id == result.sourceID }) else { return false }
        do {
            let detail = try await engine.fetchBookDetail(result, source: source)
            let chapters = try await engine.fetchChapters(book: detail, source: source)
            guard !chapters.isEmpty else { return false }
            let target: Chapter
            if let chapterTitle, let matched = chapters.first(where: { $0.title == chapterTitle }) {
                target = matched
            } else {
                let index = min(max(book.progress.chapterIndex, 0), chapters.count - 1)
                target = chapters[index]
            }
            _ = try await engine.fetchContent(book: detail, chapter: target, source: source)
            return true
        } catch {
            return false
        }
    }

    /// Re-points a shelf book at another source while keeping its identity, so
    /// reading progress, bookmarks and the shelf entry survive.
    @discardableResult
    func switchSource(of book: Book, to result: SearchResult) async throws -> Book {
        guard let source = sources.first(where: { $0.id == result.sourceID }) else {
            throw SourceError.notFound("找不到对应的书源")
        }
        let detail = try await engine.fetchBookDetail(result, source: source)
        let chapters = try await engine.fetchChapters(book: detail, source: source)
        guard !chapters.isEmpty else {
            throw SourceError.notFound("新书源没有返回目录")
        }

        guard let index = books.firstIndex(where: { $0.id == book.id }) else {
            throw SourceError.notFound("书籍不在书架中")
        }
        var updated = books[index]
        let oldProgress = updated.progress
        updated.sourceID = detail.sourceID
        updated.sourceName = detail.sourceName
        updated.detailURL = detail.detailURL
        updated.tocURL = detail.tocURL
        updated.name = detail.name.isEmpty ? updated.name : detail.name
        updated.author = detail.author.isEmpty ? updated.author : detail.author
        updated.intro = detail.intro.isEmpty ? updated.intro : detail.intro
        updated.coverURL = detail.coverURL ?? updated.coverURL
        updated.lastChapterTitle = chapters.last?.title ?? updated.lastChapterTitle

        // Try to keep the reader on the same chapter by matching its title.
        let matched = chapters.first { $0.title == oldProgress.chapterTitle }
        let newIndex = matched?.index ?? min(max(oldProgress.chapterIndex, 0), chapters.count - 1)
        updated.progress = ReadingProgress(
            chapterIndex: newIndex,
            characterOffset: 0,
            chapterTitle: chapters[newIndex].title,
            updatedAt: Date()
        )

        books[index] = updated
        let snapshot = books
        await store.saveBooks(snapshot)
        await store.saveChapters(chapters, bookID: updated.id)
        return updated
    }

    // MARK: - Banner

    func showBanner(_ text: String, isError: Bool) {
        banner = (text, isError)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self.banner?.text == text { self.banner = nil }
        }
    }
}
#endif
