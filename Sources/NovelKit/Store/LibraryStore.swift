import Foundation

/// File based persistence. Small enough to stay dependency free, structured so
/// it can be swapped for SQLite later without touching the UI.
public actor LibraryStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
