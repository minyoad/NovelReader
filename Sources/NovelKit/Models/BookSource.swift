import Foundation

public enum SourceType: Int, Codable, Hashable, Sendable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
}

/// Rules used to turn a search / explore result page into book entries.
public struct SearchRule: Codable, Hashable, Sendable {
    public var bookList: String
    public var name: String
    public var author: String
    public var intro: String
    public var kind: String
    public var lastChapter: String
    public var updateTime: String
    public var bookURL: String
    public var coverURL: String
    public var wordCount: String
    /// Optional rule that guards against bogus results (e.g. "type" pages).
    public var checkKeyWord: String?

    public init(
        bookList: String = "",
        name: String = "",
        author: String = "",
        intro: String = "",
        kind: String = "",
        lastChapter: String = "",
        updateTime: String = "",
        bookURL: String = "",
        coverURL: String = "",
        wordCount: String = "",
        checkKeyWord: String? = nil
    ) {
        self.bookList = bookList
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.bookURL = bookURL
        self.coverURL = coverURL
        self.wordCount = wordCount
        self.checkKeyWord = checkKeyWord
    }

    public var isEmpty: Bool { bookList.isEmpty }
}

public struct BookInfoRule: Codable, Hashable, Sendable {
    public var name: String
    public var author: String
    public var intro: String
    public var kind: String
    public var lastChapter: String
    public var updateTime: String
    public var coverURL: String
    public var tocURL: String
    public var wordCount: String

    public init(
        name: String = "",
        author: String = "",
        intro: String = "",
        kind: String = "",
        lastChapter: String = "",
        updateTime: String = "",
        coverURL: String = "",
        tocURL: String = "",
        wordCount: String = ""
    ) {
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.coverURL = coverURL
        self.tocURL = tocURL
        self.wordCount = wordCount
    }

    public static let empty = BookInfoRule()
}

public struct TOCRule: Codable, Hashable, Sendable {
    public var chapterList: String
    public var chapterName: String
    public var chapterURL: String
    public var isVIP: String
    public var isVolume: String
    public var updateTime: String
    /// Rule that yields links to the next page of the table of contents.
    public var nextTOCURL: String

    public init(
        chapterList: String = "",
        chapterName: String = "",
        chapterURL: String = "",
        isVIP: String = "",
        isVolume: String = "",
        updateTime: String = "",
        nextTOCURL: String = ""
    ) {
        self.chapterList = chapterList
        self.chapterName = chapterName
        self.chapterURL = chapterURL
        self.isVIP = isVIP
        self.isVolume = isVolume
        self.updateTime = updateTime
        self.nextTOCURL = nextTOCURL
    }
}

public struct ContentRule: Codable, Hashable, Sendable {
    public var content: String
    public var nextContentURL: String
    /// Regex the source uses to hide the real text (e.g. anti-scraping paragraphs).
    public var sourceRegex: String
    /// Applied to the extracted text: `regex##replacement##` chunks.
    public var replaceRegex: String
    public var imageStyle: String

    public init(
        content: String = "",
        nextContentURL: String = "",
        sourceRegex: String = "",
        replaceRegex: String = "",
        imageStyle: String = ""
    ) {
        self.content = content
        self.nextContentURL = nextContentURL
        self.sourceRegex = sourceRegex
        self.replaceRegex = replaceRegex
        self.imageStyle = imageStyle
    }
}

/// A book source, modeled after the widely used legado ("阅读") JSON format.
public struct BookSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var group: String
    public var comment: String
    public var type: SourceType
    public var enabled: Bool
    public var enabledExplore: Bool
    /// Raw header configuration, either JSON or `Key: Value` lines.
    public var header: String
    public var searchURL: String
    public var exploreURL: String
    public var search: SearchRule
    public var explore: SearchRule
    public var bookInfo: BookInfoRule
    public var toc: TOCRule
    public var content: ContentRule
    public var isBuiltIn: Bool
    /// Kept verbatim so the user can inspect / re-export a source.
    public var originalJSON: String?
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        group: String = "",
        comment: String = "",
        type: SourceType = .text,
        enabled: Bool = true,
        enabledExplore: Bool = false,
        header: String = "",
        searchURL: String = "",
        exploreURL: String = "",
        search: SearchRule = SearchRule(),
        explore: SearchRule = SearchRule(),
        bookInfo: BookInfoRule = .empty,
        toc: TOCRule = TOCRule(),
        content: ContentRule = ContentRule(),
        isBuiltIn: Bool = false,
        originalJSON: String? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.group = group
        self.comment = comment
        self.type = type
        self.enabled = enabled
        self.enabledExplore = enabledExplore
        self.header = header
        self.searchURL = searchURL
        self.exploreURL = exploreURL
        self.search = search
        self.explore = explore
        self.bookInfo = bookInfo
        self.toc = toc
        self.content = content
        self.isBuiltIn = isBuiltIn
        self.originalJSON = originalJSON
        self.lastUsedAt = lastUsedAt
    }

    public var host: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    public var canSearch: Bool { !searchURL.isEmpty }

    /// The rules a category falls back to when it has none of its own.
    ///
    /// Legado sources are often written with `ruleExplore` left as `{}` while
    /// `exploreUrl` lists dozens of categories — the author expected the
    /// discover listing to share `ruleSearch`, because the two pages render
    /// the same markup. Falling back keeps those sources usable instead of
    /// offering tabs that cannot parse anything.
    public var fallbackExploreRule: SearchRule {
        explore.bookList.isEmpty ? search : explore
    }

    /// A discover page needs both a category list and a way to read it.
    ///
    /// A source with nothing usable must not be offered at all, so the reader
    /// never sees a source that only produces errors.
    public var canExplore: Bool {
        guard enabledExplore, !exploreURL.isEmpty else { return false }
        return ExploreParser.categories(from: exploreURL)
            .contains { $0.canOpen(exploreRules: fallbackExploreRule) }
    }
    /// The categories that can actually be opened, in source order.
    public var openableExploreCategories: [ExploreCategory] {
        ExploreParser.categories(from: exploreURL)
            .filter { $0.canOpen(exploreRules: fallbackExploreRule) }
    }
}
