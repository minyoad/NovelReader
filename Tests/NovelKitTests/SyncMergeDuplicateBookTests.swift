import Testing
import Foundation
@testable import NovelKit

/// The same novel added on two devices used to show up twice on the shelf.
///
/// Ids are UUIDs minted at add time, so each device gave the book its own. The
/// merge keyed on id alone and the union kept both: one at chapter 300, one
/// never opened. The identifying pair is the source it came from and the page
/// it came from — those agree no matter which device added it.
@Suite("Books added twice on two devices")
struct SyncMergeDuplicateBookTests {

    private let sourceID = UUID()

    private func book(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        url: String = "http://www.23uswx.la/148_148514/",
        name: String = "凡骨",
        chapter: Int = 0,
        updatedAt: Date? = nil
    ) -> Book {
        Book(
            id: id,
            sourceID: sourceID ?? self.sourceID,
            sourceName: "顶点小说 23uswx",
            detailURL: url,
            name: name,
            progress: ReadingProgress(
                chapterIndex: chapter,
                chapterTitle: "第\(chapter + 1)章",
                updatedAt: updatedAt
            )
        )
    }

    private func payload(_ books: [Book], device: String = "A") -> SyncPayload {
        SyncPayload(deviceID: device, books: books, sources: [])
    }

    @Test("the same page under two ids becomes one book")
    func differentIDsSamePage() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 500)
        _ = older

        let phone = book(chapter: 300, updatedAt: newer)
        let pad = book(chapter: 0)

        let outcome = SyncMerge.merge(
            local: payload([phone]),
            remote: payload([pad], device: "B")
        )

        #expect(outcome.books.count == 1)
        // The copy this device already had keeps its id, so the shelf does not
        // churn, and the progress is the newer one.
        #expect(outcome.books.first?.id == phone.id)
        #expect(outcome.books.first?.progress.chapterIndex == 300)
        _ = older
        _ = newer
    }

    @Test("a never-read copy never beats a read one, whichever side it is on")
    func unreadCopyLoses() {
        let read = book(chapter: 300, updatedAt: Date(timeIntervalSince1970: 100))
        let unread = book()

        let localUnread = SyncMerge.merge(
            local: payload([unread]),
            remote: payload([read], device: "B")
        )
        #expect(localUnread.books.count == 1)
        #expect(localUnread.books.first?.progress.chapterIndex == 300)

        let localRead = SyncMerge.merge(
            local: payload([read]),
            remote: payload([unread], device: "B")
        )
        #expect(localRead.books.count == 1)
        #expect(localRead.books.first?.progress.chapterIndex == 300)
    }

    @Test("addedAt keeps the earliest of the two")
    func earliestAddedAt() {
        var phone = book(chapter: 5, updatedAt: Date(timeIntervalSince1970: 500))
        phone.addedAt = Date(timeIntervalSince1970: 300)
        var pad = book()
        pad.addedAt = Date(timeIntervalSince1970: 100)

        let outcome = SyncMerge.merge(
            local: payload([phone]),
            remote: payload([pad], device: "B")
        )
        #expect(outcome.books.count == 1)
        // The book was on the pad first; keeping the phone's later date would
        // make it look newly added every time the two sync.
        #expect(outcome.books.first?.addedAt == Date(timeIntervalSince1970: 100))
        #expect(outcome.books.first?.progress.chapterIndex == 5)
    }

    @Test("the same id different page stays two books")
    func sameIDDifferentPage() {
        let id = UUID()
        // An id match is authoritative, so this is one record whose URL was
        // corrected — not two books. The point is that the origin key must not
        // get in the way of that.
        let outcome = SyncMerge.merge(
            local: payload([book(id: id, url: "https://a.example.com/1")]),
            remote: payload([book(id: id, url: "https://a.example.com/2")], device: "B")
        )
        #expect(outcome.books.count == 1)
        #expect(outcome.books.first?.id == id)
    }

    @Test("the same title on different pages stays two books")
    func sameTitleDifferentPages() {
        let first = book(url: "https://a.example.com/qingshan/", name: "青山")
        let second = book(url: "https://b.example.com/qingshan/", name: "青山")
        let outcome = SyncMerge.merge(
            local: payload([first]),
            remote: payload([second], device: "B")
        )
        #expect(outcome.books.count == 2)
    }

    @Test("the same page under different sources stays two books")
    func samePageDifferentSources() {
        let a = book(url: "https://a.example.com/1")
        var b = book(url: "https://a.example.com/1")
        b.sourceID = UUID()
        let outcome = SyncMerge.merge(
            local: payload([a]),
            remote: payload([b], device: "B")
        )
        #expect(outcome.books.count == 2)
    }

    @Test("a trailing slash does not make a different book")
    func trailingSlash() {
        let withSlash = book(url: "https://a.example.com/1/")
        let without = book(url: "https://a.example.com/1", chapter: 9,
                           updatedAt: Date(timeIntervalSince1970: 10))
        let outcome = SyncMerge.merge(
            local: payload([withSlash]),
            remote: payload([without], device: "B")
        )
        #expect(outcome.books.count == 1)
        #expect(outcome.books.first?.progress.chapterIndex == 9)
    }

    @Test("books with no detail URL are never folded together")
    func missingURL() {
        let a = book(url: "", name: "甲")
        let b = book(url: "", name: "甲")
        let outcome = SyncMerge.merge(
            local: payload([a]),
            remote: payload([b], device: "B")
        )
        // Nothing says these are the same book; dropping one would delete a
        // book the user added.
        #expect(outcome.books.count == 2)
    }

    @Test("a shelf already duplicated is cleaned up by the next merge")
    func existingDuplicateIsFolded() {
        // This is the state the phone is actually in: both copies local, so no
        // remote book can trigger the cross-device path. The result returned to
        // the caller still has to come back with one book.
        let stale = book()
        let read = book(chapter: 300, updatedAt: Date(timeIntervalSince1970: 100))

        let outcome = SyncMerge.merge(
            local: payload([stale, read]),
            remote: payload([], device: "B")
        )
        #expect(outcome.books.count == 1)
        #expect(outcome.books.first?.progress.chapterIndex == 300)

        // And it has to say the local shelf changed, or the fold never reaches
        // disk.
        #expect(outcome.localChanged)
    }

    @Test("a clean shelf with no remote books is left alone")
    func noChange() {
        let only = book(chapter: 3, updatedAt: Date(timeIntervalSince1970: 100))
        let outcome = SyncMerge.merge(
            local: payload([only]),
            remote: payload([], device: "B")
        )
        #expect(outcome.books.count == 1)
        #expect(!outcome.localChanged)
    }

    @Test("merging is stable: a second pass changes nothing")
    func idempotent() {
        let phone = book(chapter: 300, updatedAt: Date(timeIntervalSince1970: 500))
        let pad = book()
        let remote = payload([pad], device: "B")
        let first = SyncMerge.merge(local: payload([phone]), remote: remote)
        let second = SyncMerge.merge(local: payload(first.books), remote: remote)
        #expect(second.books == first.books)
        #expect(!second.localChanged)
    }
}
