import Foundation
import SwiftSoup

public enum RankingProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case zongheng, jinjiang
    public var id: String { rawValue }
    public var name: String { self == .zongheng ? "纵横" : "晋江" }
    public var url: URL {
        URL(string: self == .zongheng ? "https://www.zongheng.com/rank" : "https://m.jjwxc.net/rank")!
    }
}

/// Ranking metadata is deliberately independent of readable SearchResults.
public struct RankedBook: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let name: String
    public let author: String
    public let position: Int
    public let url: URL
}

public struct BookRanking: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let books: [RankedBook]
}

public struct RankingSnapshot: Codable, Sendable {
    public let version: Int
    public let provider: RankingProvider
    public let updatedAt: Date
    public let boards: [BookRanking]
    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return version == 1 && !boards.isEmpty && age >= 0 && age < 6 * 3600
    }
}

public enum RankingError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "未能识别榜单内容，网站可能暂时不可用或页面结构已变化。" }
}

public enum RankingCatalog {
    /// The parser consumes the desktop SSR page. A mobile UA redirects this
    /// URL to m.zongheng.com, which serves a different page (or HTTP 500).
    /// Keep this override local so reading sources retain their configured UA.
    static func request(for provider: RankingProvider) -> HTTPRequest {
        var headers: [String: String] = [:]
        if provider == .zongheng {
            headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        }
        return HTTPRequest(url: provider.url.absoluteString, headers: headers)
    }

    public static func fetch(_ provider: RankingProvider, network: NetworkSettings) async throws -> RankingSnapshot {
        var settings = network
        settings.timeout = min(max(settings.timeout, 1), 8)
        let client = HTTPClient(settings: settings, maximumRetries: 0, resourceTimeout: 8,
                                maximumResponseBytes: 2 * 1024 * 1024)
        let page = try await client.fetch(request(for: provider))
        try Task.checkCancellation()
        return try parse(page.text, provider: provider)
    }

    public static func parse(_ html: String, provider: RankingProvider, now: Date = Date()) throws -> RankingSnapshot {
        let document = try SwiftSoup.parse(html, provider.url.absoluteString)
        var boards: [BookRanking] = []
        if provider == .zongheng {
            // Official homepage summary order: monthly tickets, 24h sales, new books.
            // Detail ranking pages currently render their rows only with JavaScript.
            let definitions = [("monthly", "月票榜", "monthly-ticket", 1),
                               ("sales", "24小时畅销榜", "one-day", 3),
                               ("new", "新书榜", "new-book", 4)]
            let sections = try document.select(".rank-content-default__main .zh-modules-rank").array()
            guard sections.count >= definitions.count else { throw RankingError.unavailable }
            for (index, definition) in definitions.enumerated() {
                let (id, title, nav, type) = definition
                let url = URL(string: "https://www.zongheng.com/rank?nav=\(nav)&rankType=\(type)")!
                let rows = try sections[index].select(".zh-modules-rank-book").array()
                var books: [RankedBook] = []
                var seen = Set<String>()
                for (position, row) in rows.enumerated() {
                    guard let link = try row.select(".book-rank--title-text a").first(),
                          let book = try book(link, author: row.select("a[href*=userInfo]").text(),
                                              position: position + 1, provider: provider),
                          seen.insert(book.id).inserted else { continue }
                    books.append(book)
                }
                if !books.isEmpty { boards.append(BookRanking(id: id, title: title, url: url, books: books)) }
            }
        } else {
            // Each module contains two named columns. Read the heading and its
            // matching column together, rather than flattening unrelated lists.
            let allowed = ["5": "月度排行榜", "6": "季度排行榜", "30": "半年排行榜", "29": "新晋作者榜"]
            for module in try document.select(".module").array() {
                let headings = try module.select("h2 a.channellink").array()
                let columns = try module.select("table.double_column td").array()
                guard headings.count == columns.count else { continue }
                for (heading, column) in zip(headings, columns) {
                    let path = try heading.attr("href")
                    guard let id = path.split(separator: "/").last.map(String.init),
                          let title = allowed[id], path.hasPrefix("/rank/naturalmore/") else { continue }
                    var books: [RankedBook] = []
                    var seen = Set<String>()
                    for (position, link) in try column.select("li a[href^=/book2/]").array().enumerated() {
                        if let book = try book(link, author: "", position: position + 1, provider: provider),
                           seen.insert(book.id).inserted { books.append(book) }
                    }
                    if !books.isEmpty {
                        boards.append(BookRanking(id: id, title: title,
                                                  url: URL(string: path, relativeTo: provider.url)!.absoluteURL,
                                                  books: Array(books.prefix(50))))
                    }
                }
            }
        }
        guard !boards.isEmpty else { throw RankingError.unavailable }
        return RankingSnapshot(version: 1, provider: provider, updatedAt: now, boards: boards)
    }

    private static func book(_ link: Element, author: String, position: Int,
                             provider: RankingProvider) throws -> RankedBook? {
        let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, !name.contains("\u{FFFD}"),
              let url = URL(string: try link.attr("href"), relativeTo: provider.url)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host == provider.url.host else { return nil }
        return RankedBook(name: name, author: author.trimmingCharacters(in: .whitespacesAndNewlines),
                          position: position, url: url)
    }
}
