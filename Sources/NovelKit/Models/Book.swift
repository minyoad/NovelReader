import Foundation

/// A book that lives on the user's shelf.
public struct Book: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// ID of the `BookSource` this book came from.
    public var sourceID: UUID
    /// Human readable source name, kept for display when the source is gone.
    public var sourceName: String
    /// Absolute URL of the book detail page on the source site.
    public var detailURL: String
    public var name: String
    public var author: String
    public var intro: String
    public var kind: String
    public var coverURL: String?
    public var lastChapterTitle: String
    public var updateTime: String
    public var wordCount: String
    /// URL of the table of contents, when the source exposes one separately.
    public var tocURL: String?

    public var progress: ReadingProgress
    public var addedAt: Date
    public var lastReadAt: Date?

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        sourceName: String,
        detailURL: String,
        name: String,
        author: String = "",
        intro: String = "",
        kind: String = "",
        coverURL: String? = nil,
        lastChapterTitle: String = "",
        updateTime: String = "",
        wordCount: String = "",
        tocURL: String? = nil,
        progress: ReadingProgress = ReadingProgress(),
        addedAt: Date = Date(),
        lastReadAt: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.detailURL = detailURL
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.coverURL = coverURL
        self.lastChapterTitle = lastChapterTitle
        self.updateTime = updateTime
        self.wordCount = wordCount
        self.tocURL = tocURL
        self.progress = progress
        self.addedAt = addedAt
        self.lastReadAt = lastReadAt
    }
}

public struct ReadingProgress: Codable, Hashable, Sendable {
    /// Index into the chapter list.
    public var chapterIndex: Int
    /// Character offset inside the chapter text, used to restore the scroll position.
    public var characterOffset: Int
    public var chapterTitle: String
    public var updatedAt: Date?

    public init(chapterIndex: Int = 0, characterOffset: Int = 0, chapterTitle: String = "", updatedAt: Date? = nil) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.chapterTitle = chapterTitle
        self.updatedAt = updatedAt
    }

    public var isStarted: Bool { updatedAt != nil }
}

public struct Chapter: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url }
    public var index: Int
    public var title: String
    public var url: String
    public var isVIP: Bool
    public var isVolume: Bool

    public init(index: Int, title: String, url: String, isVIP: Bool = false, isVolume: Bool = false) {
        self.index = index
        self.title = title
        self.url = url
        self.isVIP = isVIP
        self.isVolume = isVolume
    }
}

public struct ChapterContent: Codable, Hashable, Sendable {
    public var chapterURL: String
    public var text: String
    /// True when the text went through an AI cleanup pass.
    public var cleaned: Bool
    public var fetchedAt: Date

    public init(chapterURL: String, text: String, cleaned: Bool = false, fetchedAt: Date = Date()) {
        self.chapterURL = chapterURL
        self.text = text
        self.cleaned = cleaned
        self.fetchedAt = fetchedAt
    }
}

/// One row in the search results list.
public struct SearchResult: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(sourceID)|\(detailURL)" }
    public var sourceID: UUID
    public var sourceName: String
    public var name: String
    public var author: String
    public var kind: String
    public var lastChapterTitle: String
    public var updateTime: String
    public var intro: String
    public var coverURL: String?
    public var detailURL: String
    /// Populated once the book is on the shelf.
    public var shelfBookID: UUID?

    public init(
        sourceID: UUID,
        sourceName: String,
        name: String,
        author: String = "",
        kind: String = "",
        lastChapterTitle: String = "",
        updateTime: String = "",
        intro: String = "",
        coverURL: String? = nil,
        detailURL: String
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.name = name
        self.author = author
        self.kind = kind
        self.lastChapterTitle = lastChapterTitle
        self.updateTime = updateTime
        self.intro = intro
        self.coverURL = coverURL
        self.detailURL = detailURL
    }
}

/// A downloaded table of contents plus the extra metadata we learned while fetching it.
public struct BookSnapshot: Codable, Sendable {
    public var book: Book
    public var chapters: [Chapter]
    public var fetchedAt: Date

    public init(book: Book, chapters: [Chapter], fetchedAt: Date = Date()) {
        self.book = book
        self.chapters = chapters
        self.fetchedAt = fetchedAt
    }
}
