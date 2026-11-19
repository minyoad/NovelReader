import Foundation

public struct TextPurificationRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var enabled = true
    public var pattern = ""
    public var replacement = ""
    public var isRegex = false
    public init() {}

    public var validationError: String? {
        guard !pattern.isEmpty else { return "匹配内容不能为空" }
        guard pattern.count <= 2048 else { return "匹配内容最多 2048 个字符" }
        guard replacement.count <= 2048 else { return "替换内容最多 2048 个字符" }
        if isRegex {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { return "正则表达式无效：\(error.localizedDescription)" }
        }
        return nil
    }
}

public struct TextPurificationSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var rules: [TextPurificationRule] = []
    public init() {}
}

public struct TextPurificationResult: Sendable {
    public let text: String
    public let warnings: [String]
}

public enum TextPurification {
    /// Never persists transformed text. Limits apply to the entire pass; a
    /// timed-out/oversized rule leaves its input intact, including on preview.
    public static func apply(_ input: String, settings: TextPurificationSettings) -> TextPurificationResult {
        guard settings.enabled else { return TextPurificationResult(text: input, warnings: []) }
        guard input.utf16.count <= 2_000_000 else {
            return TextPurificationResult(text: input, warnings: ["正文过长，已跳过净化"])
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        var text = input
        var warnings: [String] = []
        for (index, rule) in settings.rules.prefix(50).enumerated() where rule.enabled {
            if let error = rule.validationError { warnings.append("规则 \(index + 1)：\(error)"); continue }
            let pattern = rule.isRegex ? rule.pattern : NSRegularExpression.escapedPattern(for: rule.pattern)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let template = rule.isRegex ? rule.replacement : NSRegularExpression.escapedTemplate(for: rule.replacement)
            let source = text as NSString
            var matches: [NSTextCheckingResult] = []
            var aborted = false
            regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
                if ProcessInfo.processInfo.systemUptime > deadline || matches.count >= 10000 {
                    aborted = true; stop.pointee = true; return
                }
                if let match { matches.append(match) }
            }
            if aborted { warnings.append("规则 \(index + 1) 超时或匹配过多，已跳过"); break }
            let output = NSMutableString(string: text)
            for match in matches.reversed() {
                if ProcessInfo.processInfo.systemUptime > deadline { aborted = true; break }
                let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
                if output.length - match.range.length + replacement.utf16.count > 2_000_000 { aborted = true; break }
                output.replaceCharacters(in: match.range, with: replacement)
            }
            if aborted { warnings.append("规则 \(index + 1) 处理超时或输出过长，已跳过") }
            else { text = output as String }
        }
        return TextPurificationResult(text: text, warnings: warnings)
    }
}

public struct ShelfReadingProgress: Sendable {
    public let fraction: Double?
    public let label: String
    public init(progress: ReadingProgress, chapterCount: Int, textLength: Int? = nil) {
        guard progress.isStarted, !(progress.chapterIndex == 0 && progress.characterOffset == 0 && progress.chapterTitle.isEmpty) else { fraction = nil; label = "未读"; return }
        let index = max(0, progress.chapterIndex)
        guard chapterCount > 0 else {
            fraction = nil; label = "读至第 \(index + 1) 章"; return
        }
        let chapter = min(index, chapterCount - 1)
        let within = textLength.flatMap { $0 > 0 ? min(1, max(0, Double(progress.characterOffset) / Double($0))) : nil } ?? 0
        let value = min(1, max(0, (Double(chapter) + within) / Double(chapterCount)))
        fraction = value
        label = "约 \(Int(value * 100))% · \(chapter + 1)/\(chapterCount) 章"
    }
}
