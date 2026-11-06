import Foundation

/// Where the automatic ad cleanup looks, and whether it is worth a request.
///
/// Ad copy and site trailers are not scattered evenly through a chapter: they
/// sit at the top (before the story starts) and at the bottom (after it ends).
/// The middle is prose. Sending the whole chapter meant waiting for several
/// sequential model calls before the reader saw a single word — ten seconds or
/// more per chapter turn — to remove lines that were almost never there.
///
/// So the automatic pass only asks the model about a head and a tail, and the
/// rest of the chapter is shown untouched. The model is never asked to rewrite
/// the body, which is also the safest way to run it unattended.
public enum AutoCleanup {

    /// How much text at each end is sent, in characters.
    ///
    /// Sized for a couple of paragraphs of ad copy plus the site's trailer
    /// block. Much larger and the request gets slower than the page turn it
    /// was supposed to protect.
    public static let edgeLength = 600

    /// A chapter shorter than this is not worth splitting: its whole body is
    /// about the size of the two edges anyway, so one call covers it.
    public static let wholeChapterLimit = 1400

    /// The text to send to the model.
    public struct Scope: Equatable, Sendable {
        public let head: String
        public let tail: String
        /// The middle that must come back verbatim. Empty when the chapter is
        /// short enough to send whole (then `head` holds it and `tail` is "").
        public let middle: String

        public var isWholeChapter: Bool { middle.isEmpty }

        public var prompt: String {
            if isWholeChapter { return head }
            return head + "\n" + AIPrompt.scopeSeparator + "\n" + tail
        }
    }

    /// Splits a chapter into the part worth cleaning and the part to keep.
    ///
    /// Paragraph boundaries are respected: a paragraph is never cut in half,
    /// because the model deletes whole lines and a half-line has no clean edge
    /// to delete from.
    public static func scope(for text: String) -> Scope {
        let paragraphs = TextProcessing.normalizeParagraphs(text)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !paragraphs.isEmpty else { return Scope(head: "", tail: "", middle: "") }

        let total = paragraphs.reduce(0) { $0 + $1.count }
        if total <= wholeChapterLimit {
            return Scope(head: paragraphs.joined(separator: "\n"), tail: "", middle: "")
        }

        // Collect paragraphs from each end until the budget is used up. The two
        // windows must not touch: `start` is where the tail starts scanning, so
        // the loop has to stop one short of it or the paragraph at `start` lands
        // in neither head, middle nor tail — and reassembly silently drops it.
        var headLines: [String] = []
        var headCount = 0
        var start = 0
        while start < paragraphs.count - 2, headCount < edgeLength {
            headLines.append(paragraphs[start])
            headCount += paragraphs[start].count
            start += 1
        }

        var tailLines: [String] = []
        var tailCount = 0
        var end = paragraphs.count - 1
        while end >= start + 1, tailCount < edgeLength {
            tailLines.insert(paragraphs[end], at: 0)
            tailCount += paragraphs[end].count
            end -= 1
        }

        // `end` is the last paragraph of the tail; anything from `start` up to
        // (and including) `end` is body and goes back untouched.
        let middle = paragraphs[start...end].joined(separator: "\n")
        return Scope(
            head: headLines.joined(separator: "\n"),
            tail: tailLines.joined(separator: "\n"),
            middle: middle
        )
    }

    /// Whether this chapter should be sent to the model before being shown.
    ///
    /// - `enabled` is the user's switch, the configured API, **and** whether
    ///   the reader can actually wait for it. Showing the chapter first and
    ///   cleaning in the background is what keeps a page turn instant, but a
    ///   chapter that is about to be spoken aloud cannot be cleaned after the
    ///   fact without the audio reading the raw text — so that case stays
    ///   synchronous. `synchronous` carries that decision down from the caller.
    public static func shouldRun(
        content: ChapterContent,
        enabled: Bool,
        chapterTitle: String,
        synchronous: Bool = true
    ) -> Bool {
        guard enabled, synchronous, !content.cleaned else { return false }
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return !TextProcessing.isPlaceholderContent(text, chapterTitle: chapterTitle)
    }

    /// Quotes the body back into place around whatever the model returned.
    ///
    /// The middle was never sent, so it cannot be lost — but the edges come
    /// back shorter, and a model that decided the head was entirely ads may
    /// return nothing at all for it. An empty chapter is worse than an ad, so
    /// a scope that comes back blank keeps its original text.
    public static func reassemble(scope: Scope, cleaned: Scope) -> String {
        let head = cleaned.head.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = cleaned.tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if scope.isWholeChapter {
            return head.isEmpty ? scope.head : head
        }
        // Both edges empty means the model rejected the only text it was shown;
        // the chapter would lose its opening and its ending at once.
        if head.isEmpty && tail.isEmpty { return scope.prompt }

        return [head, scope.middle, tail]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Undoes an automatic pass when the reader stops between chapters.
    ///
    /// The end of a chapter is when the site's trailers ("本章未完……", "求收藏")
    /// and its injected ad lines sit, and it is exactly what the model was asked
    /// to delete. If the cleanup fails there, what the reader is looking at is
    /// the site's raw text, so say so once instead of letting the reading go on
    /// as if it had worked.
    public static func failureMessage(chapterTitle: String) -> String {
        "《\(chapterTitle)》自动去广告失败，这一章显示的是原文"
    }

    /// What to say when the chapter loaded already cleaned.
    public static func skippedNote() -> String {
        "这一章已经清理过，跳过自动去广告"
    }

    // MARK: - Cleaning ahead

    /// Chapters to download *and clean* before the reader gets to them.
    ///
    /// The point is that turning a page must not wait for a model. The chapter
    /// being read is shown as fetched; this queue prepares the next few so they
    /// are already clean on disk when the reader arrives.
    ///
    /// Rules:
    /// - forward only, like `CachePlanner.prefetchIndices`: a reader moves down
    ///   a book far more than up;
    /// - skip anything already cleaned (`cleaned` on disk), so a re-read costs
    ///   nothing and a chapter is never paid for twice;
    /// - skip what failed before, so an offline moment does not have the app
    ///   retry the whole queue on every page turn;
    /// - skip chapters that have no body cached yet only in the sense that they
    ///   are still queued — the caller downloads them first.
    public static func cleanAheadIndices(
        currentIndex: Int,
        chapterCount: Int,
        ahead: Int,
        alreadyCleaned: Set<Int>,
        failed: Set<Int>
    ) -> [Int] {
        guard chapterCount > 0, ahead > 0, currentIndex >= 0 else { return [] }
        var result: [Int] = []
        var index = currentIndex + 1
        while index < chapterCount && result.count < ahead {
            if !alreadyCleaned.contains(index), !failed.contains(index) {
                result.append(index)
            }
            index += 1
        }
        return result
    }
}
