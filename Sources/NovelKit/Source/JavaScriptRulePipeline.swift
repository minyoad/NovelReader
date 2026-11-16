import Foundation

/// A script that timed out for one item must not consume the same budget for
/// every other item in a long search/TOC response. A new engine permits retry.
final class JavaScriptRuleBudget {
    private let lock = NSLock()
    private var timedOut = Set<String>()

    func permits(_ script: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !timedOut.contains(script)
    }

    func stop(_ script: String) {
        lock.lock()
        defer { lock.unlock() }
        timedOut.insert(script)
    }
}

extension RuleScope {
    var javascriptInput: JSONValue {
        if let sourceText { return .string(sourceText) }
        switch payload {
        case .json(let value): return value
        case .text(let value): return .string(value)
        case .element: return .string(html)
        }
    }
}

extension RuleEngine {
    /// nil means ordinary declarative syntax; [] means a JS rule had no match
    /// or failed, and must not silently return untransformed/decrypted input.
    func javascriptScopes(_ rule: String, in scope: RuleScope, list: Bool) -> [RuleScope]? {
        let parsed: JavaScriptRuleSyntax
        do {
            guard let syntax = try JavaScriptRuleSyntax.parse(rule) else { return nil }
            parsed = syntax
        } catch {
            onWarning?(error.localizedDescription)
            return []
        }
        let parts = parsed.protectedRule.components(separatedBy: "##")
        var base = parts[0]
        var exclusions: [Int] = []
        if list, let bang = base.lastIndex(of: "!"), !base[base.index(after: bang)...].isEmpty,
           base[base.index(after: bang)...].allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" }) {
            exclusions = base[base.index(after: bang)...].split(separator: ":").compactMap { Int($0) }
            base = String(base[..<bang])
        }
        let regex = parts.count > 1 ? parts[1] : ""
        let replacement = parts.count > 2 ? parts[2] : ""
        for alternative in base.components(separatedBy: "||") {
            let pieces = alternative.components(separatedBy: "&&")
            let results = pieces.map { piece -> [RuleScope] in
                for branch in piece.components(separatedBy: "@@") {
                    do {
                        let results = try runScriptStages(parsed.stages(in: branch), in: scope, list: list)
                        if !results.isEmpty { return results }
                    } catch {
                        onWarning?(error.localizedDescription)
                    }
                }
                return []
            }
            var nodes: [RuleScope]
            if pieces.count > 1 && !list {
                let first = results.compactMap { $0.first.map(scriptText) }
                nodes = first.isEmpty ? [] : [RuleScope(payload: .text(first.joined()), baseURL: scope.baseURL)]
            } else {
                nodes = results.flatMap { $0 }
            }
            if !regex.isEmpty {
                nodes = nodes.map {
                    RuleScope(payload: .text(RegexHelper.replace(regex, in: scriptText($0), with: replacement)), baseURL: $0.baseURL)
                }
            }
            nodes = nodes.filter { !scriptText($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !exclusions.isEmpty {
                let drop = Set(exclusions.map { $0 < 0 ? nodes.count + $0 : $0 })
                nodes = nodes.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            }
            if !nodes.isEmpty { return nodes }
        }
        return []
    }

    func scriptText(_ scope: RuleScope) -> String {
        if case .json(let value) = scope.payload { return value.stringValue ?? value.jsonText }
        return scope.plainText
    }

    private func runScriptStages(_ stages: [(script: Bool, text: String)], in scope: RuleScope, list: Bool) throws -> [RuleScope] {
        var current = [scope]
        var scriptedValue: JSONValue?
        for stage in stages {
            if stage.script {
                guard scriptBudget.permits(stage.text) else {
                    throw JavaScriptRuleError.execution("此脚本已超时，本次解析不再重复执行")
                }
                let input = scriptedValue ?? (current.count == 1 ? current[0].javascriptInput : .array(current.map(\.javascriptInput)))
                let value: JSONValue
                do {
                    value = try JavaScriptRuntime.evaluate(stage.text, result: input, baseURL: scope.baseURL, variables: variables)
                } catch JavaScriptRuleError.timeout {
                    scriptBudget.stop(stage.text)
                    throw JavaScriptRuleError.timeout
                }
                let values = value.arrayValue ?? (value == .null ? [] : [value])
                scriptedValue = value
                current = values.filter { $0 != .null }.map {
                    if case .string(let text) = $0 {
                        return RuleScope(payload: .text(text), baseURL: scope.baseURL)
                    }
                    return RuleScope(payload: .json($0), baseURL: scope.baseURL)
                }
            } else {
                let rule = stage.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if rule.isEmpty || rule == "+" { continue }
                scriptedValue = nil
                let isJSON = rule.hasPrefix("$") || rule.hasPrefix("@json:") || rule.hasPrefix("@jsonpath:")
                let last = rule.components(separatedBy: "@").last ?? ""
                let hasExtraction = ["text", "textNodes", "ownText", "html", "outerHtml", "href", "src", "title", "value", "content"].contains(last)
                    || last.hasPrefix("attr.")
                current = current.flatMap { node in
                    if (list && !hasExtraction) || isJSON { return scopes(for: rule, in: node) }
                    return values(rule, in: node).map { RuleScope(payload: .text($0), baseURL: node.baseURL) }
                }
            }
            if current.isEmpty && !stage.script { return [] }
        }
        return current
    }
}
