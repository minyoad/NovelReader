import Foundation

/// One tab on a source's discover page.
///
/// Legado sources describe their discover page as a newline-separated list of
/// `name::url` pairs. The URL often carries `{{page}}`, which the reader
/// substitutes when the category is opened or paged through.
///
/// A line may also carry a trailing option block — `url,{"ruleExplore":{...}}`
/// — that overrides how that one category is parsed. Real sources lean on it
/// heavily, so the block travels with the category rather than the source.
public struct ExploreCategory: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var url: String
    /// Per-category option block, parsed when the line was read.
    public var options: [String: JSONValue]

    public init(name: String, url: String, options: [String: JSONValue] = [:]) {
        self.name = name
        self.url = url
        self.options = options
    }

    /// The option block rendered as JSON, for diagnostics.
    public var optionsJson: String {
        guard !options.isEmpty else { return "(空)" }
        return JSONValue.object(options).jsonText
    }

    /// Whether this category carries its own parsing rules.
    ///
    /// A category without its own block falls back to the source-level
    /// `explore` rules, so this alone does not decide usability — see
    /// `canOpen(exploreRules:)`.
    public var hasRules: Bool {
        guard let rule = options["ruleExplore"]?.objectValue else { return false }
        return !(rule["bookList"]?.stringValue ?? "").isEmpty
    }

    /// Whether a book can actually be listed for this category.
    ///
    /// The rules used are the category's own when it has them, otherwise the
    /// source's. Both empty means the tab would open onto a page nothing can
    /// parse, which is the common shape of a half-configured legacy source.
    public func canOpen(exploreRules: SearchRule) -> Bool {
        let rule = hasRules ? ownBookList : exploreRules.bookList
        return !rule.isEmpty && !Self.isUnsupported(rule)
    }

    /// `bookList` from this category's own block, when it has one.
    private var ownBookList: String {
        let rule = options["ruleExplore"]?.objectValue
        return rule?["bookList"]?.stringValue ?? ""
    }

    /// Whether a selector needs JavaScript to produce anything.
    ///
    /// Legado lets a source compute its list with `@js:` — 🎉搜狗阅读 ships a
    /// fully obfuscated script there, appended to a plain selector as
    /// `.list li@js:...`. The engine cannot run either form, so the category
    /// would always come back empty; offering such a tab is the exact failure
    /// the reader complains about.
    ///
    /// A rule that merely *mentions* `@js:` in a string literal is rare enough
    /// that treating it as unsupported is the safer side of the trade.
    public static func isUnsupported(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@js:")
            || trimmed.contains("<js>")
            || trimmed.contains("@js<")
    }
}

/// Parses `exploreUrl` strings into categories.
///
/// Kept separate from the engine so the format — which comes from a third-party
/// app and varies in whitespace, separators, and blank lines — can be tested
/// without a network.
public enum ExploreParser {

    /// Categories in the order the source lists them.
    ///
    /// Entries without a `:` are skipped rather than guessed at: a bare URL
    /// gives nothing to label the tab with, and inventing a name would put
    /// unlabelled tabs in front of the reader.
    public static func categories(from exploreURL: String) -> [ExploreCategory] {
        var seen = Set<String>()
        var result: [ExploreCategory] = []

        for rawLine in splitEntries(exploreURL) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Legado puts the separator on the left: `name::/url`. Because `:`
            // is allowed inside a URL (`https://…`), the split has to be made
            // in a fixed order rather than by counting colons.
            let name: String
            var rest: String
            if let range = line.range(of: "::") {
                name = String(line[..<range.lowerBound])
                rest = String(line[range.upperBound...])
            } else {
                // Older sources still use a single colon.
                let parts = line.split(
                    separator: ":",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2 else { continue }
                name = String(parts[0])
                rest = String(parts[1])
            }

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !rest.isEmpty else { continue }
            guard seen.insert(trimmedName).inserted else { continue }

            let (url, options) = splitOptions(rest)
            guard !url.isEmpty else { continue }
            result.append(ExploreCategory(name: trimmedName, url: url, options: options))
        }
        return result
    }

    /// Splits `exploreUrl` into category entries.
    ///
    /// Legado separates entries with newlines, but `&&` is also accepted and
    /// real sources use it — 🥈31小说 writes its whole list on one line as
    /// `/list/1/&&修真::/list/2/&&都市::/list/3/`. Without this the entire
    /// string becomes a single bogus address.
    static func splitEntries(_ exploreURL: String) -> [String] {
        exploreURL
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "&&", with: "\n")
            .components(separatedBy: "\n")
    }

    ///
    /// Options are optional: a malformed or unterminated block leaves the
    /// whole tail on the URL rather than throwing the category away, since the
    /// address is still what the request needs.
    static func splitOptions(_ raw: String) -> (String, [String: JSONValue]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brace = indexOfOptionsBlock(in: text) else { return (text, [:]) }

        let rawURL = String(text[..<brace])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The split leaves the separating comma on the address; it is part of
        // the syntax (`url,{...}`), not of the URL.
        let url = rawURL.hasSuffix(",") ? String(rawURL.dropLast()) : rawURL
        let body = String(text[brace...])
        for candidate in [body, body.replacingOccurrences(of: "'", with: "\"")] {
            guard let data = candidate.data(using: .utf8) else { continue }
            let value = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
            if let value { return (url, value) }
        }
        return (text, [:])
    }

    /// Where the opening `{` of a trailing `,{...}` block sits, if the block is
    /// balanced and closes on this line.
    /// Scanned on UTF-8 bytes: legado option blocks are full of backslash
    /// escapes for newlines, and matching those one `Character` at a time is
    /// far more delicate than counting bytes.
    private static func indexOfOptionsBlock(in text: String) -> String.Index? {
        let bytes = Array(text.utf8)
        guard let blockStart = optionBlockStart(in: bytes) else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = blockStart

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    // Byte offsets only line up with `String.Index` at a
                    // character boundary, and a brace is ASCII.
                    return text.index(text.startIndex, offsetBy: blockStart)
                }
            }
            index += 1
        }
        // An unterminated block is a broken rule. Returning `nil` keeps the
        // whole line as the address instead of truncating it at a guess.
        return nil
    }

    /// The byte offset of the `{` that opens a trailing `,{...}` block.
    ///
    /// Searched backwards for a comma *immediately* followed by `{`. Taking the
    /// last comma outright is wrong: option blocks contain their own commas
    /// (`{"a":"x","b":"y"}`), and picking one of those splits the JSON in half.
    private static func optionBlockStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        var index = bytes.count - 2
        while index >= 0 {
            if bytes[index] == UInt8(ascii: ","),
               bytes[index + 1] == UInt8(ascii: "{") {
                return index + 1
            }
            index -= 1
        }
        return nil
    }

    /// The URL for one page of a category.
    ///
    /// Paging is expressed as `{{page}}` in the address itself; the option
    /// block controls parsing rather than addressing.
    public static func url(for category: ExploreCategory, page: Int) -> String {
        substitutePage(in: category.url, page: page)
    }

    /// Where paging actually happens, when the URL says so in its option block.
    ///
    /// Some sources keep a static category address and step through pages with
    /// a POST body such as `page={{page}}`; without this the category would
    /// show the same first page forever.
    public static func body(for category: ExploreCategory, page: Int) -> String? {
        guard let template = category.options["body"]?.stringValue, !template.isEmpty else { return nil }
        return substitutePage(in: template, page: page)
    }

    private static func substitutePage(in template: String, page: Int) -> String {
        let number = String(max(page, 1))
        var text = template
        for token in ["{{page}}", "{{ page }}", "@page"] {
            text = text.replacingOccurrences(of: token, with: number)
        }
        return text
    }
}
