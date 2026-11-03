import Foundation
import Testing
@testable import NovelKit

/// Recent search keywords are kept newest-first, de-duplicated, and capped.
@Suite("Search history")
struct SearchHistoryTests {

    /// Mirrors `AppModel.rememberSearch`, which lives in the app target.
    static func remember(_ query: String, in history: [String], limit: Int = 12) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        var updated = history.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        return Array(updated.prefix(limit))
    }

    @Test("a new search goes to the front")
    func newestFirst() {
        let history = Self.remember("斗罗", in: [])
        #expect(history == ["斗罗"])
        #expect(Self.remember("凡人", in: history) == ["凡人", "斗罗"])
    }

    @Test("searching the same word again moves it up instead of duplicating")
    func noDuplicates() {
        let history = ["凡人", "斗罗", "遮天"]
        #expect(Self.remember("遮天", in: history) == ["遮天", "凡人", "斗罗"])
    }

    @Test("surrounding whitespace is trimmed before storing")
    func trimsWhitespace() {
        #expect(Self.remember("  凡人  ", in: []) == ["凡人"])
    }

    @Test("a blank query is ignored")
    func ignoresBlank() {
        let history = ["凡人"]
        #expect(Self.remember("   ", in: history) == history)
        #expect(Self.remember("", in: history) == history)
    }

    @Test("the list is capped, dropping the oldest")
    func capped() {
        var history: [String] = []
        for index in 1...15 {
            history = Self.remember("词\(index)", in: history, limit: 5)
        }
        #expect(history.count == 5)
        #expect(history.first == "词15")
        #expect(history.last == "词11")
    }

    @Test("history round-trips through the settings JSON")
    func decodesFromDisk() throws {
        let original = AppSettings(searchHistory: ["凡人", "斗罗"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.searchHistory == ["凡人", "斗罗"])
    }

    @Test("settings written before the field existed still decode")
    func decodesOlderFile() throws {
        // An older settings.json has no `searchHistory` key at all.
        let json = #"{"searchAllSources":true}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.searchHistory.isEmpty)
    }
}
