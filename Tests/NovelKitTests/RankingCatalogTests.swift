import Foundation
import Testing
@testable import NovelKit

struct RankingCatalogTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func desktopRankingRequestDoesNotInheritMobileUserAgent() {
        // The app defaults to iPhone Safari; that UA redirects the desktop
        // ranking URL to an incompatible mobile endpoint.
        #expect(NetworkSettings.defaultUserAgent.contains("iPhone"))
        let request = RankingCatalog.request(for: .zongheng)
        #expect(request.url == "https://www.zongheng.com/rank")
        let userAgent = request.headers["User-Agent"] ?? ""
        #expect(userAgent.contains("Windows NT"))
        #expect(!userAgent.contains("iPhone"))
        #expect(!userAgent.contains("Mobile"))
        // Other providers continue using the caller's network settings.
        #expect(RankingCatalog.request(for: .jinjiang).headers["User-Agent"] == nil)
    }

    @Test func zonghengHomepageKeepsIndependentRanks() throws {
        let result = try RankingCatalog.parse(fixture("rank-zongheng"), provider: .zongheng)
        #expect(result.boards.map(\.title) == ["月票榜", "24小时畅销榜", "新书榜"])
        #expect(result.boards.map { $0.books.count } == [10, 10, 10])
        #expect(result.boards[0].books[0].name == "无敌天命")
        #expect(result.boards[0].books[0].author == "青鸾峰上")
        #expect(result.boards[0].books[1].author.isEmpty)
        #expect(result.boards[0].books.map(\.position) == Array(1...10))
        #expect(result.boards[0].books[0].url.absoluteString == "https://www.zongheng.com/detail/1336976")
        #expect(result.boards[1].books[0].name == "无敌天命")
    }

    @Test func jinjiangColumnsDoNotMixRankings() throws {
        let result = try RankingCatalog.parse(fixture("rank-jinjiang"), provider: .jinjiang)
        #expect(result.boards.map(\.title) == ["月度排行榜", "季度排行榜", "半年排行榜", "新晋作者榜"])
        #expect(result.boards.allSatisfy { !$0.books.isEmpty && $0.books.first?.position == 1 })
        #expect(result.boards.allSatisfy { Set($0.books.map(\.id)).count == $0.books.count })
        #expect(result.boards[0].url.absoluteString == "https://m.jjwxc.net/rank/naturalmore/5")
        #expect(result.boards.flatMap(\.books).allSatisfy { !$0.name.contains("�") && $0.url.host == "m.jjwxc.net" })
    }

    @Test func invalidPagesDoNotReplaceCachedRankings() throws {
        for provider in RankingProvider.allCases {
            #expect(throws: RankingError.self) { try RankingCatalog.parse("<html>正在加载</html>", provider: provider) }
        }
    }

    @Test func cacheExpiryAndPersistence() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try RankingCatalog.parse(fixture("rank-zongheng"), provider: .zongheng, now: now)
        #expect(snapshot.isFresh(now: now.addingTimeInterval(6 * 3600 - 1)))
        #expect(!snapshot.isFresh(now: now.addingTimeInterval(6 * 3600)))
        #expect(!snapshot.isFresh(now: now.addingTimeInterval(-1)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        await store.saveRankings(snapshot)
        let older = try RankingCatalog.parse(fixture("rank-zongheng"), provider: .zongheng, now: now.addingTimeInterval(-100))
        await store.saveRankings(older)
        let saved = await store.loadRankings(.zongheng)
        #expect(saved?.updatedAt == now)
        #expect(saved?.boards[0].books[0].name == snapshot.boards[0].books[0].name)
        #expect(await store.loadRankings(.jinjiang) == nil)
    }
}
