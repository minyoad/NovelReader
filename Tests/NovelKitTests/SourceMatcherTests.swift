import XCTest
@testable import NovelKit

final class SourceMatcherTests: XCTestCase {

    private func hit(_ name: String, _ author: String) -> SearchResult {
        SearchResult(
            sourceID: UUID(),
            sourceName: "测试源",
            name: name,
            author: author,
            detailURL: "https://example.org/book/1"
        )
    }

    /// Real case: bqg6 labels 《剑来》 with a bogus author, deqitxt has the real
    /// one. The bogus copy must still be offered, just ranked lower.
    func testWrongAuthorIsKeptButRankedLower() throws {
        let good = hit("剑来", "烽火戏诸侯")
        let mislabelled = hit("剑来", "手机可乐床")

        let ranked = SourceMatcher.rank([mislabelled, good], wantedTitle: "剑来", wantedAuthor: "烽火戏诸侯")

        XCTAssertEqual(ranked.count, 2, "作者不符也应保留，交回调用方验证正文")
        XCTAssertEqual(ranked.first?.author, "烽火戏诸侯")
        XCTAssertEqual(ranked.last?.author, "手机可乐床")
    }

    /// If the shelf's own author is the bogus one, the correct mirror must still
    /// beat unrelated books — this is what previously dropped every candidate.
    func testShelfWithBogusAuthorStillMatchesCorrectMirror() throws {
        let correct = hit("剑来", "烽火戏诸侯")
        let unrelated = hit("剑来杂谈", "浮生半日不得闲")

        let ranked = SourceMatcher.rank([unrelated, correct], wantedTitle: "剑来", wantedAuthor: "手机可乐床")

        XCTAssertEqual(ranked.map(\.author), ["烽火戏诸侯"], "同前缀的同人书必须被排除")
    }

    func testDifferentTitleIsRejected() {
        XCTAssertNil(SourceMatcher.score(
            candidateName: "剑来杂谈", candidateAuthor: "浮生半日不得闲",
            wantedTitle: "剑来", wantedAuthor: "烽火戏诸侯"
        ), "同前缀但作者不同的另一本书不能当成同一本")
        XCTAssertNil(SourceMatcher.score(
            candidateName: "剑来大纲", candidateAuthor: "",
            wantedTitle: "剑来", wantedAuthor: "烽火戏诸侯"
        ), "作者未知时也不接受前缀匹配，避免换成同人")

        // Same title core plus the same author: the extra word is decoration.
        XCTAssertNotNil(SourceMatcher.score(
            candidateName: "剑来（精校版）", candidateAuthor: "烽火戏诸侯",
            wantedTitle: "剑来", wantedAuthor: "烽火戏诸侯"
        ))
        // Contained the other way round, when the shelf title is decorated.
        XCTAssertNotNil(SourceMatcher.score(
            candidateName: "剑来", candidateAuthor: "烽火戏诸侯",
            wantedTitle: "剑来（精校版）", wantedAuthor: "烽火戏诸侯"
        ))
    }

    func testDecorationsAreStripped() {
        XCTAssertEqual(SourceMatcher.normalizedTitle("《剑来》"), "剑来")
        XCTAssertEqual(SourceMatcher.normalizedTitle("剑来（完结）"), "剑来完结")
        XCTAssertEqual(SourceMatcher.normalizedTitle("剑来最新章节"), "剑来")
        XCTAssertEqual(SourceMatcher.normalizedAuthor("作者：烽火戏诸侯"), "烽火戏诸侯")
    }

    /// Equal titles are ordered shortest-first so the plain listing wins.
    func testShorterTitleWinsOnTie() throws {
        let decorated = hit("剑来", "烽火戏诸侯")
        let plain = hit("剑来", "烽火戏诸侯")
        XCTAssertEqual(
            SourceMatcher.rank([decorated, plain], wantedTitle: "剑来", wantedAuthor: "烽火戏诸侯").count,
            2
        )
    }
}
