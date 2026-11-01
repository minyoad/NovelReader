import Foundation
import Testing
@testable import NovelKit

/// A trial read is opened from a search result, so the book is not on the shelf
/// yet. Everything that writes back to the library has to be off for it —
/// recording progress would make a book nobody added the app's resume target,
/// and caching would leave chapter files keyed by an id the library never learns.
///
/// The flags live in `ReadingMode` so the five call sites in the reader cannot
/// drift apart; these tests pin the flags themselves.
@Suite("Shelf reads versus trial reads")
struct ReadingModeTests {

    private func chapter() -> Chapter {
        Chapter(index: 0, title: "第一章", url: "https://example.com/1")
    }

    @Test("a reader without preview chapters is a normal shelf read")
    func shelfMode() {
        let mode = ReadingMode(previewChapters: nil)
        #expect(mode == .shelf)
        #expect(mode.recordsProgress)
        #expect(mode.cachesChapters)
        #expect(mode.canSwitchSource)
        #expect(!mode.asksToAddToShelf)
    }

    @Test("a reader handed a preview table of contents is a trial read")
    func previewMode() {
        let mode = ReadingMode(previewChapters: [chapter()])
        #expect(mode == .preview)
        // Every write back to the library is refused…
        #expect(!mode.recordsProgress)
        #expect(!mode.cachesChapters)
        #expect(!mode.canSwitchSource)
        // …and closing asks the question the trial exists to answer.
        #expect(mode.asksToAddToShelf)
    }

    @Test("an empty preview table of contents is still a trial read")
    func emptyPreviewIsStillPreview() {
        // The distinction is "opened from a preview", not "has chapters": a
        // preview whose TOC failed to parse must not quietly become a shelf
        // read and start writing progress for a book that is not there.
        let mode = ReadingMode(previewChapters: [])
        #expect(mode == .preview)
        #expect(!mode.recordsProgress)
    }
}
