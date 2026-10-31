import Foundation

/// File based persistence. Small enough to stay dependency free, structured so
/// it can be swapped for SQLite later without touching the UI.
public actor LibraryStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// How many utterances can be written between cache sweeps.
    ///
    /// 20 chunks is roughly a chapter, so the cache never drifts far past its
    /// cap while the directory scan stays off the hot path.
    static let speechTrimInterval = 20
    private var speechWritesSinceTrim = 0

    public init(directory: URL? = nil) {
        let base = directory ?? LibraryStore.defaultDirectory()
        self.directory = base

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("speech"), withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        #if os(iOS)
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        #else
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        #endif
        return base.appendingPathComponent("NovelReader", isDirectory: true)
    }

    // MARK: - Books

    public func loadBooks() -> [Book] {
        read([Book].self, from: "books.json") ?? []
    }

    public func saveBooks(_ books: [Book]) {
        write(books, to: "books.json")
    }

    // MARK: - Sources

    public func loadSources() -> [BookSource] {
        read([BookSource].self, from: "sources.json") ?? []
    }

    public func saveSources(_ sources: [BookSource]) {
        write(sources, to: "sources.json")
    }

    // MARK: - Settings

    public func loadSettings() -> AppSettings {
        read(AppSettings.self, from: "settings.json") ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) {
        write(settings, to: "settings.json")
    }

    // MARK: - Bootstrap flags

    /// One-shot launch flags (e.g. "preset sources have been seeded"). Kept in
    /// its own file so resetting settings does not re-run first-launch work.
    public func isFlagSet(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: flagURL(name).path)
    }

    public func setFlag(_ name: String) {
        try? FileManager.default.createDirectory(at: flagURL(name).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("1".utf8).write(to: flagURL(name), options: .atomic)
    }

    private func flagURL(_ name: String) -> URL {
        directory.appendingPathComponent("flags/\(name).flag")
    }

    // MARK: - Chapters

    public func loadChapters(bookID: UUID) -> [Chapter]? {
        read([Chapter].self, from: "chapters/\(bookID.uuidString)-toc.json")
    }

    public func saveChapters(_ chapters: [Chapter], bookID: UUID) {
        write(chapters, to: "chapters/\(bookID.uuidString)-toc.json")
    }

    public func loadContent(bookID: UUID, chapterURL: String) -> ChapterContent? {
        read(ChapterContent.self, from: contentPath(bookID: bookID, chapterURL: chapterURL))
    }

    public func saveContent(_ content: ChapterContent, bookID: UUID) {
        write(content, to: contentPath(bookID: bookID, chapterURL: content.chapterURL))
    }

    public func deleteContent(bookID: UUID, chapterURL: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(contentPath(bookID: bookID, chapterURL: chapterURL)))
    }

    public func clearChapterCache(bookID: UUID) {
        let folder = directory.appendingPathComponent("chapters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(bookID.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func cachedChapterCount(bookID: UUID) -> Int {
        let folder = directory.appendingPathComponent("chapters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { $0.lastPathComponent.hasPrefix(bookID.uuidString) && !$0.lastPathComponent.hasSuffix("-toc.json") }.count
    }

    /// Chapter URLs that already have a body on disk, mapped back from the file
    /// names via the saved table of contents (the file name is only a hash).
    public func cachedChapterURLs(bookID: UUID) -> Set<String> {
        let chapters = loadChapters(bookID: bookID) ?? []
        guard !chapters.isEmpty else { return [] }
        let folder = directory.appendingPathComponent("chapters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let present = Set(files.map { $0.lastPathComponent })

        var result: Set<String> = []
        for chapter in chapters {
            let name = "\(bookID.uuidString)-\(StableHash.hex(chapter.url)).json"
            if present.contains(name) { result.insert(chapter.url) }
        }
        return result
    }

    /// Byte size of one book's cached bodies (table of contents excluded).
    public func cachedSize(bookID: UUID) -> Int64 {
        let folder = directory.appendingPathComponent("chapters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for file in files where file.lastPathComponent.hasPrefix(bookID.uuidString)
            && !file.lastPathComponent.hasSuffix("-toc.json") {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Total bytes used by every book's chapter cache.
    public func totalCachedSize() -> Int64 {
        let folder = directory.appendingPathComponent("chapters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for file in files where !file.lastPathComponent.hasSuffix("-toc.json") {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Synthesized speech

    /// Where cached utterances live.
    ///
    /// Kept apart from `chapters/` so clearing one never touches the other: a
    /// reader who runs out of space wants to drop audio without losing the
    /// offline copy of the text they are reading.
    public var speechDirectory: URL {
        directory.appendingPathComponent("speech", isDirectory: true)
    }

    public func speechFileURL(key: String) -> URL {
        speechDirectory.appendingPathComponent("\(key).mp3")
    }

    public func hasSpeech(key: String) -> Bool {
        FileManager.default.fileExists(atPath: speechFileURL(key: key).path)
    }

    /// Bumps the access time so eviction treats a replayed utterance as recent.
    ///
    /// The modification date doubles as "last used" on purpose: it costs no
    /// extra index file, and a half-written cache can never disagree with it.
    public func touchSpeech(key: String) {
        let url = speechFileURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    public func saveSpeech(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: speechDirectory, withIntermediateDirectories: true)
        try? data.write(to: speechFileURL(key: key), options: .atomic)
    }

    /// Saves an utterance and enforces the size cap.
    ///
    /// Trimming on every write would stat the whole directory once per
    /// sentence — with a 300 MB cache that is thousands of entries per
    /// sentence read aloud. Instead the sweep runs every `speechTrimInterval`
    /// saves, which keeps the cap approximate but the cost amortised to
    /// nothing.
    public func saveSpeech(_ data: Data, key: String, limitBytes: Int64) {
        saveSpeech(data, key: key)
        speechWritesSinceTrim += 1
        guard speechWritesSinceTrim >= Self.speechTrimInterval else { return }
        speechWritesSinceTrim = 0
        trimSpeechCache(limitBytes: limitBytes)
    }

    public func loadSpeech(key: String) -> Data? {
        try? Data(contentsOf: speechFileURL(key: key))
    }

    public func speechEntries() -> [(key: String, size: Int64, lastUsed: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: speechDirectory,
            includingPropertiesForKeys: keys
        ) else { return [] }

        let fallback = Date(timeIntervalSince1970: 0)
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (
                key: file.deletingPathExtension().lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                lastUsed: values.contentModificationDate ?? fallback
            )
        }
    }

    public func speechCacheCount() -> Int {
        speechEntries().count
    }

    public func speechCacheSize() -> Int64 {
        speechEntries().reduce(Int64(0)) { $0 + $1.size }
    }

    /// Deletes least-recently-used utterances until the cache fits.
    ///
    /// Returns what was freed so the settings screen can report it without a
    /// second scan.
    @discardableResult
    public func trimSpeechCache(limitBytes: Int64) -> (removed: Int, freed: Int64) {
        guard limitBytes > 0 else { return (0, 0) }
        let entries = speechEntries()
        let doomed = SpeechCachePolicy.evictionOrder(entries: entries, limitBytes: limitBytes)
        guard !doomed.isEmpty else { return (0, 0) }

        let sizes = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.size) })
        var freed: Int64 = 0
        var removed = 0
        for key in doomed {
            let url = speechFileURL(key: key)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                freed += sizes[key] ?? 0
                removed += 1
            }
        }
        return (removed, freed)
    }

    @discardableResult
    public func clearSpeechCache() -> (removed: Int, freed: Int64) {
        let entries = speechEntries()
        guard !entries.isEmpty else { return (0, 0) }
        var freed: Int64 = 0
        var removed = 0
        for entry in entries {
            let url = speechFileURL(key: entry.key)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                freed += entry.size
                removed += 1
            }
        }
        return (removed, freed)
    }

    // MARK: - IO

    private func contentPath(bookID: UUID, chapterURL: String) -> String {
        "chapters/\(bookID.uuidString)-\(StableHash.hex(chapterURL)).json"
    }

    private func read<T: Decodable>(_ type: T.Type, from relativePath: String) -> T? {
        let url = directory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to relativePath: String) {
        let url = directory.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Stable across launches (unlike `Hashable`'s seeded hashing), used for file names.
public enum StableHash {
    public static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
