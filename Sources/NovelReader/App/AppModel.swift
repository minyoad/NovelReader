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
    /// - Parameters:
    ///   - query: what is being searched for.
    ///   - done: sources that have answered so far.
    ///   - total: sources taking part.
    ///
    /// Results stream in one source at a time, so the count is what tells the
    /// user the search is still working rather than stuck — waiting for the
    /// slowest source before showing anything made a 20-source search feel
    /// broken even when most had already answered.
    case searching(String, done: Int = 0, total: Int = 0)
    /// - Parameters:
    ///   - failed: sources that errored (network, site changed, …). Worth
    ///     retrying later.
    ///   - skipped: sources that cannot work in this build at all because their
    ///     search rule is JavaScript. Retrying will never help, so they are not
    ///     lumped in with the failures — that list would train the user to
    ///     ignore a permanent problem.
    case finished(count: Int, failed: [String], skipped: [String])
    case failed(String)

    /// A search is in flight, so the UI shows progress rather than empty states.
    var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }
}

/// The tabs in the bottom bar, in display order.
///
/// Search is deliberately absent: it is presented over the discover page, so
/// it gets no slot. A case without a matching `.tabItem` still leaves a dead
/// gap in the bar, which is why this list matches the bar one-for-one.
enum AppTab: Hashable {
    case library
    case explore
    case sources
    case settings
}

/// A source's discover page: categories, then the books in one of them.
enum ExploreState: Equatable {
    case idle
    case loading
    /// - Parameter more: whether another page may exist. Sources rarely say,
    ///   so the page asks until a page comes back empty.
    case loaded([SearchResult], page: Int, more: Bool)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var results: [SearchResult] {
        if case .loaded(let results, _, _) = self { return results }
        return []
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var books: [Book] = []
    @Published var sources: [BookSource] = []
    @Published var searchState: SearchState = .idle
    @Published var searchResults: [SearchResult] = []
    /// State of the discover page. Separate from `searchState` so switching
    /// tabs never disturbs a search the user left running.
    @Published var exploreState: ExploreState = .idle
    /// Which discover categories the current source offers.
    @Published var exploreCategories: [ExploreCategory] = []
    /// The category whose books are on screen.
    ///
    /// Held here rather than in the view because opening a source can skip
    /// past stale tabs, and the highlighted tab has to follow what was loaded.
    @Published var exploreCategory: ExploreCategory?
    /// The book source whose discover page is showing.
    @Published var exploreSourceID: UUID?
    /// Whether the search screen is presented over the discover page.
    ///
    /// Search used to be a tab of its own. It is now opened from the discover
    /// page, so this is a presentation flag rather than a tab selection.
    @Published var isSearching = false
    /// Identifies the search currently allowed to write results.
    ///
    /// Searching again while an older one is still in flight (or cancelling)
    /// invalidates the old ticket, so a late reply cannot overwrite whatever
    /// the user is looking at now.
    private var activeSearchTicket: UUID?
    @Published var banner: (text: String, isError: Bool)?

    /// Latches and counters used only by the discover-page probe.
    ///
    /// They live behind a lock because the probe updates them from the request
    /// tasks, which run off the main actor; keeping them here avoids touching
    /// `self` across those boundaries.
    nonisolated let probeCoordinator = ExploreProbeCoordinator()

    let store: LibraryStore
    private var client: HTTPClient
    /// Guards against a second run when the root view's task fires again.
    private var didBootstrap = false

    init(store: LibraryStore = LibraryStore()) {
        self.store = store

        var loaded = AppSettings()
        loaded.ai.apiKey = Keychain.get("ai.apiKey") ?? ""
        loaded.tts.remote.apiKey = Keychain.get("tts.apiKey") ?? ""
        // Settings are loaded asynchronously in bootstrap(); this placeholder only
        // carries the API keys so the first launch is not blocked by disk IO.
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
        guard !didBootstrap else { return }
        didBootstrap = true
        var loaded = await store.loadSettings()
        loaded.ai.apiKey = Keychain.get("ai.apiKey") ?? ""
        loaded.tts.remote.apiKey = Keychain.get("tts.apiKey") ?? ""
        loaded = await adoptSystemAppearanceIfNeeded(loaded)
        settings = loaded
        client = HTTPClient(settings: loaded.network)
        books = await store.loadBooks()
        sources = await store.loadSources()
        loadExploreAvailability()

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

    /// Turns on "follow system" exactly once for existing installs.
    ///
    /// `followSystemAppearance` used to default to off, so every install made
    /// before this build has it stored as `false` — and stored values win over
    /// the new default. Without this, those readers would keep a permanently
    /// white page at night and reasonably call it a bug.
    ///
    /// Guarded by a flag rather than by the stored value: once someone has
    /// deliberately switched the toggle off, it stays off.
    private func adoptSystemAppearanceIfNeeded(_ loaded: AppSettings) async -> AppSettings {
        let flag = "systemAppearanceAdopted"
        let alreadyAdopted = await store.isFlagSet(flag)

        var updated = loaded
        // The bundled typography defaults moved once; installs that never
        // touched the sliders need the new numbers written through, because
        // the stored blob would otherwise keep the old ones forever.
        let typographyFlag = "typographyDefaultsAdopted"
        let typographyAdopted = await store.isFlagSet(typographyFlag)
        let hasStoredSettings = await store.hasSettingsOnDisk()
        var changed = false
        if hasStoredSettings, updated.reading.adoptTypographyDefaults(hasMigrated: typographyAdopted) {
            changed = true
        }
        // A brand new install has nothing stored yet, so there is nothing to
        // migrate — the new default already applies.
        if hasStoredSettings, updated.reading.adoptSystemAppearance(hasMigrated: alreadyAdopted) {
            changed = true
        }
        if changed {
            // Persist right away: a crash before the next `saveSettings` would
            // otherwise redo the migration with the same result, which is fine,
            // but writing here keeps disk and memory in step. `strippingSecrets`
            // matters — the in-memory settings hold the Keychain values.
            await store.saveSettings(updated.strippingSecrets)
        }
        if !alreadyAdopted { await store.setFlag(flag) }
        if !typographyAdopted { await store.setFlag(typographyFlag) }
        return updated
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
    /// ranking by title with the recorded author as a hint.
    ///
    /// The flag is only set once every book has been repointed, so an offline
    /// launch retries next time instead of leaving books stuck on a dead host.
    private func repairBooksAfterPresetMigration() async {
        let flag = "presetBooksRepairedV3"
        guard !(await store.isFlagSet(flag)) else { return }

        var allFixed = true
        for book in books {
            guard BuiltinContent.isPresetID(book.sourceID),
                  let source = sources.first(where: { $0.id == book.sourceID }),
                  let staleHost = URL(string: book.detailURL)?.host,
                  let sourceHost = URL(string: source.baseURL)?.host,
                  staleHost != sourceHost else { continue }

            let matches = await searchMatches(keyword: book.name, authorHint: book.author, in: [source])
            guard let hit = matches.first else {
                allFixed = false
                continue
            }
            do {
                _ = try await switchSource(of: book, to: hit)
            } catch {
                allFixed = false
            }
        }

        if allFixed {
            await store.setFlag(flag)
        }
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
        if settings.ai.apiKey.isEmpty {
            Keychain.delete("ai.apiKey")
        } else {
            Keychain.set(settings.ai.apiKey, for: "ai.apiKey")
        }
        if settings.tts.remote.apiKey.isEmpty {
            Keychain.delete("tts.apiKey")
        } else {
            Keychain.set(settings.tts.remote.apiKey, for: "tts.apiKey")
        }
        let snapshot = settings.strippingSecrets
        Task { await store.saveSettings(snapshot) }
        client.update(settings: settings.network)
    }

    // MARK: - Sources

    @discardableResult
    func importSources(fromJSON text: String) -> (added: Int, warnings: [String]) {
        guard let data = text.data(using: .utf8) else {
            return (0, ["书源文本编码无法识别"])
        }
        return importSources(from: data)
    }

    /// Imports a legado bundle and merges it into the shelf.
    ///
    /// Sources are matched by `baseURL`, so re-importing the same collection
    /// refreshes the rules in place instead of piling up duplicates — that
    /// matters here because collections are re-downloaded whenever the site
    /// re-verifies them.
    @discardableResult
    func importSources(from data: Data) -> (added: Int, warnings: [String]) {
        do {
            let result = try LegadoImporter.importSources(from: data)
            var added = 0
            for var source in result.sources {
                if let index = sources.firstIndex(where: { $0.baseURL == source.baseURL }) {
                    // Refresh in place: keep the identity (books point at it)
                    // and whatever the user chose about enabling it.
                    source.id = sources[index].id
                    source.isBuiltIn = sources[index].isBuiltIn
                    source.enabled = sources[index].enabled
                    sources[index] = source
                    // The rules changed, so any verdict learned from the old
                    // ones no longer applies.
                    forgetExploreFailures(of: source)
                } else {
                    sources.append(source)
                    added += 1
                }
            }
            if added > 0 { persistSources() }
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
        forgetExploreFailures(of: source)
        persistSources()
    }

    func deleteSource(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        forgetExploreFailures(of: source)
        persistSources()
    }

    /// Removes several sources at once, keeping the shelf as it was.
    ///
    /// One save for the whole batch: a hundred sources would otherwise queue a
    /// hundred writes to the same file.
    func deleteSources(withIDs ids: Set<UUID>) {
        let removed = sources.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        sources.removeAll { ids.contains($0.id) }
        for source in removed { forgetExploreFailures(of: source) }
        persistSources()
    }

    /// Switches several sources off at once.
    ///
    /// Disabling is the reversible half of deleting: the rules stay, the books
    /// keep their link, and flipping them back on costs nothing.
    func setSources(_ ids: Set<UUID>, enabled: Bool) {
        var changed = false
        for index in sources.indices where ids.contains(sources[index].id) {
            guard sources[index].enabled != enabled else { continue }
            sources[index].enabled = enabled
            changed = true
        }
        guard changed else { return }
        persistSources()
    }

    /// Shelf books that would lose their source.
    ///
    /// Deleting a source does not touch the shelf, but those books can no
    /// longer be refreshed or read further, so the reader is told before the
    /// decision rather than after. Disabling leaves the books working, so it is
    /// reported as a count instead of a warning.
    func booksOnShelf(from sourceIDs: Set<UUID>) -> [Book] {
        books.filter { sourceIDs.contains($0.sourceID) }
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

    // MARK: - Collections

    /// Browse the online 书源合集 list.
    ///
    /// Kept here rather than in the view so the network client (with its cookie
    /// jar and timeout settings) stays the app's single entry point.
    func collectionClient() -> SourceCollectionClient {
        SourceCollectionClient(client: client)
    }

    // MARK: - Search

    func search(_ keyword: String) async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // A newer search supersedes any older one still running; the older
        // task checks this before writing so its results never land on top of
        // a search the user has moved on from.
        let ticket = UUID()
        activeSearchTicket = ticket

        searchResults = []

        let available = sources.filter { $0.enabled && $0.type == .text && ($0.canSearch || $0.isBuiltIn) }
        let active = settings.searchAllSources ? available : Array(available.prefix(1))
        guard !active.isEmpty else {
            searchState = .failed("没有可用的书源，请先在「书源」里导入")
            return
        }

        searchState = .searching(query, done: 0, total: active.count)

        var collected: [SearchResult] = []
        var failures: [String] = []
        var done = 0

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

            // Publish after every answer rather than once at the end. The
            // slowest source used to hold back everything the fast ones had
            // already returned, which is what made a many-source search feel
            // like it had hung.
            var remembered = false
            for await (name, result) in group {
                guard activeSearchTicket == ticket else { return }
                done += 1
                switch result {
                case .success(let results): collected.append(contentsOf: results)
                case .failure: failures.append(name)
                }
                let sorted = Self.rankResults(collected, for: query)
                searchResults = sorted
                searchState = .searching(query, done: done, total: active.count)
                // Record the keyword the moment anything is found, not at the
                // end. Cancelling while the slow sources are still running
                // returns early, and a search that did produce results is
                // exactly the one worth repeating.
                if !remembered, !collected.isEmpty {
                    remembered = true
                    rememberSearch(query)
                }
            }
        }

        guard activeSearchTicket == ticket else { return }

        // A source whose search rule is JavaScript-only is not a transient
        // failure; say so once, up front, instead of listing it as "失败".
        var skipped: [String] = []
        for source in active where source.compatibility.blockingRoles.contains("搜索列表") {
            skipped.append(source.name)
        }
        failures.removeAll { name in skipped.contains(name) }

        searchResults = Self.rankResults(collected, for: query)
        searchState = .finished(count: collected.count, failed: failures, skipped: skipped)
    }

    /// Drops results of an in-flight search and returns to the empty state.
    ///
    /// Cancelling used to leave the previous results on screen, so the list no
    /// longer matched what was typed in the field.
    func cancelSearch() {
        activeSearchTicket = nil
        searchState = .idle
        searchResults = []
    }

    /// Records a successful search so it can be tapped again later.
    ///
    /// Only results-bearing searches are kept: remembering every abandoned
    /// keystroke would fill the list with typos nobody wants to revisit.
    func rememberSearch(_ keyword: String) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var history = settings.searchHistory.filter { $0 != query }
        history.insert(query, at: 0)
        settings.searchHistory = Array(history.prefix(Self.searchHistoryLimit))
        saveSettings()
    }

    func removeSearchHistory(_ keyword: String) {
        settings.searchHistory.removeAll { $0 == keyword }
        saveSettings()
    }

    func clearSearchHistory() {
        guard !settings.searchHistory.isEmpty else { return }
        settings.searchHistory = []
        saveSettings()
    }

    /// Enough to cover a session's worth of looking things up, short enough to
    /// read at a glance.
    static let searchHistoryLimit = 12

    // MARK: - Explore

    /// Sources whose discover page can actually be opened.
    ///
    /// A source that has failed here is remembered and dropped from the list:
    /// a dead site or a page that no longer matches its selectors will fail
    /// every time, and leaving it in the picker only produces the same error on
    /// the next attempt. Both lists are remembered across launches and can be
    /// reset from the picker's footer.
    var explorableSources: [BookSource] {
        sources.filter {
            $0.enabled
                && $0.type == .text
                && $0.canExplore
                && !unavailableExploreSourceIDs.contains($0.id.uuidString)
                && !openCategories(of: $0).isEmpty
        }
    }

    /// Sources that are explorable on paper but currently filtered out.
    var hiddenExploreSources: [BookSource] {
        sources.filter {
            $0.enabled
                && $0.type == .text
                && $0.canExplore
                && (unavailableExploreSourceIDs.contains($0.id.uuidString)
                    || openCategories(of: $0).isEmpty)
        }
    }

    /// The categories of a source that have not failed yet.
    ///
    /// Failures are tracked per category as well as per source. A source whose
    /// 玄幻 tab answers 404 usually still has a dozen other sections, and
    /// hiding the whole source over one stale address was what emptied the
    /// list while working sources were still in it.
    func openCategories(of source: BookSource) -> [ExploreCategory] {
        let failed = unavailableExploreCategories[source.id.uuidString] ?? []
        return source.openableExploreCategories.filter { !failed.contains($0.name) }
    }

    /// Category names that failed to open, keyed by source id.
    @Published private(set) var unavailableExploreCategories: [String: Set<String>] = [:] {
        didSet { persistExploreAvailability() }
    }

    /// Sources with every category failed, or whose host does not answer.
    @Published private(set) var unavailableExploreSourceIDs: Set<String> = [] {
        didSet { persistExploreAvailability() }
    }

    private static let unavailableExploreKey = "explore.unavailableSources"
    private static let failedCategoriesKey = "explore.failedCategories"
    private static let availabilityVersionKey = "explore.availabilityVersion"

    /// Bumped when the filtering rules change, so verdicts reached by older
    /// ones are thrown away instead of hiding sources that now qualify.
    private static let availabilityVersion = 3

    /// Set when old verdicts were discarded, so the discover page can check the
    /// sources once instead of making the reader tap through them again.
    @Published var shouldProbeExplore = false

    /// How many tabs opening a source will try before giving up.
    ///
    /// Two would cover the usual case — the first tab is stale, the second
    /// works — and three keeps a dead source from costing a minute of timeouts.
    private static let exploreAttempts = 3

    /// Brings hidden sources and categories back, for when the failure was the
    /// network rather than the site.
    func restoreHiddenExploreSources() {
        guard !unavailableExploreSourceIDs.isEmpty || !unavailableExploreCategories.isEmpty else { return }
        unavailableExploreSourceIDs = []
        unavailableExploreCategories = [:]
    }

    /// Drops the learned state for one source, after its rules were re-imported
    /// or edited: the old verdict was about the old rules.
    func forgetExploreFailures(of source: BookSource) {
        unavailableExploreSourceIDs.remove(source.id.uuidString)
        unavailableExploreCategories[source.id.uuidString] = nil
    }

    private func persistExploreAvailability() {
        let defaults = UserDefaults.standard
        defaults.set(Array(unavailableExploreSourceIDs), forKey: Self.unavailableExploreKey)
        let categories = unavailableExploreCategories.mapValues { Array($0) }
        defaults.set(categories, forKey: Self.failedCategoriesKey)
    }

    private func loadExploreAvailability() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.availabilityVersionKey) < Self.availabilityVersion {
            // Earlier builds hid a whole source as soon as any one of its tabs
            // failed, which threw away sources that still had working
            // sections. Those verdicts cannot be trusted, so start clean.
            unavailableExploreSourceIDs = []
            unavailableExploreCategories = [:]
            defaults.set(Self.availabilityVersion, forKey: Self.availabilityVersionKey)
            shouldProbeExplore = true
            return
        }

        unavailableExploreSourceIDs = Set(defaults.stringArray(forKey: Self.unavailableExploreKey) ?? [])
        let stored = defaults.dictionary(forKey: Self.failedCategoriesKey) as? [String: [String]] ?? [:]
        unavailableExploreCategories = stored.mapValues(Set.init)
    }

    /// Loads the first page of a source's discover page.
    ///
    /// Only categories the source can actually read are offered: a tab that is
    /// guaranteed to fail is worse than no tab at all. When the first tab does
    /// fail anyway — the site moved a section, the page was rewritten — the
    /// next one is tried, so a source with one stale link still opens.
    func startExplore(source: BookSource) async {
        exploreSourceID = source.id
        exploreCategories = openCategories(of: source)
        guard !exploreCategories.isEmpty else {
            exploreState = .failed("这个书源的发现页没有配置可用的分类规则")
            return
        }

        exploreState = .loading
        var lastError: Error?
        for category in exploreCategories.prefix(Self.exploreAttempts) {
            switch await fetchExplore(category: category, source: source, page: 1) {
            case .success(let results):
                exploreCategories = openCategories(of: source)
                exploreCategory = category
                exploreState = .loaded(results, page: 1, more: !results.isEmpty)
                return
            case .failure(let error):
                lastError = error
                // A whole-source failure would only repeat on the next tab;
                // the source is hidden by now, so stop wasting the reader's
                // time on timeouts.
                if unavailableExploreSourceIDs.contains(source.id.uuidString) { break }
            }
        }

        exploreCategories = openCategories(of: source)
        exploreCategory = exploreCategories.first
        exploreState = .failed(lastError?.localizedDescription ?? "发现页打不开")
    }

    func loadExplore(category: ExploreCategory, source: BookSource, page: Int) async {
        // Named for the page it shows; the list above is rebuilt from page 1
        // when the first tab fails.
        _ = page
        exploreState = .loading
        var lastError: Error?
        // Tapping a stale tab should land on books, not on its error: carry on
        // to the next tab the same way opening the source does. A failure that
        // condemns the whole source is not worth repeating on its neighbours.
        for attempt in categoriesAfter(category, of: source).prefix(Self.exploreAttempts) {
            switch await fetchExplore(category: attempt, source: source, page: 1) {
            case .success(let results):
                exploreCategories = openCategories(of: source)
                exploreCategory = attempt
                exploreState = .loaded(results, page: 1, more: !results.isEmpty)
                return
            case .failure(let error):
                lastError = error
                if unavailableExploreSourceIDs.contains(source.id.uuidString) { break }
            }
        }

        exploreCategories = openCategories(of: source)
        if !exploreCategories.contains(category) {
            exploreCategory = exploreCategories.first
        }
        exploreState = .failed(lastError?.localizedDescription ?? "这个分类打不开")
    }

    /// The tapped tab first, then the others in the order they are listed.
    private func categoriesAfter(_ category: ExploreCategory, of source: BookSource) -> [ExploreCategory] {
        let open = openCategories(of: source)
        guard open.contains(category) else { return open }
        return [category] + open.filter { $0 != category }
    }

    /// Fetches one page and records whether the category opened.
    ///
    /// Only the first page is judged: a later page failing can be a timeout or
    /// the end of the list, and hiding a tab that just showed books would be
    /// wrong.
    private func fetchExplore(
        category: ExploreCategory,
        source: BookSource,
        page: Int
    ) async -> Result<[SearchResult], Error> {
        do {
            let results = try await engine.explore(category: category, page: page, source: source)
            if page == 1 { recordExploreSuccess(category: category, source: source) }
            return .success(results)
        } catch {
            if page == 1 { recordExploreFailure(category: category, source: source, error: error) }
            return .failure(error)
        }
    }

    /// Clears the marks on a category and on its source.
    ///
    /// A page that returns books proves both, so a site that came back is
    /// offered again without the reader having to reset anything.
    private func recordExploreSuccess(category: ExploreCategory, source: BookSource) {
        let key = source.id.uuidString
        unavailableExploreSourceIDs.remove(key)
        guard var failed = unavailableExploreCategories[key] else { return }
        failed.remove(category.name)
        if failed.isEmpty {
            unavailableExploreCategories[key] = nil
        } else {
            unavailableExploreCategories[key] = failed
        }
    }

    private func recordExploreFailure(category: ExploreCategory, source: BookSource, error: Error) {
        recordExploreFailure(
            category: category,
            source: source,
            wholeSource: ExploreFailure.failsWholeSource(error)
        )
    }

    private func recordExploreFailure(
        category: ExploreCategory,
        source: BookSource,
        wholeSource: Bool
    ) {
        let key = source.id.uuidString
        if wholeSource {
            unavailableExploreCategories[key] = Set(source.openableExploreCategories.map(\.name))
            unavailableExploreSourceIDs.insert(key)
        } else {
            unavailableExploreCategories[key, default: []].insert(category.name)
            if openCategories(of: source).isEmpty {
                unavailableExploreSourceIDs.insert(key)
            }
        }
    }

    // MARK: - Explore probe

    /// Progress of "open every discover page once", for the picker's footer.
    enum ExploreProbeState: Equatable {
        case idle
        case running(done: Int, total: Int, working: Int)
        case finished(working: Int, total: Int)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var exploreProbe: ExploreProbeState = .idle
    private var probeTask: Task<Void, Never>?

    /// How many sources are checked at once.
    ///
    /// Each source walks its own tabs in turn, so this only decides how many
    /// sites are being talked to at the same time; six spreads the load and
    /// still finishes a few hundred sources in a couple of minutes.
    private static let probeConcurrency = 6

    /// Opens every discover page and keeps whatever answers.
    ///
    /// Imported collections are mostly dead, and finding the live ones by
    /// tapping each source in turn is hopeless. This walks the visible list in
    /// the background, records the verdicts and leaves a short list of sources
    /// that actually returned books.
    func probeExploreSources() {
        guard probeTask == nil else { return }
        let queue = explorableSources
        guard !queue.isEmpty else {
            exploreProbe = .finished(working: 0, total: 0)
            return
        }
        probeCoordinator.reset()
        exploreProbe = .running(done: 0, total: queue.count, working: 0)
        probeTask = Task { [weak self] in
            await self?.runExploreProbe(queue)
            self?.probeTask = nil
        }
    }

    func cancelExploreProbe() {
        probeTask?.cancel()
    }

    /// One source's verdict, as produced by the request tasks.
    private struct ProbeOutcome: Sendable {
        let source: BookSource
        let workingCategory: ExploreCategory?
        let failures: [ExploreCategory]
        /// The first failure that condemns the whole source, if any.
        let sourceError: Error?

        var isWorking: Bool { workingCategory != nil }
    }

    private func runExploreProbe(_ queue: [BookSource]) async {
        let total = queue.count
        var done = 0
        var working = 0

        // A dead host is known within seconds; the reader's own timeout is far
        // too long to spend on a hundred of them.
        var quick = settings.network
        quick.timeout = min(quick.timeout, 6)
        let probeClient = HTTPClient(settings: quick)
        let coordinator = probeCoordinator
        let categories = Dictionary(
            uniqueKeysWithValues: queue.map { ($0.id, openCategories(of: $0)) }
        )

        await withTaskGroup(of: ProbeOutcome.self) { group in
            var next = 0
            func enqueue(_ source: BookSource) {
                let tabs = categories[source.id] ?? []
                group.addTask {
                    let verdict = await Self.probeSource(
                        source,
                        categories: tabs,
                        client: probeClient,
                        coordinator: coordinator
                    )
                    return ProbeOutcome(
                        source: source,
                        workingCategory: verdict.working,
                        failures: verdict.failures,
                        sourceError: verdict.sourceError
                    )
                }
            }

            for _ in 0..<min(Self.probeConcurrency, total) {
                enqueue(queue[next])
                next += 1
            }

            for await outcome in group {
                done += 1
                applyProbeOutcome(outcome)
                if outcome.isWorking { working += 1 }
                exploreProbe = .running(done: done, total: total, working: working)

                if next < total {
                    enqueue(queue[next])
                    next += 1
                }
                if Task.isCancelled { break }
            }
            group.cancelAll()
        }

        // The source on screen may have lost every tab it had.
        if let id = exploreSourceID, let source = sources.first(where: { $0.id == id }) {
            exploreCategories = openCategories(of: source)
            if let shown = exploreCategory, !exploreCategories.contains(shown) {
                exploreCategory = exploreCategories.first
            }
        }
        exploreProbe = Task.isCancelled
            ? .finished(working: working, total: done)
            : .finished(working: working, total: total)
    }

    /// Walks one source's tabs until one answers.
    ///
    /// Checking only the first tab was what hid sources with one stale link;
    /// checking all of them on a dead host is what made the run slow. So the
    /// tabs are tried in order and the walk stops at the first page that comes
    /// back with books — or as soon as the source is clearly broken.
    private nonisolated static func probe(
        _ source: BookSource,
        categories: [ExploreCategory],
        client: HTTPClient,
        coordinator: ExploreProbeCoordinator
    ) async -> ProbeOutcome {
        let verdict = await probeSource(
            source,
            categories: categories,
            client: client,
            coordinator: coordinator
        )
        return ProbeOutcome(
            source: source,
            workingCategory: verdict.working,
            failures: verdict.failures,
            sourceError: verdict.sourceError
        )
    }

    /// The check one source gets, shared by the discover-page run and the
    /// source list's "only keep the ones that work" button.
    ///
    /// It leaves no record of its own: the caller decides what a verdict means
    /// (the discover page records failures, the source list just keeps the
    /// survivors).
    nonisolated static func probeSource(
        _ source: BookSource,
        categories: [ExploreCategory],
        client: HTTPClient,
        coordinator: ExploreProbeCoordinator
    ) async -> (working: ExploreCategory?, failures: [ExploreCategory], sourceError: Error?) {
        guard let host = URL(string: source.baseURL)?.host else {
            return (nil, categories, nil)
        }
        if coordinator.isDead(host: host) {
            return (nil, categories, nil)
        }

        let engine = SourceEngine(client: client)
        var failures: [ExploreCategory] = []

        for category in categories {
            if Task.isCancelled { break }
            if coordinator.shouldSkip(source: source.id) { break }
            do {
                _ = try await engine.explore(category: category, page: 1, source: source)
                // A tab that returns books proves both the tab and the source,
                // so the failures on the way here are not worth keeping.
                return (category, [], nil)
            } catch {
                failures.append(category)
                coordinator.recordFailure(source: source.id)
                if ExploreFailure.failsWholeSource(error) {
                    return (nil, categories, error)
                }
                // Only the first host-level failure is conclusive: a site that
                // cannot be resolved at all is gone, while one bad section is
                // not.
                if let http = error as? HTTPError, case .transport = http {
                    coordinator.markDead(host: host)
                    return (nil, categories, error)
                }
            }
        }
        return (nil, failures, nil)
    }

    /// Records a finished source on the main actor.
    private func applyProbeOutcome(_ outcome: ProbeOutcome) {
        let key = outcome.source.id.uuidString
        if let working = outcome.workingCategory {
            unavailableExploreSourceIDs.remove(key)
            unavailableExploreCategories[key] = nil
            // Keeps what the check learned for the picker's row count without
            // marking anything: the source is offered as a whole.
            probeWorkingCategory[outcome.source.id] = working
            return
        }
        probeWorkingCategory[outcome.source.id] = nil
        if outcome.sourceError != nil {
            unavailableExploreCategories[key] = Set(outcome.source.openableExploreCategories.map(\.name))
        } else {
            unavailableExploreCategories[key] = Set(outcome.failures.map(\.name))
        }
        if openCategories(of: outcome.source).isEmpty {
            unavailableExploreSourceIDs.insert(key)
        }
    }

    /// Which tab worked for a source during the last check.
    @Published private(set) var probeWorkingCategory: [UUID: ExploreCategory] = [:]

    /// Opens a source at the tab the last check found working.
    func startExploreAtProbedCategory(source: BookSource) async {
        await startExplore(source: source)
        guard let working = probeWorkingCategory[source.id],
              exploreCategories.contains(working),
              exploreCategories.first != working else { return }
        await loadExplore(category: working, source: source, page: 1)
    }

    /// Appends the next page of the category already on screen.
    func loadMoreExplore(category: ExploreCategory, source: BookSource) async {
        guard case .loaded(let existing, let page, true) = exploreState else { return }
        do {
            let next = try await engine.explore(category: category, page: page + 1, source: source)
            if next.isEmpty {
                exploreState = .loaded(existing, page: page, more: false)
            } else {
                exploreState = .loaded(existing + next, page: page + 1, more: true)
            }
        } catch {
            // Keep what is on screen: losing a loaded page because the next one
            // failed is worse than simply not having more.
            exploreState = .loaded(existing, page: page, more: false)
        }
    }

    /// Exact title first, then titles containing the query, then the rest.
    static func rankResults(_ results: [SearchResult], for query: String) -> [SearchResult] {
        results.sorted { lhs, rhs in
            let lhsExact = lhs.name == query ? 0 : (lhs.name.contains(query) ? 1 : 2)
            let rhsExact = rhs.name == query ? 0 : (rhs.name.contains(query) ? 1 : 2)
            if lhsExact != rhsExact { return lhsExact < rhsExact }
            return lhs.name < rhs.name
        }
    }

    // MARK: - Shelf

    func bookOnShelf(for result: SearchResult) -> Book? {
        books.first { $0.sourceID == result.sourceID && $0.detailURL == result.detailURL }
    }

    /// Everything needed to decide whether a search result is worth keeping.
    ///
    /// Reading the detail page and the TOC is the only way to answer the two
    /// questions a search result cannot: how long the book is and whether the
    /// chapters actually load. Nothing here touches the shelf or the disk, so
    /// browsing results does not leave empty books behind.
    struct BookPreview {
        var result: SearchResult
        var book: Book
        var chapters: [Chapter]
        /// True when the detail page failed but the search row still had enough
        /// to show; the page then reads as a degraded preview instead of an error.
        var isPartial: Bool
        var error: String?
    }

    func preview(for result: SearchResult) async -> BookPreview {
        guard let source = sources.first(where: { $0.id == result.sourceID }) else {
            return BookPreview(
                result: result,
                book: Self.placeholderBook(from: result),
                chapters: [],
                isPartial: true,
                error: "找不到对应的书源"
            )
        }
        if source.isBuiltIn {
            return BookPreview(
                result: result,
                book: BuiltinContent.sampleBook,
                chapters: BuiltinContent.sampleChapters,
                isPartial: false,
                error: nil
            )
        }

        var book = Self.placeholderBook(from: result)
        var detailError: String?
        do {
            book = try await engine.fetchBookDetail(result, source: source)
        } catch {
            // The search row already carries name/author/cover, which is enough
            // for the preview header, so a failed detail page degrades to a
            // partial preview instead of an error screen. The TOC below may
            // still work, because many sites serve it on the detail URL anyway.
            detailError = error.localizedDescription
        }

        do {
            let chapters = try await engine.fetchChapters(book: book, source: source)
            return BookPreview(
                result: result,
                book: book,
                chapters: chapters,
                isPartial: detailError != nil,
                error: detailError
            )
        } catch {
            return BookPreview(
                result: result,
                book: book,
                chapters: [],
                isPartial: true,
                error: detailError ?? error.localizedDescription
            )
        }
    }

    /// A `Book` built only from what the search result knew, used when the
    /// detail page is unreachable or before the network answers.
    private static func placeholderBook(from result: SearchResult) -> Book {
        Book(
            sourceID: result.sourceID,
            sourceName: result.sourceName,
            detailURL: result.detailURL,
            name: result.name,
            author: result.author,
            intro: result.intro,
            kind: result.kind,
            coverURL: result.coverURL,
            lastChapterTitle: result.lastChapterTitle,
            updateTime: result.updateTime
        )
    }

    func addToShelf(_ result: SearchResult, preview: BookPreview? = nil) async throws -> Book {
        if let existing = bookOnShelf(for: result) { return existing }
        guard let source = sources.first(where: { $0.id == result.sourceID }) else {
            throw SourceError.notFound("找不到对应的书源")
        }

        var book: Book
        var chapters: [Chapter] = []

        if source.isBuiltIn {
            book = BuiltinContent.sampleBook
            chapters = BuiltinContent.sampleChapters
        } else if let preview, !preview.chapters.isEmpty {
            // The preview screen already paid for these two requests; repeating
            // them here made "加入书架" sit on a spinner for seconds after the
            // user had just read the same data.
            book = preview.book
            chapters = preview.chapters
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
        let shouldCacheAll = settings.cache.autoCacheOnAdd && !book.detailURL.hasPrefix("local://")
        Task {
            await store.saveBooks(snapshot)
            await store.saveChapters(chapterSnapshot, bookID: bookID)
        }
        if shouldCacheAll {
            // Off the main path: adding to the shelf must stay instant.
            Task { await self.cacheWholeBookInBackground(book: book, chapters: chapters) }
        }
        return book
    }

    /// Caches every chapter of a freshly added book when the user asked for it.
    private func cacheWholeBookInBackground(book: Book, chapters: [Chapter]) async {
        let cached = await store.cachedChapterURLs(bookID: book.id)
        let cachedIndices = Set(chapters.enumerated().filter { cached.contains($0.element.url) }.map { $0.offset })
        let plan = CachePlanner.missingForWholeBook(chapterCount: chapters.count, alreadyCached: cachedIndices)
        guard !plan.isEmpty else { return }

        var done = 0
        var failed = 0
        for index in plan {
            if Task.isCancelled { break }
            if await cacheChapter(book: book, chapter: chapters[index]) {
                done += 1
            } else {
                failed += 1
            }
        }
        showBanner(
            failed == 0 ? "「\(book.name)」全本缓存完成（\(done) 章）" : "「\(book.name)」缓存完成，\(failed) 章失败",
            isError: failed > 0
        )
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

    /// Fetches one chapter body.
    ///
    /// `cache: false` is what a trial read passes: the book is not on the shelf,
    /// so writing the body to disk would leave a chapter file for a book the
    /// library does not know about, and nothing would ever expire it.
    func chapterContent(book: Book, chapter: Chapter, cache: Bool = true) async throws -> ChapterContent {
        if cache, let cached = await store.loadContent(bookID: book.id, chapterURL: chapter.url) {
            // Older builds cached whatever the site returned, including
            // "内容正在获取中，稍候重试" paywall stubs. Drop those instead of
            // showing them as prose.
            if !TextProcessing.isPlaceholderContent(cached.text, chapterTitle: chapter.title) {
                return cached
            }
            await store.deleteContent(bookID: book.id, chapterURL: chapter.url)
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
        if cache {
            await store.saveContent(content, bookID: book.id)
        }
        return content
    }

    /// Fetches one chapter, strips ads, and writes the result to disk.
    ///
    /// The cache is written after the strip so background prefetch and speech
    /// look-ahead never see the raw body. `cache: false` (a trial read) keeps
    /// the cleanup in memory only.
    ///
    /// Background prefetch does *not* come through here: it would fire one
    /// model call per prefetched chapter, and a reader who opens a book and
    /// closes it would pay for chapters they never read. The first time such a
    /// chapter is opened, the strip runs then.
    func chapterContentPrepared(
        book: Book,
        chapter: Chapter,
        cache: Bool = true
    ) async throws -> ChapterContent {
        let content = try await chapterContent(book: book, chapter: chapter, cache: cache)
        return await autoCleanIfNeeded(content, chapter: chapter, bookID: book.id, cache: cache)
    }

    func aiClean(
        _ content: ChapterContent,
        task: AIPrompt.ChapterTask,
        format: AIPrompt.OutputFormat = .paragraphs,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ChapterContent {
        guard settings.ai.isUsable else { throw AIError.notConfigured }
        let client = AIClient(configuration: settings.ai)
        let cleaned = try await client.cleanChapter(
            content.text,
            instruction: task,
            customInstruction: settings.ai.customInstruction,
            format: format,
            progress: progress
        )
        let result = ChapterContent(
            chapterURL: content.chapterURL,
            text: TextProcessing.cleanupChapterText(cleaned),
            cleaned: true,
            // Keep the downloaded text so a cleanup can be undone without a
            // network round trip.
            originalText: content.originalText ?? content.text
        )
        return result
    }

    /// Fetches one chapter and writes it to disk without touching the reader
    /// state. Returns false when the chapter could not be cached (offline,
    /// paywall, deleted source), so callers can count failures.
    @discardableResult
    func cacheChapter(book: Book, chapter: Chapter) async -> Bool {
        if await store.loadContent(bookID: book.id, chapterURL: chapter.url) != nil {
            return true
        }
        if chapter.url.hasPrefix("local://") {
            return false
        }
        guard let source = sources.first(where: { $0.id == book.sourceID }) else { return false }
        do {
            let content = try await engine.fetchContent(book: book, chapter: chapter, source: source)
            await store.saveContent(content, bookID: book.id)
            return true
        } catch {
            return false
        }
    }

    func persistContent(_ content: ChapterContent, for book: Book) {
        let bookID = book.id
        Task { await store.saveContent(content, bookID: bookID) }
    }

    /// Strips ads and the site's trailers before a chapter is shown.
    ///
    /// Runs on the text just downloaded, so the cleaned copy is what gets
    /// cached and what the reader, the prefetch and the speech look-ahead all
    /// see — cleaning later would leave every path downstream reading the raw
    /// body. A failure returns the original: a chapter with an ad line in it is
    /// still readable, and failing the whole load would be worse.
    func autoCleanIfNeeded(
        _ content: ChapterContent,
        chapter: Chapter,
        bookID: UUID,
        cache: Bool
    ) async -> ChapterContent {
        // Local sample chapters are ours, not scraped: nothing to strip, and an
        // API call there would only spend quota.
        guard !chapter.url.hasPrefix("local://"),
              AutoCleanup.shouldRun(
                  content: content,
                  enabled: settings.aiAutoClean && settings.ai.isUsable,
                  chapterTitle: chapter.title
              ) else {
            return content
        }
        do {
            // A fixed format, not the user's manual choice: the manual options
            // re-flow paragraphs, which the automatic pass deliberately avoids.
            let cleaned = try await aiClean(content, task: .stripAds, format: .paragraphs)
            // The model occasionally returns an empty string (it treated the
            // whole chapter as junk). Showing a blank page is worse than the
            // ads, so keep the original in that case.
            guard !cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return content
            }
            if cache {
                await store.saveContent(cleaned, bookID: bookID)
            }
            return cleaned
        } catch {
            showBanner(AutoCleanup.failureMessage(chapterTitle: chapter.title), isError: true)
            return content
        }
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
        let candidates = sources.filter {
            $0.enabled && $0.type == .text && $0.canSearch && $0.id != book.sourceID && !$0.isBuiltIn
        }
        return await searchMatches(keyword: book.name, authorHint: book.author, in: candidates)
    }

    /// Searches `candidates` and ranks the hits by how likely they are the same
    /// book.
    ///
    /// See `SourceMatcher`: author is only a tie-breaker, because mirrors
    /// routinely mislabel it.
    func searchMatches(keyword: String, authorHint: String, in candidates: [BookSource]) async -> [SearchResult] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !candidates.isEmpty else { return [] }

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

        return SourceMatcher.rank(collected, wantedTitle: query, wantedAuthor: authorHint)
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
            // Probe only. Caching it would leave an orphan file: `switchSource`
            // clears the cache anyway, and if the user backs out the URL belongs
            // to a site this book is not on.
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
        // Cached bodies are keyed by the old site's chapter URLs; leaving them
        // behind wastes space and confuses anything that matches by URL.
        await store.clearChapterCache(bookID: updated.id)
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
