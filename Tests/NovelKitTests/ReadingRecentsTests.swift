import Foundation
import Testing
@testable import NovelKit

@Suite("Resuming the last reading")
struct ReadingRecentsTests {

    private func book(
        name: String,
        lastReadAt: Date? = nil,
        progressUpdatedAt: Date? = nil
    ) -> Book {
        let progress = ReadingProgress(
            chapterIndex: 3,
            chapterTitle: "第三章",
            updatedAt: progressUpdatedAt
        )
        return Book(
            sourceID: UUID(),
            sourceName: "源",
            detailURL: "https://example.com/\(name)",
            name: name,
            progress: progress,
            lastReadAt: lastReadAt
        )
    }

    @Test("picks the most recently read book")
    func picksMostRecent() {
        let now = Date()
        let older = book(name: "旧书", lastReadAt: now.addingTimeInterval(-3600))
        let newer = book(name: "新书", lastReadAt: now)
        #expect(ReadingRecents.mostRecent(in: [older, newer])?.name == "新书")
    }

    @Test("ignores books that were never opened")
    func ignoresUnread() {
        let never = book(name: "没读过")
        let read = book(name: "读过", lastReadAt: Date())
        #expect(ReadingRecents.mostRecent(in: [never, read])?.name == "读过")
        #expect(ReadingRecents.mostRecent(in: [never]) == nil)
    }

    @Test("falls back to saved progress without a last-read date")
    func fallsBackToProgress() {
        // Books added by builds that predate `lastReadAt` only have progress.
        let legacy = book(name: "老书", progressUpdatedAt: Date())
        #expect(ReadingRecents.mostRecent(in: [legacy])?.name == "老书")
    }

    @Test("lastReadAt wins over the progress timestamp")
    func lastReadAtWins() {
        let now = Date()
        let resumed = book(
            name: "刚读过",
            lastReadAt: now,
            progressUpdatedAt: now.addingTimeInterval(-86_400)
        )
        let other = book(name: "别处", lastReadAt: now.addingTimeInterval(-60))
        #expect(ReadingRecents.mostRecent(in: [resumed, other])?.name == "刚读过")
    }

    @Test("an empty shelf has nothing to resume")
    func emptyShelf() {
        #expect(ReadingRecents.mostRecent(in: []) == nil)
    }
}
