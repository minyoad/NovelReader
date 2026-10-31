import Foundation

/// A deliberately small JSONPath evaluator: enough for the paths book sources
/// actually use (`$.data.list[*].name`, `$..name`, `$.items[0].url`).
public enum JSONPath {
    private enum Step: Equatable {
        case key(String)
        case index(Int)
        case wildcard
        case recursiveKey(String)
        case recursiveWildcard
        case union([String])
    }

    public static func evaluate(_ path: String, on root: JSONValue) -> [JSONValue] {
        guard let steps = parse(path), !steps.isEmpty else { return [root] }
        var current: [JSONValue] = [root]
        for step in steps {
            var next: [JSONValue] = []
            for value in current {
                switch step {
                case .key(let key):
                    if let child = value[key] { next.append(child) }
                case .index(let index):
                    if let child = value[index] { next.append(child) }
                case .wildcard:
                    if let array = value.arrayValue { next.append(contentsOf: array) }
                    else if let object = value.objectValue { next.append(contentsOf: object.keys.sorted().compactMap { object[$0] }) }
                case .recursiveKey(let key):
                    collect(key: key, in: value, into: &next)
                case .recursiveWildcard:
                    collectAll(in: value, into: &next)
                case .union(let keys):
                    for key in keys {
                        if let child = value[key] { next.append(child) }
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    public static func strings(_ path: String, on root: JSONValue) -> [String] {
        evaluate(path, on: root).compactMap { value in
            if let text = value.stringValue { return text }
            if let array = value.arrayValue { return array.compactMap(\.stringValue).joined(separator: ",") }
            return nil
        }.filter { !$0.isEmpty }
    }

    private static func collect(key: String, in value: JSONValue, into result: inout [JSONValue]) {
        if let object = value.objectValue {
            if let child = object[key] { result.append(child) }
            for childKey in object.keys.sorted() {
                if let child = object[childKey] { collect(key: key, in: child, into: &result) }
            }
        } else if let array = value.arrayValue {
            for child in array { collect(key: key, in: child, into: &result) }
        }
    }

    private static func collectAll(in value: JSONValue, into result: inout [JSONValue]) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                if let child = object[key] { result.append(child); collectAll(in: child, into: &result) }
            }
        case .array(let array):
            for child in array { result.append(child); collectAll(in: child, into: &result) }
        default:
            break
        }
    }

    private static func parse(_ path: String) -> [Step]? {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "$" { return [] }
        if text.hasPrefix("$") { text.removeFirst() }
        // Some sources omit the leading "$."; keep `..name` intact for descent.
        if text.hasPrefix("."), !text.hasPrefix("..") { text.removeFirst() }

        var steps: [Step] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "." {
                var lookahead = text.index(after: index)
                var recursive = false
                if lookahead < text.endIndex, text[lookahead] == "." {
                    recursive = true
                    lookahead = text.index(after: lookahead)
                }
                if lookahead < text.endIndex, text[lookahead] == "*" {
                    steps.append(recursive ? .recursiveWildcard : .wildcard)
                    index = text.index(after: lookahead)
                    continue
                }
                var name = ""
                var cursor = lookahead
                while cursor < text.endIndex, text[cursor] != ".", text[cursor] != "[" {
                    name.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if !name.isEmpty {
                    steps.append(recursive ? .recursiveKey(name) : .key(name))
                }
                index = cursor
                continue
            }

            if character == "[" {
                guard let closing = text[index...].firstIndex(of: "]") else { return steps.isEmpty ? nil : steps }
                let inner = text[text.index(after: index)..<closing].trimmingCharacters(in: .whitespaces)
                if inner == "*" {
                    steps.append(.wildcard)
                } else if let number = Int(inner) {
                    steps.append(.index(number))
                } else {
                    let keys = inner.split(separator: ",").map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    }
                    if keys.count == 1 {
                        steps.append(.key(keys[0]))
                    } else {
                        steps.append(.union(keys))
                    }
                }
                index = text.index(after: closing)
                continue
            }

            // Bare key at the start (e.g. "data.list").
            var name = ""
            var cursor = index
            while cursor < text.endIndex, text[cursor] != ".", text[cursor] != "[" {
                name.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            if !name.isEmpty { steps.append(.key(name)) }
            index = cursor
        }
        return steps
    }
}
