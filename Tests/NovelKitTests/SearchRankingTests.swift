import Foundation
import Testing
@testable import NovelKit

/// Results stream in one source at a time, so the list is re-ranked after
/// every answer. Ranking has to be stable: the same set of results always
/// produces the same order, otherwise rows would jump around while the search
/// is still running.
@Suite("Search result ranking")
struct SearchRankingTests {

    /// Mirrors `AppModel.rankResults`, which lives in the app target.
    static func rank(_ results: [SearchResult], for query: String) -> [SearchResult] {
        results.sorted { lhs, rhs in
            let lhsExact = lhs.name == query ? 0 : (lhs.name.contains(query) ? 1 : 2)
            let rhsExact = rhs.name == query ? 0 : (rhs.name.contains(query) ? 1 : 2)
            if lhsExact != rhsExact { return lhsExact < rhsExact }
            return lhs.name < rhs.name
        }
    }

    static func make(_ name: String, source: String = "s") -> SearchResult {
        SearchResult(
            sourceID: UUID(),
            sourceName: source,
            name: name,
            author: "",
            intro: "",
            detailURL: name
        )
    }

    @Test("an exact title comes first, then titles containing the query")
    func exactThenContains() {
        let results = [
            Self.make("长夜灯下后传"),
            Self.make("别的书"),
            Self.make("长夜灯下"),
        ]
        let ranked = Self.rank(results, for: "长夜灯下")
        #expect(ranked.map(\.name) == ["长夜灯下", "长夜灯下后传", "别的书"])
    }

    @Test("ranking is stable regardless of arrival order")
    func stableAcrossArrivalOrder() {
        let a = Self.make("长夜灯下")
        let b = Self.make("长夜灯下后传")
        let c = Self.make("别的书")

        let one = Self.rank([a, b, c], for: "长夜灯下").map(\.name)
        let two = Self.rank([c, b, a], for: "长夜灯下").map(\.name)
        let three = Self.rank([b, a, c], for: "长夜灯下").map(\.name)

        #expect(one == two)
        #expect(two == three)
    }

    @Test("ties fall back to title order so rows do not shuffle")
    func tiesAreOrdered() {
        let results = [
            Self.make("长夜灯下乙"),
            Self.make("长夜灯下甲"),
        ]
        let ranked = Self.rank(results, for: "长夜")
        #expect(ranked.map(\.name) == ["长夜灯下乙", "长夜灯下甲"])
    }

    @Test("an empty result set ranks to nothing")
    func empty() {
        #expect(Self.rank([], for: "任意").isEmpty)
    }
}
