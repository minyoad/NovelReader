import XCTest
import SwiftSoup
@testable import NovelKit

/// Parsing tests for the 源仓库 (yckceo.com) 书源合集 browser.
///
/// The fixtures are real pages captured from the site, so a change in its
/// markup shows up here instead of as an empty list on the phone.
final class SourceCollectionClientTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "缺少测试样例 \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Listing

    func testListParsesTheFirstPage() throws {
        let document = try SwiftSoup.parse(try fixture("yck-collections.html"))
        let cards = try document.select("div.ylist").array()

        // 100 per page is the site's own page size; the count is asserted so a
        // markup change that silently drops rows fails loudly.
        XCTAssertEqual(cards.count, 100)

        let first = try XCTUnwrap(cards.first as Element?)
        let anchor = try XCTUnwrap(first.select("h2 a").first() as Element?)
        XCTAssertEqual(try anchor.attr("href"), "/yuedu/shuyuans/content/id/1329.html")
        XCTAssertEqual(try anchor.text(), "自用")

        let badges = try first.select("span").array().map { try $0.text() }.joined(separator: " ")
        XCTAssertTrue(badges.contains("用户: ffoef"))
        XCTAssertTrue(badges.contains("源数量:320"))
    }

    func testCollectionIDFromHref() {
        XCTAssertEqual(SourceCollectionClient.collectionID(fromHref: "/yuedu/shuyuans/content/id/1326.html"), "1326")
        XCTAssertEqual(SourceCollectionClient.collectionID(fromHref: "https://www.yckceo.com/yuedu/shuyuans/content/id/9.html"), "9")
        XCTAssertNil(SourceCollectionClient.collectionID(fromHref: "/yuedu/shuyuans/index.html"))
    }

    func testBadgeParsing() {
        let badges = "用户: ffoef 源数量:320 下载:4822"
        XCTAssertEqual(SourceCollectionClient.author(from: badges), "ffoef")
        XCTAssertEqual(SourceCollectionClient.number(after: "源数量", in: badges), 320)
        XCTAssertEqual(SourceCollectionClient.number(after: "下载", in: badges), 4822)
        XCTAssertNil(SourceCollectionClient.number(after: "源数量", in: "用户: x"))
    }

    func testTotalAndPaging() throws {
        let html = try fixture("yck-collections.html")
        XCTAssertEqual(SourceCollectionClient.total(from: html), 807)

        // Page 1 of 807 at 100 per page still has more; the last page does not.
        let first = SourceCollectionPage(items: (0..<100).map {
            SourceCollection(id: "\($0)", title: "t")
        }, total: 807, page: 1)
        XCTAssertTrue(first.hasMore)

        let last = SourceCollectionPage(items: [SourceCollection(id: "1", title: "t")], total: 807, page: 9)
        XCTAssertFalse(last.hasMore)
    }

    func testJsonURLIsBuiltFromTheID() {
        let client = SourceCollectionClient(client: HTTPClient(), site: "https://www.yckceo.com")
        XCTAssertEqual(
            client.jsonURL(for: "1326"),
            "https://www.yckceo.com/yuedu/shuyuans/json/id/1326.json"
        )
    }

    // MARK: - Detail

    func testDetailParsesSummaryAndSourceTable() throws {
        let document = try SwiftSoup.parse(try fixture("yck-collection-detail.html"))

        let h1 = try XCTUnwrap(document.select("h1").first() as Element?)
        XCTAssertEqual(try h1.text(), "精品书源")

        let jsonURL = try XCTUnwrap(document.select("input#jsonurl").first() as Element?)
        XCTAssertEqual(
            try jsonURL.attr("value"),
            "https://www.yckceo.com/yuedu/shuyuans/json/id/1326.json"
        )

        let summary = try XCTUnwrap(document.select("div.contents").first() as Element?)
        XCTAssertTrue(try summary.text().contains("可以稳定使用的书源"))

        let rows = try document.select("table tbody tr").array()
        XCTAssertEqual(rows.count, 11)
        let cells = try rows[0].select("td").array().map { try $0.text() }
        XCTAssertEqual(cells.first, "顶点小说（dingdian888）")
        XCTAssertEqual(cells.last, "https://www.dingdian888.com")
    }

    func testDetailHeaderNumbers() {
        // "用户: alanAlancc (15330)" / "11 31kb 6296"
        XCTAssertEqual(SourceCollectionClient.leadingNumber(in: "11 31kb 6296"), 11)
        XCTAssertEqual(SourceCollectionClient.trailingNumber(in: "11 31kb 6296"), 6296)
        XCTAssertNil(SourceCollectionClient.leadingNumber(in: "没有数字"))
    }

    // MARK: - Download + import

    /// The whole point of the feature: a collection's JSON must survive
    /// `LegadoImporter` and come out as usable sources.
    func testCollectionJSONImports() throws {
        let text = try fixture("yck-collection-1326.json")
        let result = try LegadoImporter.importSources(fromJSON: text)

        XCTAssertEqual(result.sources.count, 11)
        XCTAssertTrue(result.warnings.isEmpty, "不该有警告：\(result.warnings)")

        let deqi = try XCTUnwrap(result.sources.first { $0.name.contains("得奇") })
        XCTAssertEqual(deqi.baseURL.hasPrefix("https://www.deqixs.org"), true)
        XCTAssertFalse(deqi.search.bookList.isEmpty)
        XCTAssertFalse(deqi.content.content.isEmpty)
        // The site's bundle carries a group, which the shelf groups by.
        XCTAssertFalse(result.sources.filter { !$0.group.isEmpty }.isEmpty)
    }
}
