import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One "书源合集" entry on yckceo.com/源仓库.
///
/// A collection is a curated bundle: a title, who published it, how many
/// sources it holds, and a JSON file with the actual legado sources. Users pick
/// a collection instead of hand-copying dozens of individual sources, which is
/// what the site is for.
public struct SourceCollection: Identifiable, Hashable, Sendable {
    /// The site's numeric id, e.g. `1326`.
    public var id: String
    public var title: String
    public var author: String
    /// How many sources the bundle contains, as reported by the site.
    public var sourceCount: Int
    public var downloadCount: Int
    /// Relative time as the site renders it ("2天前", "10/24 12:14").
    public var updatedText: String
    /// Direct link to the bundle's source JSON.
    public var jsonURL: String

    public init(
        id: String,
        title: String,
        author: String = "",
        sourceCount: Int = 0,
        downloadCount: Int = 0,
        updatedText: String = "",
        jsonURL: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceCount = sourceCount
        self.downloadCount = downloadCount
        self.updatedText = updatedText
        self.jsonURL = jsonURL
    }
}

/// What a collection's detail page shows: the blurb plus, usually, a table with
/// every source's name and site. That table is what lets people judge a bundle
/// before importing hundreds of sources.
public struct SourceCollectionDetail: Sendable {
    public struct Entry: Hashable, Sendable {
        public var name: String
        public var baseURL: String

        public init(name: String, baseURL: String) {
            self.name = name
            self.baseURL = baseURL
        }
    }

    public var collection: SourceCollection
    public var summary: String
    public var entries: [Entry]

    public init(collection: SourceCollection, summary: String = "", entries: [Entry] = []) {
        self.collection = collection
        self.summary = summary
        self.entries = entries
    }
}

/// One page of the collection list.
public struct SourceCollectionPage: Sendable {
    public var items: [SourceCollection]
    /// Total number of collections the site reports, not the page size.
    public var total: Int
    public var page: Int
    /// Page size is fixed by the site, but callers need it to know when to stop.
    public var pageSize: Int

    public init(items: [SourceCollection], total: Int, page: Int, pageSize: Int = 100) {
        self.items = items
        self.total = total
        self.page = page
        self.pageSize = pageSize
    }

    public var hasMore: Bool {
        !items.isEmpty && page * pageSize < total
    }
}

public enum SourceCollectionError: LocalizedError {
    case layoutChanged(String)
    case emptyJSON(String)

    public var errorDescription: String? {
        switch self {
        case .layoutChanged(let what): return "源仓库页面结构变了，读不出\(what)"
        case .emptyJSON(let id): return "合集 \(id) 的下载链接是空的"
        }
    }
}

/// Browses the "书源合集" section of 源仓库 (yckceo.com).
///
/// The site has no API: everything is server-rendered HTML plus a per-collection
/// JSON file. Parsing here is deliberately tolerant — a missing count or author
/// degrades the row instead of dropping the collection, because a layout tweak
/// on one small part of the page should not make the whole feature unusable.
public struct SourceCollectionClient: Sendable {
    public enum Order: String, Sendable {
        /// Newest first, the site's default.
        case updated
        /// Most downloaded first. A better proxy for "still works" than
        /// recency, since old bundles get fixed without changing their id.
        case downloads
    }

    public var client: HTTPClient
    /// Site root. Kept configurable so the mirror (yckceo.vip) can be used when
    /// the main domain is unreachable.
    public var site: String

    public init(client: HTTPClient, site: String = "https://www.yckceo.com") {
        self.client = client
        self.site = site
    }

    // MARK: - List

    public func list(page: Int = 1, keyword: String = "", order: Order = .updated) async throws -> SourceCollectionPage {
        var components = URLComponents(string: site + "/yuedu/shuyuans/index.html")!
        var query: [URLQueryItem] = []
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { query.append(URLQueryItem(name: "keys", value: trimmed)) }
        if page > 1 { query.append(URLQueryItem(name: "page", value: String(page))) }
        switch order {
        case .updated:
            query.append(URLQueryItem(name: "order1", value: "time"))
            query.append(URLQueryItem(name: "order2", value: "1"))
        case .downloads:
            query.append(URLQueryItem(name: "order1", value: "down"))
            query.append(URLQueryItem(name: "order2", value: "1"))
        }
        components.queryItems = query

        guard let url = components.url else { throw URLError(.badURL) }
        let fetched = try await client.fetch(HTTPRequest(url: url.absoluteString), retries: 1)
        let document = try SwiftSoup.parse(fetched.text)

        var items: [SourceCollection] = []
        for card in try document.select("div.ylist").array() {
            guard let anchor = try card.select("h2 a").first(),
                  let href = try? anchor.attr("href"),
                  let id = Self.collectionID(fromHref: href) else { continue }

            let title = (try? anchor.text()) ?? ""
            if title.isEmpty { continue }

            let badgeText = try card.select("span").array()
                .compactMap { try? $0.text() }
                .joined(separator: " ")

            items.append(SourceCollection(
                id: id,
                title: title,
                author: Self.author(from: badgeText),
                sourceCount: Self.number(after: "源数量", in: badgeText) ?? 0,
                downloadCount: Self.number(after: "下载", in: badgeText) ?? 0,
                updatedText: (try? card.select("p.m-right").first()?.text()) ?? "",
                jsonURL: jsonURL(for: id)
            ))
        }

        if items.isEmpty {
            // An empty page is legitimate for a search with no hits, but a page
            // with no cards *and* no result count means the markup moved.
            let text = fetched.text
            if !text.contains("条数据") {
                throw SourceCollectionError.layoutChanged("合集列表")
            }
        }

        let total = Self.total(from: fetched.text) ?? items.count
        return SourceCollectionPage(items: items, total: total, page: page)
    }

    // MARK: - Detail

    public func detail(for collection: SourceCollection) async throws -> SourceCollectionDetail {
        guard let url = URL(string: site + "/yuedu/shuyuans/content/id/\(collection.id).html") else {
            throw URLError(.badURL)
        }
        let fetched = try await client.fetch(HTTPRequest(url: url.absoluteString), retries: 1)
        let document = try SwiftSoup.parse(fetched.text)

        var resolved = collection
        if let heading = try document.select("h1").first(), let title = try? heading.text(), !title.isEmpty {
            resolved.title = title
        }

        // The header is a blockquote with two lines: author, then
        // "count · size · downloads".
        if let quote = try document.select("blockquote").first() {
            let lines = try quote.select("p").array().map { (try? $0.text()) ?? "" }
            if lines.count > 1, let count = Self.leadingNumber(in: lines[1]) { resolved.sourceCount = count }
            if lines.count > 1, let downloads = Self.trailingNumber(in: lines[1]) { resolved.downloadCount = downloads }
        }

        var summary = ""
        if let body = try document.select("div.contents").first() {
            summary = ((try? body.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var jsonURL = resolved.jsonURL
        if let input = try document.select("input#jsonurl").first() {
            let value = ((try? input.attr("value")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { jsonURL = value }
        }
        resolved.jsonURL = jsonURL

        var entries: [SourceCollectionDetail.Entry] = []
        for row in try document.select("table tbody tr").array() {
            let cells = try row.select("td").array().map { ((try? $0.text()) ?? "").trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, !cells[0].isEmpty else { continue }
            entries.append(SourceCollectionDetail.Entry(name: cells[0], baseURL: cells[1]))
        }

        return SourceCollectionDetail(collection: resolved, summary: summary, entries: entries)
    }

    // MARK: - Download

    /// Fetches the bundle's legado JSON, ready for `LegadoImporter`.
    public func jsonData(for collection: SourceCollection) async throws -> Data {
        let target = collection.jsonURL.isEmpty ? jsonURL(for: collection.id) : collection.jsonURL
        guard let url = URL(string: target), !target.isEmpty else {
            throw SourceCollectionError.emptyJSON(collection.id)
        }
        let fetched = try await client.fetch(HTTPRequest(url: url.absoluteString), retries: 1)
        guard !fetched.data.isEmpty else { throw SourceCollectionError.emptyJSON(collection.id) }
        return fetched.data
    }

    // MARK: - Parsing helpers

    public func jsonURL(for id: String) -> String {
        site + "/yuedu/shuyuans/json/id/\(id).json"
    }

    /// `/yuedu/shuyuans/content/id/1326.html` → `1326`
    static func collectionID(fromHref href: String) -> String? {
        guard let match = RegexHelper.firstMatch("/content/id/(\\d+)", in: href, group: 1) else { return nil }
        return match
    }

    /// `用户: ffoef` → `ffoef`
    static func author(from badges: String) -> String {
        guard let match = RegexHelper.firstMatch("用户[:：]\\s*([^\\s]+)", in: badges, group: 1) else { return "" }
        return match
    }

    /// `源数量:320` with label `源数量` → `320`
    static func number(after label: String, in text: String) -> Int? {
        let pattern = NSRegularExpression.escapedPattern(for: label) + "[:：]\\s*(\\d+)"
        guard let match = RegexHelper.firstMatch(pattern, in: text, group: 1) else { return nil }
        return Int(match)
    }

    /// `共有 807 条数据` → `807`
    static func total(from text: String) -> Int? {
        guard let match = RegexHelper.firstMatch("共有\\s*(\\d+)\\s*条数据", in: text, group: 1) else { return nil }
        return Int(match)
    }

    static func leadingNumber(in text: String) -> Int? {
        guard let match = RegexHelper.firstMatch("^\\s*(\\d+)", in: text, group: 1) else { return nil }
        return Int(match)
    }

    static func trailingNumber(in text: String) -> Int? {
        guard let match = RegexHelper.firstMatch("(\\d+)\\s*$", in: text, group: 1) else { return nil }
        return Int(match)
    }
}
