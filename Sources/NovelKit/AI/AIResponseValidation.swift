import Foundation

/// A successful HTTP response is not necessarily usable chapter text.
public enum AIResponseValidation {
    /// Validate against the exact source chunk before joining or caching it.
    /// Ad removal may delete text and change whitespace, but cannot add prose.
    public static func validated(_ reply: String, original: String, task: AIPrompt.ChapterTask) throws -> String {
        let cleaned = AIPrompt.cleanReply(reply)
        guard !hasIntroducedRefusal(cleaned, original: original) else { throw AIError.unusableChapter }
        if task == .stripAds, !isDeletionOnly(cleaned, original: original) {
            throw AIError.unusableChapter
        }
        return cleaned
    }

    /// Compare non-whitespace characters in order. This deliberately rejects
    /// even well-meant rewrites: returning the original is safer than inventing
    /// missing novel text. Empty output remains valid for an all-ad chunk.
    public static func isDeletionOnly(_ reply: String, original: String) -> Bool {
        var source = original.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.makeIterator()
        for scalar in reply.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            var found = false
            while let next = source.next() {
                if next == scalar { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Used to repair existing caches as well as validate fresh replies. Match
    /// refusal language, not a generic occurrence of "sorry" in story dialogue.
    /// A phrase already present in the downloaded text is never a new refusal.
    public static func hasIntroducedRefusal(_ reply: String, original: String) -> Bool {
        let patterns = [
            #"(?i)\bi\s+(?:can(?:not|'t|’t)|am\s+unable\s+to|am\s+not\s+able\s+to)\s+(?:respond|response|comply|fulfil[l]?|assist|help|process|provide|complete|answer|continue|generate)[^\n.!?。！？]{0,160}"#,
            #"(?i)\bi(?:'m|’m|\s+am)\s+sorry[^\n.!?。！？]{0,100}(?:request|content|assist|help)[^\n.!?。！？]{0,80}"#,
            #"(?:抱歉|对不起|很遗憾|我无法|我不能|无法协助|无法满足)[^\n。！？]{0,100}(?:请求|提供|协助|处理|生成|回答|违规|政策|敏感)[^\n。！？]{0,80}"#
        ]
        let canonicalSource = canonical(original)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = reply as NSString
            for match in regex.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
                let phrase = canonical(ns.substring(with: match.range))
                if !canonicalSource.contains(phrase) { return true }
            }
        }
        return false
    }

    private static func canonical(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }
}
