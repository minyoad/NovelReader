import Foundation

/// Where the automatic ad cleanup looks, and whether it is worth a request.
///
/// Ad copy is not only at the ends of a chapter. Some sites paste a URL or a
/// "最新网址" line between two paragraphs in the middle of the prose, so the
/// whole chapter has to be shown to the model — the ends-only version left
/// those lines in.
///
/// Sending a whole chapter used to mean one long request per chapter, which is
/// what made a page turn slow. The fix is not to send less, it is to split the
/// chapter into paragraph-aligned chunks and send them **concurrently**, with
/// one paragraph of overlap so a straddling ad line is still visible to some
/// chunk. A 6000-character chapter then costs about as long as its longest
/// chunk, not the sum of all of them.
public enum AutoCleanup {

    /// Characters per request, derived from the output budget.
    ///
    /// A cleanup reply is as long as what was sent — deleting lines only makes
    /// it shorter — so the binding limit is **output**, not context window.
    /// Sending more than `maxTokens` can produce means the tail of the reply
    /// is cut off and the chapter loses its ending.
    ///
    /// Rules of thumb, deliberately conservative:
    /// - a Chinese character costs about 1.5 tokens (BPE splits punctuation
    ///   and less common characters);
    /// - the reply rounds-trips through the same budget, so plan against it,
    ///   not against the context window;
    /// - leave a margin for the model keeping a few extra lines.
    ///
    /// At the default `maxTokens` of 2048 that gives ~1100 characters, which is
    /// smaller than the old hard-coded 1800 — that value was a guess, and it
    /// left almost no headroom.
    public static func chunkLength(maxTokens: Int) -> Int {
        let usable = max(maxTokens - outputMargin, 400)
        return max(400, Int(Double(usable) / tokensPerCharacter))
    }

    /// Tokens held back from `maxTokens` for layout and tokenizer variance.
    public static let outputMargin = 300

    /// Approximate tokens per Chinese character.
    public static let tokensPerCharacter = 1.5

    /// Paragraphs of context shared by neighbouring chunks.
    ///
    /// An ad line often sits right after a paragraph break, and a chunk that
    /// starts exactly at that break would have no prose before it to judge the
    /// line against. One paragraph of overlap fixes that. A repeated paragraph
    /// is harmless: the model is told to echo it and the caller drops the
    /// duplicate when reassembling.
    public static let overlapParagraphs = 1

    /// The chunk size actually used: the user's setting, capped by what the
    /// output budget can return in one reply.
    ///
    /// The ceiling is not a preference — a reply longer than `maxTokens` is cut
    /// off, and the chapter loses its ending. Exposed so the settings screen
    /// can show the real number instead of the one being typed in.
    public static func effectiveChunkLength(chunkSize: Int, maxTokens: Int) -> Int {
        min(chunkSize, chunkLength(maxTokens: maxTokens))
    }

    /// The chunks to send, in reading order.
    ///
    /// `limit` comes from `chunkLength(maxTokens:)`; the chapter is sent in one
    /// request whenever it fits, because splitting a chapter that fits only
    /// pays for the system prompt twice.
    ///
    /// Paragraph boundaries are respected: a paragraph is never split, because
    /// the model deletes whole lines and half a line has no clean edge to
    /// delete from. A paragraph longer than `limit` is sent as its own chunk
    /// rather than cut, for the same reason.
    public static func chunks(for text: String, limit: Int = AutoCleanup.chunkLength(maxTokens: 2048)) -> [String] {
        let paragraphs = TextProcessing.normalizeParagraphs(text)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !paragraphs.isEmpty else { return [] }
        if paragraphs.reduce(0, { $0 + $1.count }) <= limit {
            return [paragraphs.joined(separator: "\n")]
        }

        // Greedily pack paragraphs, carrying the tail of the previous chunk
        // forward as overlap. `start` is the first paragraph not yet consumed;
        // `overlapStart` is where this chunk's copy begins.
        var result: [String] = []
        var start = 0
        while start < paragraphs.count {
            let overlapStart = max(0, start - overlapParagraphs)
            var end = start
            var count = 0
            var overlapsOnly = true
            while end < paragraphs.count {
                let next = count + paragraphs[end].count + 1
                // Always take at least one new paragraph, however long it is.
                if next > limit && !overlapsOnly { break }
                count = next
                overlapsOnly = false
                end += 1
            }
            guard end > start else { break }
            result.append(paragraphs[overlapStart..<end].joined(separator: "\n"))
            start = end
        }
        return result
    }

    /// Puts the cleaned chunks back together, dropping the overlap.
    ///
    /// `cleaned` must be in the same order as the chunks. A chunk that came
    /// back empty was entirely junk and contributes nothing. The overlap
    /// paragraphs at the start of each later chunk repeat what the previous
    /// chunk already ended with, so they are removed — but only when the
    /// model actually returned them; if it dropped them as ads too, there is
    /// nothing to remove and skipping the removal must not lose new text.
    public static func reassemble(chunks: [String], cleaned: [String]) -> String {
        guard chunks.count == cleaned.count else {
            // Mismatched counts mean the reply was unreadable; the caller
            // falls back to the original rather than guess an alignment.
            return ""
        }
        guard !chunks.isEmpty else { return "" }

        var output: [String] = []
        for (index, raw) in cleaned.enumerated() {
            var lines = raw
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if index > 0 {
                let overlap = chunks[index].components(separatedBy: "\n").prefix(overlapParagraphs)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Drop leading lines that repeat the overlap — at most the
                // overlap size, and only while they match, so a genuine
                // repeated line of dialogue after the seam is kept.
                var dropped = 0
                while dropped < overlap.count, let first = lines.first,
                      first == overlap[overlap.index(overlap.startIndex, offsetBy: dropped)] {
                    lines.removeFirst()
                    dropped += 1
                }
            }
            output.append(contentsOf: lines)
        }
        return output.joined(separator: "\n")
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
