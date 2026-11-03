import Foundation
import Testing
@testable import NovelKit

/// Whole-book progress shown beside the chapter bar.
///
/// Chapters differ in length, so counting chapters alone misreports how much
/// of the book is behind the reader. These pin the arithmetic that blends the
/// finished chapters with the current one's own position.
@Suite("Book progress")
struct BookProgressTests {

    /// Mirrors `ReaderModel.bookProgressFraction`, which lives in the app
    /// target and cannot be imported here.
    static func fraction(chapterIndex: Int, chapterProgress: Double, chapterCount: Int) -> Double {
        guard chapterCount > 0 else { return 0 }
        return (Double(chapterIndex) + chapterProgress) / Double(chapterCount)
    }

    @Test("the start of the first chapter is zero")
    func firstChapterStart() {
        #expect(Self.fraction(chapterIndex: 0, chapterProgress: 0, chapterCount: 10) == 0)
    }

    @Test("halfway through the fifth chapter of ten is 45 percent")
    func midChapter() {
        // Four whole chapters done, plus half of the fifth.
        let value = Self.fraction(chapterIndex: 4, chapterProgress: 0.5, chapterCount: 10)
        #expect(abs(value - 0.45) < 0.0001)
    }

    @Test("the end of the last chapter is one")
    func lastChapterEnd() {
        #expect(Self.fraction(chapterIndex: 9, chapterProgress: 1, chapterCount: 10) == 1)
    }

    @Test("an empty book reports zero rather than dividing by zero")
    func emptyBook() {
        #expect(Self.fraction(chapterIndex: 0, chapterProgress: 0, chapterCount: 0) == 0)
    }

    @Test("progress inside a chapter moves the fraction forward")
    func monotonicWithinChapter() {
        let start = Self.fraction(chapterIndex: 3, chapterProgress: 0, chapterCount: 8)
        let middle = Self.fraction(chapterIndex: 3, chapterProgress: 0.5, chapterCount: 8)
        let end = Self.fraction(chapterIndex: 3, chapterProgress: 1, chapterCount: 8)
        #expect(start < middle)
        #expect(middle < end)
    }
}

/// The chapter bar itself: which page of the chapter is showing.
@Suite("Chapter progress")
struct ChapterProgressTests {

    /// Mirrors the write in `PagedReader.syncPageIndicator`.
    static func fraction(pageIndex: Int, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        return Double(min(pageIndex + 1, pageCount)) / Double(pageCount)
    }

    @Test("the first page is already a step in, not zero")
    func firstPage() {
        // Page 1 of 4 reads as 25% — the bar fills as pages are consumed,
        // which matches the "3/12" in the header.
        #expect(Self.fraction(pageIndex: 0, pageCount: 4) == 0.25)
    }

    @Test("the last page is full")
    func lastPage() {
        #expect(Self.fraction(pageIndex: 3, pageCount: 4) == 1)
    }

    @Test("an unpaginated chapter reads as zero")
    func noPages() {
        #expect(Self.fraction(pageIndex: 0, pageCount: 0) == 0)
    }

    @Test("a stale page index past the end clamps to full")
    func clamps() {
        #expect(Self.fraction(pageIndex: 9, pageCount: 4) == 1)
    }
}
