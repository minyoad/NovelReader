import Testing
import Foundation
@testable import NovelKit

/// The same collection imported on two devices produced two copies of every
/// source: the importer mints an id per import, and the merge keyed on id.
/// A 211-source list was really about a hundred sources and their twins.
@Suite("Sources imported on two devices")
struct SyncMergeDuplicateSourceTests {

    private func source(
        id: UUID = UUID(),
        name: String = "快眼看书",
        url: String = "http://www.booksky.cc",
        group: String = "🌹已检",
        searchURL: String = "http://www.booksky.cc/search.php?q={{key}}",
        enabled: Bool = true
    ) -> BookSource {
        BookSource(
            id: id,
            name: name,
            baseURL: url,
            group: group,
            enabled: enabled,
            searchURL: searchURL
        )
    }

    private func payload(_ sources: [BookSource], _ books: [Book] = []) -> SyncPayload {
        SyncPayload(deviceID: "A", books: books, sources: sources)
    }

    @Test("the same name and site under two ids becomes one source")
    func differentIDsSameSite() {
        let phone = source()
        let pad = source()
        let outcome = SyncMerge.merge(local: payload([phone]), remote: payload([pad]))
        #expect(outcome.sources.count == 1)
        // The local id survives: books point at it.
        #expect(outcome.sources.first?.id == phone.id)
    }

    @Test("a trailing # fragment does not make a different source")
    func trailingFragment() {
        // Collections leave `#🎃` on the end of the URL; the importer strips it,
        // so a source imported before and after that cleanup must compare equal.
        let clean = source(url: "http://www.booksky.cc")
        let dirty = source(url: "http://www.booksky.cc#🎃")
        let outcome = SyncMerge.merge(local: payload([clean]), remote: payload([dirty]))
        #expect(outcome.sources.count == 1)
    }

    @Test("a trailing slash does not make a different source")
    func trailingSlash() {
        let a = source(url: "https://www.dingdian888.com")
        let b = source(url: "https://www.dingdian888.com/")
        let outcome = SyncMerge.merge(local: payload([a]), remote: payload([b]))
        #expect(outcome.sources.count == 1)
    }

    @Test("the same name on two different sites stays two sources")
    func sameNameDifferentSites() {
        // 笔趣阁 is the name of several unrelated sites; folding them would send
        // every book to the wrong one.
        let a = source(name: "笔趣阁", url: "https://a.example.com")
        let b = source(name: "笔趣阁", url: "https://b.example.com")
        let outcome = SyncMerge.merge(local: payload([a]), remote: payload([b]))
        #expect(outcome.sources.count == 2)
    }

    @Test("the same site under two names stays two sources")
    func sameSiteDifferentNames() {
        // Two rules for one site can be deliberate — one searches, one reads —
        // and merging them would delete one of the user's imports.
        let a = source(name: "快眼看书", url: "http://www.booksky.cc")
        let b = source(name: "快眼看书botaodz", url: "http://www.booksky.cc")
        let outcome = SyncMerge.merge(local: payload([a]), remote: payload([b]))
        #expect(outcome.sources.count == 2)
    }

    @Test("a local list already duplicated is folded")
    func existingDuplicateFolded() {
        // This is the state the phone is actually in, so the cleanup cannot
        // rely on a remote copy arriving to trigger it.
        let first = source()
        let second = source()
        let outcome = SyncMerge.merge(local: payload([first, second]), remote: payload([]))
        #expect(outcome.sources.count == 1)
        #expect(outcome.localChanged)
    }

    @Test("books follow the source id that survives the fold")
    func booksRepointed() {
        // The surviving copy is whichever sorts first by id, not necessarily
        // the first one passed in — what matters is that the book follows it.
        let dropped = source()
        let kept = source()
        var book = Book(
            sourceID: dropped.id,
            sourceName: kept.name,
            detailURL: "http://www.booksky.cc/1",
            name: "书"
        )
        let outcome = SyncMerge.merge(
            local: payload([kept, dropped], [book]),
            remote: payload([])
        )
        #expect(outcome.sources.count == 1)
        // Without this the book points at a source that no longer exists and
        // shows as "书源已删除".
        #expect(outcome.books.first?.sourceID == outcome.sources.first?.id)
        _ = book
    }

    @Test("an empty local rule is filled from the remote copy")
    func remoteRulesFillGaps() {
        let local = source(searchURL: "")
        let remote = source(searchURL: "http://www.booksky.cc/s.php?q={{key}}")
        let outcome = SyncMerge.merge(local: payload([local]), remote: payload([remote]))
        #expect(outcome.sources.count == 1)
        #expect(outcome.sources.first?.searchURL == "http://www.booksky.cc/s.php?q={{key}}")
        // Still keyed by the id books point at.
        #expect(outcome.sources.first?.id == local.id)
    }

    @Test("a source this device switched off stays off after a merge")
    func enabledFlagNotOverwritten() {
        let local = source(enabled: false)
        let remote = source(searchURL: "", enabled: true)
        let outcome = SyncMerge.merge(local: payload([local]), remote: payload([remote]))
        #expect(outcome.sources.first?.enabled == false)
    }

    @Test("merging twice changes nothing the second time")
    func idempotent() {
        let local = source()
        let remote = payload([source()])
        let first = SyncMerge.merge(local: payload([local]), remote: remote)
        let second = SyncMerge.merge(local: payload(first.sources), remote: remote)
        #expect(second.sources == first.sources)
        #expect(!second.localChanged)
    }

    @Test("distinct sources are all kept")
    func noOverMerge() {
        let a = source(name: "甲", url: "https://a.example.com")
        let b = source(name: "乙", url: "https://b.example.com")
        let c = source(name: "丙", url: "https://c.example.com")
        let outcome = SyncMerge.merge(local: payload([a]), remote: payload([b, c]))
        #expect(outcome.sources.count == 3)
    }
}
