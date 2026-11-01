import Foundation
import Testing
@testable import NovelKit

/// The reader answers horizontal drags twice: page turns and "leave the book".
/// These cases pin down the split between the two, which is the part a user
/// notices immediately when it is wrong — either the book closes while they
/// were turning a page, or the back gesture never fires.
@Suite("Swiping back out of the reader")
struct ReaderSwipeTests {

    @Test("an edge drag rightwards with the bars up leaves the book")
    func edgeDragDismisses() {
        #expect(ReaderSwipe.isBackSwipe(
            startX: 4,
            translation: CGSize(width: 120, height: 8),
            barsVisible: true
        ))
    }

    @Test("full-screen reading ignores the edge drag")
    func fullScreenDoesNotDismiss() {
        // Without the bars there is no chrome to leave from, and the same drag
        // is what turns the first page of a chapter.
        #expect(!ReaderSwipe.isBackSwipe(
            startX: 4,
            translation: CGSize(width: 120, height: 8),
            barsVisible: false
        ))
    }

    @Test("a drag that starts mid-page is a page turn, not a dismissal")
    func midPageDragIsNotDismiss() {
        #expect(!ReaderSwipe.isBackSwipe(
            startX: ReaderSwipe.edgeWidth + 40,
            translation: CGSize(width: 140, height: 4),
            barsVisible: true
        ))
    }

    @Test("a short nudge does not leave the book")
    func shortNudgeDoesNotDismiss() {
        #expect(!ReaderSwipe.isBackSwipe(
            startX: 2,
            translation: CGSize(width: ReaderSwipe.dismissDistance - 1, height: 2),
            barsVisible: true
        ))
    }

    @Test("swiping left at the edge does not leave the book")
    func leftwardEdgeDragDoesNotDismiss() {
        #expect(!ReaderSwipe.isBackSwipe(
            startX: 2,
            translation: CGSize(width: -140, height: 4),
            barsVisible: true
        ))
    }

    @Test("a mostly vertical drag is a scroll")
    func verticalDragDoesNotDismiss() {
        #expect(!ReaderSwipe.isBackSwipe(
            startX: 2,
            translation: CGSize(width: 90, height: 200),
            barsVisible: true
        ))
        // Equal travel in both axes is ambiguous, and the page turn is the
        // reading action, so it wins.
        #expect(!ReaderSwipe.isBackSwipe(
            startX: 2,
            translation: CGSize(width: 100, height: 100),
            barsVisible: true
        ))
    }

    @Test("page turning keeps its hands off edge drags with the bars up")
    func pageTurnYieldsEdgeDrags() {
        // The mirror of the rule above: while the bars are up, an edge drag is
        // never also a page turn, so the page cannot move before it vanishes.
        #expect(ReaderSwipe.claimsEdge(startX: 6, barsVisible: true))
        #expect(!ReaderSwipe.claimsEdge(startX: 6, barsVisible: false))
        #expect(!ReaderSwipe.claimsEdge(startX: 120, barsVisible: true))
    }

    @Test("the page turn and the back gesture agree exactly on the edge zone")
    func boundariesAgree() {
        // A drag exactly at the edge is still an edge drag; one point further in
        // belongs to the page. Getting this off by one either swallows page
        // turns or makes the back gesture feel dead near the edge.
        #expect(ReaderSwipe.claimsEdge(startX: ReaderSwipe.edgeWidth, barsVisible: true))
        #expect(!ReaderSwipe.claimsEdge(startX: ReaderSwipe.edgeWidth + 1, barsVisible: true))
    }
}
