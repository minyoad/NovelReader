import Foundation

/// Decides *what* the automatic ad cleanup works on, and when it is worth
/// running at all.
///
/// Kept in `NovelKit` so the rules are unit tested on Linux; the reader only
/// calls the network part. Separating this matters because the common failure
/// mode is not a broken model — it is running the cleanup on text that has
/// nothing to clean (already cleaned, a paywall stub, an empty chapter) and
/// then showing the failure as a reader error over perfectly good prose.
public enum AutoCleanup {

    /// Whether this chapter should be sent to the model before being shown.
    ///
    /// - `enabled` is the user's switch and the configured API.
    /// - `alreadyCleaned` skips text an earlier pass (manual or automatic)
    ///   already went through; re-running costs money and risks the model
    ///   rewriting prose that was fine.
    /// - Placeholder bodies are refused for the same reason the cache refuses
    ///   them: there is no prose to clean, and a model asked to tidy
    ///   "内容正在获取中" happily invents a chapter.
    public static func shouldRun(
        content: ChapterContent,
        enabled: Bool,
        chapterTitle: String
    ) -> Bool {
        guard enabled, !content.cleaned else { return false }
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
}
