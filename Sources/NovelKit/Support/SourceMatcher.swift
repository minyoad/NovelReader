import Foundation

/// Ranks search hits by how likely they are the same book.
///
/// Author is deliberately a *hint*, not a filter. Mirror sites routinely
/// mislabel it — bqg6 lists 《剑来》 as 「手机可乐床」, deqitxt has the correct
/// 「烽火戏诸侯」 — so requiring agreement would throw away the only readable
/// copy of a book. Title overlap is the hard requirement; author agreement only
/// reorders candidates.
public enum SourceMatcher {

    /// Scores a candidate hit against what the shelf already knows about a book.
    /// Returns `nil` when the title cannot plausibly be the same work.
    public static func score(
        candidateName: String,
        candidateAuthor: String,
        wantedTitle: String,
        wantedAuthor: String
    ) -> Int? {
        let title = normalizedTitle(candidateName)
        let wanted = normalizedTitle(wantedTitle)
        guard !title.isEmpty, !wanted.isEmpty else { return nil }

        let author = normalizedAuthor(candidateAuthor)
        let wantedWriter = normalizedAuthor(wantedAuthor)
        let sameAuthor = !wantedWriter.isEmpty && !author.isEmpty
            && (author == wantedWriter || author.contains(wantedWriter) || wantedWriter.contains(author))

        var total: Int
        if title == wanted {
            total = 100
        } else if sameAuthor, title.hasPrefix(wanted) || wanted.hasPrefix(title) {
            // Same title core *and* the same author: extra words are almost
            // certainly decoration the normalizer did not know about.
            total = 40
        } else {
            // A prefix with a different author is a different book:
            // 《剑来》 vs 《剑来杂谈》/《剑来大纲》/《剑来封天》.
            return nil
        }

        if sameAuthor {
            total += 50
        } else if !wantedWriter.isEmpty, !author.isEmpty {
            // Wrong author, but the mirror may simply lie. Keep it as a last
            // resort; callers still verify the chapter body.
            total -= 20
        }
        return total
    }

    /// Sorts hits by score, then by title length so `剑来` beats
    /// `剑来（精校版）` when both match equally well.
    public static func rank(
        _ results: [SearchResult],
        wantedTitle: String,
        wantedAuthor: String
    ) -> [SearchResult] {
        results
            .compactMap { result -> (SearchResult, Int)? in
                guard let value = score(
                    candidateName: result.name,
                    candidateAuthor: result.author,
                    wantedTitle: wantedTitle,
                    wantedAuthor: wantedAuthor
                ) else { return nil }
                return (result, value)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.count < rhs.0.name.count
            }
            .map(\.0)
    }

    /// Strips decorations sites wrap titles in, so `《剑来》` and
    /// `剑来（完结）` compare equal.
    static func normalizedTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["《", "》", "「", "」", "【", "】", "（", "）", "(", ")", "[", "]", "·"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        for suffix in ["最新章节", "全文阅读", "免费阅读", "无弹窗", "笔趣阁", "小说"] {
            text = text.replacingOccurrences(of: suffix, with: "")
        }
        return text.replacingOccurrences(of: " ", with: "").lowercased()
    }

    static func normalizedAuthor(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["作者：", "作者:", "作    者：", "著", "\u{3000}"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        return text.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
