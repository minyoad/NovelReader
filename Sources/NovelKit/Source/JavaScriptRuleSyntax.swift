import Foundation

/// Replaces script bodies with opaque tokens before legado operators are split.
/// JS strings, comments, templates and regex literals are scanned so a literal
/// `</js>` is not mistaken for the end of a tagged rule.
struct JavaScriptRuleSyntax {
    let protectedRule: String
    let scripts: [String: String]

    static func containsScript(_ rule: String) -> Bool {
        do { return try parse(rule) != nil }
        catch { return true }
    }

    static func parse(_ rule: String) throws -> Self? {
        guard rule.contains("@js:") || rule.contains("<js>") || rule.contains("@js<") else { return nil }
        guard rule.utf8.count <= 1024 * 1024 else { throw JavaScriptRuleError.invalidRule("规则超过大小限制") }
        let characters = Array(rule)
        var index = 0
        var quote: Character?
        var output = ""
        var scripts: [String: String] = [:]
        let prefix = "__NOVEL_JS_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_"
        while index < characters.count {
            let char = characters[index]
            if let current = quote {
                output.append(char)
                if char == "\\", index + 1 < characters.count {
                    index += 1
                    output.append(characters[index])
                } else if char == current { quote = nil }
                index += 1
                continue
            }
            if char == "'" || char == "\"" { quote = char; output.append(char); index += 1; continue }
            let terminal = matches(characters, index, "@js:")
            let tagged = matches(characters, index, "<js>")
            if matches(characters, index, "@js<") {
                throw JavaScriptRuleError.invalidRule("请使用 @js: 或 <js>…</js> 标记")
            }
            if terminal || tagged {
                let start = index + 4
                let end: Int
                if terminal { end = characters.count }
                else {
                    guard let closing = closingTag(in: characters, from: start) else {
                        throw JavaScriptRuleError.invalidRule("缺少 </js> 结束标记")
                    }
                    end = closing
                }
                let token = "\(prefix)\(scripts.count)__"
                scripts[token] = String(characters[start..<end])
                output += token
                index = terminal ? end : end + 5
            } else {
                output.append(char)
                index += 1
            }
        }
        return scripts.isEmpty ? nil : Self(protectedRule: output, scripts: scripts)
    }

    /// Host APIs are capability hints, not a security boundary. Actual isolation
    /// comes from exposing no native objects in the bounded interpreter.
    static func unsupportedHosts(in rule: String) -> Set<String> {
        guard let parsed = try? parse(rule) else {
            return rule.contains("@js<") || rule.contains("<js>") ? ["规则格式"] : []
        }
        let hosts = Set(["java", "Packages", "org", "Jsoup", "android", "javax", "window", "document",
                         "fetch", "XMLHttpRequest", "cookie", "source", "book", "chapter", "getElements", "getString"])
        var found = Set<String>()
        for script in parsed.scripts.values {
            let chars = Array(script)
            scan(chars, from: 0) { start, end in
                let name = String(chars[start..<end])
                var previous = start - 1
                while previous >= 0 && chars[previous].isWhitespace { previous -= 1 }
                var next = end
                while next < chars.count && chars[next].isWhitespace { next += 1 }
                if hosts.contains(name), (previous < 0 || chars[previous] != "."),
                   (next == chars.count || chars[next] != ":") { found.insert(name) }
            }
        }
        return found
    }

    static func requiresUnavailableRuntime(_ rule: String) -> Bool {
        do {
            guard try parse(rule) != nil else { return false }
            return !JavaScriptRuntime.isAvailable || !unsupportedHosts(in: rule).isEmpty
        } catch { return true }
    }

    func stages(in text: String) -> [(script: Bool, text: String)] {
        var remaining = text[...]
        var stages: [(Bool, String)] = []
        while !remaining.isEmpty {
            let next = scripts.keys.compactMap { token -> (Range<String.Index>, String)? in
                remaining.range(of: token).map { ($0, token) }
            }.min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, token) = next else { stages.append((false, String(remaining))); break }
            if range.lowerBound > remaining.startIndex { stages.append((false, String(remaining[..<range.lowerBound]))) }
            stages.append((true, scripts[token]!))
            remaining = remaining[range.upperBound...]
        }
        return stages
    }

    private static func matches(_ text: [Character], _ index: Int, _ marker: String) -> Bool {
        text[index...].starts(with: marker)
    }

    private static func closingTag(in characters: [Character], from start: Int) -> Int? {
        scan(characters, from: start, stopAtClosingTag: true) { _, _ in }
    }

    @discardableResult
    private static func scan(_ chars: [Character], from start: Int, stopAtClosingTag: Bool = false,
                             stopAtClosingBrace: Bool = false,
                             depth: Int = 0,
                             identifier: (Int, Int) -> Void) -> Int? {
        guard depth < 64 else { return nil }
        var index = start
        var permitsRegex = true
        var braces = 1
        while index < chars.count {
            let char = chars[index]
            if stopAtClosingTag && matches(chars, index, "</js>") { return index }
            if char.isWhitespace { index += 1; continue }
            if stopAtClosingBrace {
                if char == "{" { braces += 1 }
                if char == "}" {
                    braces -= 1
                    if braces == 0 { return index }
                }
            }
            if char == "'" || char == "\"" || char == "`" {
                let quote = char
                index += 1
                while index < chars.count {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == quote { index += 1; break }
                    if quote == "`", matches(chars, index, "${") {
                        guard let end = scan(chars, from: index + 2, stopAtClosingBrace: true, depth: depth + 1, identifier: identifier) else { return nil }
                        index = end + 1
                        continue
                    }
                    index += 1
                }
                permitsRegex = false
                continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                index += 2
                while index < chars.count && chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count && !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index = min(index + 2, chars.count)
                continue
            }
            if char == "/" && permitsRegex {
                index += 1
                var inClass = false
                while index < chars.count {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == "[" { inClass = true }
                    if chars[index] == "]" { inClass = false }
                    if chars[index] == "/" && !inClass { index += 1; break }
                    index += 1
                }
                while index < chars.count && chars[index].isLetter { index += 1 }
                permitsRegex = false
                continue
            }
            if char.isLetter || char == "_" || char == "$" {
                let begin = index
                index += 1
                while index < chars.count && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_" || chars[index] == "$") { index += 1 }
                identifier(begin, index)
                permitsRegex = ["return", "throw", "case", "typeof", "void", "delete", "yield", "await", "in", "of"].contains(String(chars[begin..<index]))
                continue
            }
            permitsRegex = "=(:,;!&|?{[+*-~%^<>".contains(char)
            index += 1
        }
        return nil
    }
}
