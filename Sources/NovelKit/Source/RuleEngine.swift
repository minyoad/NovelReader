import Foundation
import SwiftSoup

/// Where a rule is evaluated.
public struct RuleScope {
    public enum Payload {
        case element(Element)
        case json(JSONValue)
        case text(String)
    }

    public var payload: Payload
    public var baseURL: URL?

    public init(payload: Payload, baseURL: URL? = nil) {
        self.payload = payload
        self.baseURL = baseURL
    }

    public static func html(_ html: String, baseURL: URL?) -> RuleScope {
        let document = (try? SwiftSoup.parse(html)) ?? Document("")
        let root = document.body() ?? document
        return RuleScope(payload: .element(root), baseURL: baseURL)
    }

    public var plainText: String {
        switch payload {
        case .element(let element): return (try? element.text()) ?? ""
        case .json(let value): return value.stringValue ?? value.jsonText
        case .text(let text): return text
        }
    }

    public var html: String {
        switch payload {
        case .element(let element): return (try? element.html()) ?? ""
        case .json(let value): return value.stringValue ?? value.jsonText
        case .text(let text): return text
        }
    }

    public var element: Element? {
        if case .element(let element) = payload { return element }
        return nil
    }

    public var json: JSONValue? {
        if case .json(let value) = payload { return value }
        return nil
    }
}

/// Evaluates legado-style rule strings against HTML or JSON documents.
///
/// Supported syntax:
/// - `selector1@@selector2` — fallback chain (first non-empty wins)
/// - `rule##regex##replacement` — regex post-processing
/// - `@css:`, `@json:` / `$.`, `@XPath:` (best effort), `:regex`
/// - legado path syntax: `class.foo@tag.li@tag.a@href`, `id.content@html`, `text.下一页@href`
/// - `{{variable}}` interpolation
///
/// JavaScript rules (`@js:`, `<js>`) are not supported and reported as warnings.
public struct RuleEngine {
    public var variables: [String: String]
    public var onWarning: ((String) -> Void)?

    public init(variables: [String: String] = [:], onWarning: ((String) -> Void)? = nil) {
        self.variables = variables
        self.onWarning = onWarning
    }

    // MARK: - Public API

    /// All nodes matched by a list rule (book list, chapter list, ...).
    public func scopes(for rule: String, in scope: RuleScope) -> [RuleScope] {
        let (base, _, _) = splitPostProcessing(rule)

        // A list rule may carry an exclusion suffix such as `!0` (drop the
        // header row) or `!0:1:2` / `!-1`. In legado these indexes are
        // *removed* from the result, not kept.
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var excluded: [Int] = []
        if let bang = text.lastIndex(of: "!"),
           !text[text.index(after: bang)...].isEmpty,
           text[text.index(after: bang)...].allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" }) {
            let spec = String(text[text.index(after: bang)...])
            text = String(text[..<bang])
            excluded = spec.split(separator: ":").compactMap { Int($0) }
        }

        for alternative in text.components(separatedBy: "@@") {
            let trimmed = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            var (segments, _) = compile(interpolate(trimmed))
            if segments.isEmpty { continue }

            // JSON sources keep a single opaque path: send it to the JSON
            // selector instead of resolving it as CSS.
            let raw = interpolate(trimmed)
            var nodes: [RuleScope]
            if raw.hasPrefix("@json:") || raw.hasPrefix("@jsonpath:") || raw.hasPrefix("$") {
                nodes = select(raw, in: scope)
            } else {
                // `tr:has(.odd):lt(6)` mixes jQuery-ish filters into the selector;
                // SwiftSoup understands `:has()` and `:lt()` is translated here.
                var limit: Int? = nil
                if let last = segments.last,
                   let match = RegexHelper.firstMatch(":lt\\((\\d+)\\)", in: last.css, group: 1),
                   let number = Int(match) {
                    limit = number
                    segments[segments.count - 1].css =
                        RegexHelper.replace(":lt\\(\\d+\\)", in: last.css, with: "")
                }
                nodes = resolve(segments, in: scope)
                if let limit {
                    nodes = Array(nodes.prefix(limit))
                }
            }

            if !excluded.isEmpty {
                nodes = remove(excluded, from: nodes)
            }
            if !nodes.isEmpty { return nodes }
        }
        return []
    }

    /// legado exclusion syntax: remove the listed indexes (`!0`, `!0:1:2`,
    /// `!-1` counts from the end).
    private func remove(_ spec: [Int], from nodes: [RuleScope]) -> [RuleScope] {
        guard !nodes.isEmpty else { return nodes }
        var drop = Set<Int>()
        for index in spec {
            let resolved = index < 0 ? nodes.count + index : index
            if nodes.indices.contains(resolved) { drop.insert(resolved) }
        }
        return nodes.enumerated()
            .filter { !drop.contains($0.offset) }
            .map(\.element)
    }

    /// The first non-empty string produced by a rule.
    public func value(_ rule: String, in scope: RuleScope) -> String? {
        values(rule, in: scope).first
    }

    /// Every string produced by a rule.
    public func values(_ rule: String, in scope: RuleScope) -> [String] {
        let (base, regex, replacement) = splitPostProcessing(rule)

        // legado: `a||b` tries a, then b; `a&&b` concatenates both.
        for alternative in base.components(separatedBy: "||") {
            let trimmed = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let pieces = trimmed.components(separatedBy: "&&")
            var results: [String]
            if pieces.count == 1 {
                results = rawValues(pieces[0], in: scope)
            } else {
                let first = pieces.compactMap { rawValues($0, in: scope).first }
                results = first.isEmpty ? [] : [first.joined()]
            }
            if results.isEmpty { continue }

            let processed = results
                .map { applyReplacements($0, regex: regex, replacement: replacement) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !processed.isEmpty { return processed }
        }
        return []
    }

    /// Every string produced by a single selector path (no `||` / `&&`).
    private func rawValues(_ rule: String, in scope: RuleScope) -> [String] {
        for alternative in rule.components(separatedBy: "@@") {
            let trimmed = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let expanded = interpolate(trimmed)
            // JSON paths (`$.a`, `@json:`) stay whole; they are not CSS.
            if expanded.hasPrefix("@json:") || expanded.hasPrefix("@jsonpath:") || expanded.hasPrefix("$") {
                let nodes = select(expanded, in: scope)
                let results = nodes.compactMap { extractValue(from: $0, mode: nil) }.filter { !$0.isEmpty }
                if !results.isEmpty { return results }
                continue
            }
            // `:regex` pulls matches straight out of the node text.
            if expanded.hasPrefix(":") {
                let nodes = select(expanded, in: scope)
                let results = nodes.map { $0.plainText }.filter { !$0.isEmpty }
                if !results.isEmpty { return results }
                continue
            }

            let (segments, extract) = compile(expanded)
            // `@text` / `@href` with no selector means "the current node".
            let nodes: [RuleScope]
            if segments.isEmpty {
                guard extract != nil else { continue }
                nodes = [scope]
            } else {
                nodes = resolve(segments, in: scope)
            }

            var results: [String] = []
            for node in nodes {
                if let text = extractValue(from: node, mode: extract), !text.isEmpty {
                    results.append(text)
                }
            }
            if !results.isEmpty { return results }
        }
        return []
    }

    public func boolValue(_ rule: String, in scope: RuleScope) -> Bool {
        guard let text = value(rule, in: scope) else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if ["false", "0", "no", "否", "不是"].contains(normalized) { return false }
        return true
    }

    // MARK: - Selection

    /// One step of a legado path: a CSS selector plus an optional 0-based index
    /// that applies to the matches *within each* current node.
    private struct SelectorSegment {
        var css: String
        var index: Int?
    }

    /// Resolves a compiled path segment by segment. Doing this per segment lets
    /// us honour legado's `.n` index (`td.0`, `tag.a.1`) which is applied to
    /// each parent separately — SwiftSoup has no `:eq()` to express that.
    private func resolve(_ segments: [SelectorSegment], in scope: RuleScope) -> [RuleScope] {
        var current = [scope]
        for segment in segments {
            var next: [RuleScope] = []
            for node in current {
                var matches = selectCSS(segment.css, in: node)
                if let index = segment.index {
                    if matches.indices.contains(index) {
                        matches = [matches[index]]
                    } else {
                        matches = []
                    }
                }
                next.append(contentsOf: matches)
            }
            if next.isEmpty { return [] }
            current = next
        }
        return current
    }

    private func select(_ rule: String, in scope: RuleScope) -> [RuleScope] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if rule.hasPrefix("@css:") {
            return selectCSS(String(rule.dropFirst(5)), in: scope)
        }
        if rule.hasPrefix("@XPath:") || rule.hasPrefix("@xpath:") {
            let xpath = String(rule.dropFirst(7))
            return selectCSS(xpathToCSS(xpath), in: scope)
        }
        if rule.hasPrefix("@json:") {
            return selectJSON(String(rule.dropFirst(6)), in: scope)
        }
        if rule.hasPrefix("@jsonpath:") {
            return selectJSON(String(rule.dropFirst(10)), in: scope)
        }
        if rule.hasPrefix("@js:") || rule.contains("<js>") || rule.contains("@js<") {
            onWarning?("暂不支持 JavaScript 规则：\(rule.prefix(60))")
            return []
        }
        if rule.hasPrefix(":") {
            return selectRegex(String(rule.dropFirst()), in: scope)
        }
        if rule.hasPrefix("$") {
            return selectJSON(rule, in: scope)
        }
        return selectCSS(rule, in: scope)
    }

    private func selectCSS(_ selector: String, in scope: RuleScope) -> [RuleScope] {
        let (css, index) = normalizeLegadoSelector(selector)
        var base: Element?
        switch scope.payload {
        case .element(let element):
            base = element
        case .text:
            // Allow selectors against text that contains HTML.
            if let parsed = try? SwiftSoup.parse(scope.html) {
                base = parsed.body()
            }
        case .json:
            if let parsed = try? SwiftSoup.parse(scope.html) {
                base = parsed.body()
            }
        }
        guard let root = base else { return [] }

        var elements: [Element]
        if css.isEmpty {
            elements = [root]
        } else {
            elements = (try? root.select(css).array()) ?? []
            if elements.isEmpty, let document = root.ownerDocument(), let found = try? document.select(css).array(), !found.isEmpty {
                elements = found
            }
        }

        if let index, elements.indices.contains(index) {
            elements = [elements[index]]
        }
        return elements.map { RuleScope(payload: .element($0), baseURL: scope.baseURL) }
    }

    private func selectJSON(_ path: String, in scope: RuleScope) -> [RuleScope] {
        let root: JSONValue
        switch scope.payload {
        case .json(let value):
            root = value
        case .text(let text):
            guard let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
            root = value
        case .element(let element):
            let text = (try? element.text()) ?? ""
            guard let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
            root = value
        }

        let cleaned = path.trimmingCharacters(in: .whitespaces)
        return JSONPath.evaluate(cleaned, on: root).map {
            RuleScope(payload: .json($0), baseURL: scope.baseURL)
        }
    }

    private func selectRegex(_ pattern: String, in scope: RuleScope) -> [RuleScope] {
        let text = scope.plainText
        return RegexHelper.allMatches(pattern, in: text, options: [.dotMatchesLineSeparators])
            .map { RuleScope(payload: .text($0), baseURL: scope.baseURL) }
    }

    // MARK: - Extraction

    private enum ExtractMode {
        case text
        case textNodes
        case ownText
        case html
        case outerHTML
        case attribute(String)
    }

    private func extractValue(from scope: RuleScope, mode: ExtractMode?) -> String? {
        switch scope.payload {
        case .json(let value):
            if let text = value.stringValue { return text }
            if let array = value.arrayValue {
                let strings = array.compactMap { $0.stringValue ?? ($0.arrayValue?.compactMap(\.stringValue).joined(separator: ",")) }
                return strings.isEmpty ? nil : strings.joined(separator: ",")
            }
            if let object = value.objectValue {
                let text = object.values.compactMap(\.stringValue).joined(separator: " ")
                return text.isEmpty ? value.jsonText : text
            }
            return nil
        case .text(let text):
            return text
        case .element(let element):
            switch mode {
            case .none, .text:
                return (try? element.text())
            case .textNodes:
                let nodes = element.textNodes()
                let text = nodes.map { $0.text() }.joined(separator: "\n")
                return text.isEmpty ? (try? element.text()) : text
            case .ownText:
                return element.ownText()
            case .html:
                return (try? element.html())
            case .outerHTML:
                return (try? element.outerHtml())
            case .attribute(let name):
                let raw = (try? element.attr(name)) ?? ""
                if raw.isEmpty { return nil }
                if name == "href" || name == "src" || name == "data-src" || name == "data-original" {
                    if let resolved = TextProcessing.resolveURL(raw, base: scope.baseURL) {
                        return resolved
                    }
                }
                return raw
            }
        }
    }

    // MARK: - Rule compilation

    private func splitPostProcessing(_ rule: String) -> (String, String?, String?) {
        let parts = rule.components(separatedBy: "##")
        // legado allows `rule##regex` (replace with nothing) as well as
        // `rule##regex##replacement`. Requiring three parts silently broke any
        // rule that only strips matches.
        guard parts.count >= 2, !parts[0].isEmpty else { return (rule, nil, nil) }
        let base = parts[0]
        let regex = parts[1]
        let replacement = parts.count > 2 ? parts[2] : ""
        return (base, regex.isEmpty ? nil : regex, replacement)
    }

    private func applyReplacements(_ text: String, regex: String?, replacement: String?) -> String {
        guard let regex, !regex.isEmpty else { return text }
        let pattern: String
        // legado users often write `##\\s+##`; treat plain text as literal.
        if regex.hasPrefix("{{") { pattern = regex } else { pattern = regex }
        return RegexHelper.replace(pattern, in: text, with: replacement ?? "")
    }

    private func interpolate(_ rule: String) -> String {
        guard rule.contains("{{"), !variables.isEmpty else { return rule }
        var result = rule
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Splits a legado path into selector segments plus the extraction step.
    private func compile(_ rule: String) -> ([SelectorSegment], ExtractMode?) {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return ([], nil) }

        if text.hasPrefix("@js:") || text.contains("<js>") || text.contains("@js<") {
            onWarning?("暂不支持 JavaScript 规则：\(text.prefix(60))")
            return ([], nil)
        }
        if text.hasPrefix("@css:") {
            text = String(text.dropFirst(5))
        } else if text.hasPrefix("@XPath:") || text.hasPrefix("@xpath:") {
            text = xpathToCSS(String(text.dropFirst(7)))
        } else if text.hasPrefix("@json:") {
            return ([SelectorSegment(css: String(text.dropFirst(6)), index: nil)], nil)
        } else if text.hasPrefix("@jsonpath:") {
            return ([SelectorSegment(css: String(text.dropFirst(10)), index: nil)], nil)
        } else if text.hasPrefix("$") {
            return ([SelectorSegment(css: text, index: nil)], nil)
        }

        var tokens = text.components(separatedBy: "@")
        var mode: ExtractMode?

        if let last = tokens.last, let parsed = extractMode(for: last) {
            mode = parsed
            tokens.removeLast()
        }

        var segments: [SelectorSegment] = []
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let segment = selectorSegment(from: trimmed) {
                segments.append(segment)
            }
        }
        return (segments, mode)
    }

    private func extractMode(for token: String) -> ExtractMode? {
        switch token.trimmingCharacters(in: .whitespaces) {
        case "text": return .text
        case "textNodes", "textnodes": return .textNodes
        case "ownText", "owntext": return .ownText
        case "html": return .html
        case "outerHtml", "outerhtml": return .outerHTML
        case "content": return .html
        default:
            if token.hasPrefix("attr.") {
                return .attribute(String(token.dropFirst(5)))
            }
            // Bare attribute names that show up in real sources.
            let known = ["href", "src", "data-src", "data-original", "title", "alt", "content", "value"]
            let name = token.trimmingCharacters(in: .whitespaces)
            if known.contains(name) { return .attribute(name) }
            return nil
        }
    }

    /// Converts one legado path segment into a CSS selector plus an index.
    private func selectorSegment(from token: String) -> SelectorSegment? {
        // legado index suffix: `class.odd.0`, `tag.a.1`, `id.list.2`. A trailing
        // dotted number after the real selector is an index, not a class name.
        var body = token
        var index: Int?
        if let match = RegexHelper.firstMatch("\\.(\\d+)$", in: body, group: 1), let number = Int(match) {
            // Only treat it as an index when something precedes it, so `.2`
            // alone (a real class) keeps working.
            let stripped = RegexHelper.replace("\\.\\d+$", in: body, with: "")
            if !stripped.isEmpty && !stripped.hasSuffix(".") {
                index = number
                body = stripped
            }
        }

        if body.hasPrefix("class.") {
            let value = String(body.dropFirst(6))
            let css = value.split(separator: " ").map { ".\($0)" }.joined()
            return SelectorSegment(css: css, index: index)
        }
        if body.hasPrefix("tag.") {
            return SelectorSegment(css: String(body.dropFirst(4)), index: index)
        }
        if body.hasPrefix("id.") {
            let css = "#" + String(body.dropFirst(3)).replacingOccurrences(of: " ", with: "")
            return SelectorSegment(css: css, index: index)
        }
        if body.hasPrefix("text.") {
            let value = String(body.dropFirst(5))
            return SelectorSegment(css: ":contains(\(value))", index: index)
        }
        if body.hasPrefix("children") || body.hasPrefix("parent") || body.hasPrefix("sibling") {
            onWarning?("暂不支持路径关键字：\(body)")
            return nil
        }
        // Raw CSS (allows hand-written selectors in custom sources).
        return SelectorSegment(css: body, index: index)
    }

    /// Normalizes a selector, pulling a trailing `[n]` or `.n` index out of it.
    private func normalizeLegadoSelector(_ selector: String) -> (String, Int?) {
        var css = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        var index: Int?

        if let match = RegexHelper.firstMatch("\\[(\\d+)\\]$", in: css, group: 1), let number = Int(match) {
            index = number
            css = RegexHelper.replace("\\[\\d+\\]$", in: css, with: "")
        }
        // `.0` style index at the very end of a path segment.
        if let match = RegexHelper.firstMatch("\\.(\\d+)$", in: css, group: 1), let number = Int(match),
           css.contains(".") {
            index = number
            css = RegexHelper.replace("\\.\\d+$", in: css, with: "")
        }
        return (css, index)
    }

    // MARK: - XPath (best effort)

    /// Converts the small XPath subset that book sources commonly use:
    /// `//div[@class='list']//a/@href`, `//*[@id="content"]/text()`.
    private func xpathToCSS(_ xpath: String) -> String {
        var text = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        var extraction = ""
        if text.hasSuffix("/text()") {
            extraction = "@text"
            text = String(text.dropLast(7))
        } else if let range = text.range(of: "/@") {
            extraction = "@" + String(text[range.upperBound...])
            text = String(text[..<range.lowerBound])
        }

        let segments = text.components(separatedBy: "/").filter { !$0.isEmpty && $0 != "." }
        var parts: [String] = []
        for segment in segments {
            var segment = segment
            if segment.hasPrefix("@") { continue }
            var tag = "*"
            if let bracket = segment.firstIndex(of: "[") {
                tag = String(segment[..<bracket])
                segment = String(segment[bracket...])
            } else {
                tag = segment
                segment = ""
            }
            if tag.isEmpty { tag = "*" }

            var css = tag
            if !segment.isEmpty, let regex = RegexHelper.regex("\\[([^\\]]+)\\]") {
                let predicates = regex.matches(in: segment, options: [], range: NSRange(segment.startIndex..., in: segment))
                for predicate in predicates {
                    guard let range = Range(predicate.range(at: 1), in: segment) else { continue }
                    let body = String(segment[range])
                    if let value = RegexHelper.firstMatch("@class\\s*=\\s*['\"]([^'\"]+)['\"]", in: body, group: 1) {
                        css += value.split(separator: " ").map { ".\($0)" }.joined()
                    } else if let value = RegexHelper.firstMatch("@id\\s*=\\s*['\"]([^'\"]+)['\"]", in: body, group: 1) {
                        css += "#" + value
                    } else if let value = RegexHelper.firstMatch("@([a-zA-Z-]+)\\s*=\\s*['\"]([^'\"]+)['\"]", in: body, group: 2),
                              let attribute = RegexHelper.firstMatch("@([a-zA-Z-]+)\\s*=", in: body, group: 1) {
                        css += "[\(attribute)=\"\(value)\"]"
                    } else if let value = RegexHelper.firstMatch("^(\\d+)$", in: body, group: 1), let number = Int(value) {
                        css += ":nth-child(\(number))"
                    }
                }
            }
            parts.append(css)
        }
        let selector = parts.joined(separator: " ")
        return extraction.isEmpty ? selector : selector + extraction
    }
}
