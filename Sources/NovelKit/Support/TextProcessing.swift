import Foundation

/// Text cleanup that is independent of any particular source: HTML stripping,
/// paragraph normalization, and removal of the boilerplate Chinese novel sites
/// love to inject into chapter bodies.
public enum TextProcessing {

    // MARK: - HTML

    private static let entityMap: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "hellip": "…",
        "mdash": "—", "ndash": "–", "middot": "·", "copy": "©", "reg": "®",
        "times": "×", "divide": "÷", "laquo": "«", "raquo": "»",
    ]

    /// Converts an HTML fragment to plain text, keeping paragraph structure.
    public static func plainText(fromHTML html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html

        // Drop non-content blocks entirely.
        text = RegexHelper.replace("(?is)<(script|style|noscript|iframe|svg)[^>]*>.*?</\\1>", in: text, with: "")

        // Turn block boundaries into newlines.
        text = RegexHelper.replace("(?i)<br\\s*/?>", in: text, with: "\n")
        text = RegexHelper.replace("(?i)</(p|div|section|article|h[1-6]|li|tr|blockquote|dd)\\s*>", in: text, with: "\n")
        text = RegexHelper.replace("(?i)<(p|div|section|article|h[1-6]|li|tr|blockquote|dd)(\\s[^>]*)?>", in: text, with: "\n")
        text = RegexHelper.replace("(?i)<hr\\s*/?>", in: text, with: "\n")

        // Strip the remaining tags.
        text = RegexHelper.replace("<[^>]+>", in: text, with: "")

        text = unescapeEntities(text)
        // Block boundaries above produce empty lines; a chapter body only needs
        // one newline per paragraph.
        text = RegexHelper.replace("\\n{2,}", in: text, with: "\n")
        return normalizeParagraphs(text)
    }

    public static func unescapeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        if let regex = RegexHelper.regex("&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]{1,10});") {
            let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: result) else { continue }
                let name = String(result[nameRange])
                let replacement: String
                if name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let scalarValue: UInt32?
                    if digits.first == "x" || digits.first == "X" {
                        scalarValue = UInt32(String(digits.dropFirst()), radix: 16)
                    } else {
                        scalarValue = UInt32(String(digits))
                    }
                    if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                        replacement = String(Character(scalar))
                    } else {
                        replacement = ""
                    }
                } else {
                    replacement = entityMap[name.lowercased()] ?? ""
                }
                result.replaceSubrange(whole, with: replacement)
            }
        }
        return result
    }

    // MARK: - Normalization

    /// Trims every line, removes zero-width characters and collapses runs of blank lines.
    public static func normalizeParagraphs(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\u{00A0}", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\u{3000}", with: " ")
        for zeroWidth in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"] {
            cleaned = cleaned.replacingOccurrences(of: zeroWidth, with: "")
        }

        var lines: [String] = []
        for rawLine in cleaned.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(line)
            }
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Chapter cleanup

    private static let adPatterns: [String] = [
        "(?i)\\bhttps?://[\\w\\-./?=&%#]+",
        "www\\.[\\w\\-]+\\.(com|net|cn|cc|la|info|org|xyz|top|vip|me|tv|co)",
        "本站域名", "本站网址", "请记住本站", "记住本站", "收藏本站", "加入书签",
        "最新网址", "最新域名", "唯一网址", "备用网址", "手机版阅读网址",
        "章节错误.*?举报", "求月票", "求推荐票", "求收藏", "求订阅", "求打赏",
        "本章未完.*?下一页", "点击下一页继续", "请点击下一页",
        "笔趣阁", "biquge", "顶点小说", "无错小说", "全本小说", "txt下载",
        "一秒记住", "精彩小说", "无弹窗", "免费阅读",
        "（本章完）", "如果您觉得.*?不错",
    ]

    /// Removes lines that are pure site boilerplate and de-duplicates repeated paragraphs.
    public static func cleanupChapterText(_ text: String) -> String {
        var paragraphs = normalizeParagraphs(text).components(separatedBy: "\n")

        paragraphs = paragraphs.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            if trimmed.count <= 2 { return true }
            for pattern in adPatterns {
                if RegexHelper.isMatch(pattern, in: trimmed, options: [.caseInsensitive]) {
                    // Only drop the line when the ad pattern makes up most of it.
                    if let match = RegexHelper.firstMatch(pattern, in: trimmed, options: [.caseInsensitive]),
                       Double(match.count) / Double(max(trimmed.count, 1)) > 0.5 {
                        return false
                    }
                }
            }
            return true
        }

        // Drop consecutive duplicates (very common with paginated chapters).
        var deduped: [String] = []
        for line in paragraphs {
            if line == deduped.last { continue }
            deduped.append(line)
        }
        return normalizeParagraphs(deduped.joined(separator: "\n"))
    }

    // MARK: - Placeholder detection

    /// Markers some sites serve instead of the real chapter body once the free
    /// preview runs out ("内容正在获取中，稍候重试"), or while anti-scraping
    /// replaces the text with junk. Treating these as real content poisons the
    /// cache, so callers should fail loudly instead.
    private static let placeholderPatterns: [String] = [
        "内容正在获取中", "正在获取中", "稍候重试", "稍后重试",
        "正在手打中", "正在加载中", "内容加载中", "请稍候",
        "本章内容正在", "正文正在", "章节内容正在",
        "暂无内容", "本章未完", "正在更新中",
    ]

    /// True when the text is dominated by a site placeholder rather than prose.
    public static func isPlaceholderContent(_ text: String, chapterTitle: String? = nil) -> Bool {
        let trimmed = normalizeParagraphs(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Real chapters are long; anything under a couple of hundred characters
        // that also mentions a placeholder is certainly not the body.
        let looksShort = trimmed.count < 300
        for pattern in placeholderPatterns where trimmed.contains(pattern) {
            if looksShort { return true }
            // Long pages can still carry the marker in a header/footer; only
            // fail when the marker makes up a real share of the text, or when
            // the chapter title itself is echoed next to it.
            let ratio = Double(pattern.count) / Double(max(trimmed.count, 1))
            if ratio > 0.02 { return true }
            if let title = chapterTitle, !title.isEmpty, trimmed.contains(title), trimmed.count < 1200 { return true }
        }
        return false
    }

    // MARK: - Sentences (used by TTS)

    /// Splits a chapter into speakable sentences. Long sentences are further
    /// chopped so the synthesizer stays responsive and highlighting stays useful.
    public static func sentences(from text: String, maxLength: Int = 110) -> [String] {
        let normalized = normalizeParagraphs(text)
        var sentences: [String] = []
        var buffer = ""

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(contentsOf: splitLong(trimmed, maxLength: maxLength)) }
            buffer = ""
        }

        for character in normalized {
            if character == "\n" {
                flush()
                continue
            }
            buffer.append(character)
            if "。！？…；!?;".contains(character) {
                flush()
            }
        }
        flush()
        return sentences
    }

    private static func splitLong(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        let limit = max(maxLength, 10)
        let softBreaks: Set<Character> = ["，", "、", ",", "：", ":", " ", "；", ";"]
        var result: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            let shouldBreakEarly = current.count >= limit / 2 && softBreaks.contains(character)
            if current.count >= limit || shouldBreakEarly {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    // MARK: - URLs

    public static func resolveURL(_ link: String, base: URL?) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return (base?.scheme ?? "https") + ":" + trimmed
        }
        if let url = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return url.absoluteString
        }
        return trimmed
    }

    public static func absoluteURL(_ link: String, base: URL?) -> URL? {
        guard let resolved = resolveURL(link, base: base) else { return nil }
        return URL(string: resolved)
    }
}
