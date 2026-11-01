import Foundation

/// Whether a source's rules can actually be executed by this build.
///
/// The rule engine implements the declarative half of legado — CSS, XPath,
/// JSONPath, `##` replacements — and skips JavaScript rules. Skipping is not
/// equally harmful everywhere:
///
/// * `class.cover@img@src<js> ...` loses a transformation on something
///   cosmetic. The book still reads.
/// * `<js> ...` as the *whole* chapter-list rule loses the selector too, so
///   there is nothing left to match and the source cannot produce a single
///   chapter.
///
/// Before this existed the difference was invisible until a book failed to
/// open, and the error said "书源规则可能已失效" — which is wrong and sends the
/// user looking for a new source instead of a different one. Importing showed a
/// warning, but it scrolled away with the alert.
///
/// The analysis is derived from the parsed rules, never from `originalJSON`:
/// the raw JSON of every legado source mentions JS somewhere in its comments and
/// metadata, and treating that as a problem would mark all 55 sources.
public struct SourceCompatibility: Equatable, Sendable {

    /// How much of the source still works without JavaScript.
    public enum Level: Int, Comparable, Sendable {
        /// No JavaScript in any rule.
        case supported = 0
        /// JavaScript is skipped, but every rule keeps a selector that still
        /// produces something. Reading works; some field may be plainer than
        /// the site intended (a cover URL missing, a translated body left in
        /// traditional characters).
        case degraded = 1
        /// A rule the reader cannot do without is JavaScript-only, so no amount
        /// of fallback gets a chapter out of this source.
        case unreadable = 2

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var level: Level
    /// Roles whose JavaScript is skipped, in the order a reader meets them.
    /// Empty when `level == .supported`.
    public var roles: [String]
    /// The subset of `roles` that has no selector left once the JavaScript is
    /// removed — the ones that actually break something.
    public var blockingRoles: [String]
    /// Whether any rule calls into `org.jsoup`, which needs a DOM bridge.
    public var usesDOM: Bool
    /// Whether any rule calls `java.ajax` / `java.get` / `java.put`, which needs
    /// a second request or cross-request state.
    public var usesNetwork: Bool

    public var hasJavaScript: Bool { level != .supported }

    public static let clean = SourceCompatibility(
        level: .supported,
        roles: [],
        blockingRoles: [],
        usesDOM: false,
        usesNetwork: false
    )

    // MARK: - Analysis

    /// The markers legado uses to start a JavaScript rule.
    private static let markers = ["@js:", "<js>", "@js<"]

    /// One rule slot and how badly losing its JavaScript hurts.
    private struct Slot {
        let role: String
        let rule: String
        /// A blocking slot is one that has no fallback in the engine: if its
        /// selector disappears, the source yields nothing to read.
        let blocking: Bool
    }

    public static func analyze(_ source: BookSource) -> SourceCompatibility {
        let slots: [Slot] = [
            // Blocking: the engine has no fallback for an empty chapter list or
            // an empty search result list, so these fail outright.
            Slot(role: "目录", rule: source.toc.chapterList, blocking: true),
            Slot(role: "搜索列表", rule: source.search.bookList, blocking: true),
            Slot(role: "书名", rule: source.search.name, blocking: true),
            Slot(role: "搜索结果链接", rule: source.search.bookURL, blocking: true),

            // Degraded: `SourceEngine` falls back to guessing the body element,
            // and a missing TOC URL falls back to the detail page.
            Slot(role: "正文", rule: source.content.content, blocking: false),
            Slot(role: "目录地址", rule: source.bookInfo.tocURL, blocking: false),
            Slot(role: "正文翻页", rule: source.content.nextContentURL, blocking: false),

            // Not about reading at all: losing these only costs a field.
            Slot(role: "目录翻页", rule: source.toc.nextTOCURL, blocking: false),
            Slot(role: "简介", rule: source.bookInfo.intro, blocking: false),
            Slot(role: "封面", rule: source.bookInfo.coverURL, blocking: false),
            Slot(role: "封面", rule: source.search.coverURL, blocking: false),
            Slot(role: "字数", rule: source.bookInfo.wordCount, blocking: false),
            Slot(role: "最新章节", rule: source.bookInfo.lastChapter, blocking: false),
            Slot(role: "发现页", rule: source.exploreURL, blocking: false),
        ]

        var roles: [String] = []
        var blockingRoles: [String] = []
        var usesDOM = false
        var usesNetwork = false

        for slot in slots {
            guard let inspection = inspect(slot.rule) else { continue }
            if !roles.contains(slot.role) { roles.append(slot.role) }
            if slot.blocking && !inspection.keepsSelector {
                if !blockingRoles.contains(slot.role) { blockingRoles.append(slot.role) }
            }
            if inspection.usesDOM { usesDOM = true }
            if inspection.usesNetwork { usesNetwork = true }
        }

        // `exploreURL` and the per-item `explore` rules are the one place where
        // a JavaScript-only rule is harmless: 发现 is optional.
        if roles.isEmpty {
            return .clean
        }

        return SourceCompatibility(
            level: blockingRoles.isEmpty ? .degraded : .unreadable,
            roles: roles,
            blockingRoles: blockingRoles,
            usesDOM: usesDOM,
            usesNetwork: usesNetwork
        )
    }

    // MARK: - One rule

    private struct Inspection {
        /// Whether the part before the JavaScript still selects something.
        var keepsSelector: Bool
        var usesDOM: Bool
        var usesNetwork: Bool
    }

    /// Returns `nil` when the rule contains no JavaScript at all.
    private static func inspect(_ rule: String) -> Inspection? {
        guard let cut = javascriptStart(in: rule) else { return nil }

        let selector = rule[rule.startIndex..<cut]
        let script = rule[cut...]

        return Inspection(
            keepsSelector: hasSelector(selector),
            usesDOM: script.contains("org.jsoup") || script.contains("Jsoup"),
            usesNetwork: script.contains("java.ajax")
                || script.contains("java.connect")
                || script.contains("java.get(")
                || script.contains("java.put(")
                || script.contains("java.setContent(")
        )
    }

    /// Index of the earliest JavaScript marker, or `nil` when there is none.
    private static func javascriptStart(in rule: String) -> String.Index? {
        var earliest: String.Index?
        for marker in markers {
            guard let range = rule.range(of: marker) else { continue }
            if let current = earliest {
                if range.lowerBound < current { earliest = range.lowerBound }
            } else {
                earliest = range.lowerBound
            }
        }
        return earliest
    }

    /// Whether a rule prefix still names something to select.
    ///
    /// The prefix is normally a legado path (`article@html`, `a!1@href`). It is
    /// empty when the rule is JavaScript from the first character, and it can be
    /// left as a bare operator (`+`) — legado's "append to the previous value"
    /// marker, which on its own selects nothing.
    private static func hasSelector(_ prefix: Substring) -> Bool {
        let operators: Set<Character> = ["+", "-", "!", "@", " ", "\t", "\n", "\r", "&"]
        return prefix.contains { !operators.contains($0) }
    }
}

public extension BookSource {
    /// What this build can do with these rules. See `SourceCompatibility`.
    var compatibility: SourceCompatibility {
        SourceCompatibility.analyze(self)
    }
}
