import Foundation

/// Capability hints derived from the executable rule fields, not raw metadata.
/// Basic JS runs in the isolated interpreter. Host APIs and rule locations not
/// wired into that interpreter remain restricted; this is not a network health
/// verdict and cannot statically prove that an arbitrary script will succeed.
public struct SourceCompatibility: Equatable, Sendable {

    /// How much of the source the available rule runtimes can execute.
    public enum Level: Int, Comparable, Sendable {
        /// Declarative rules and/or basic JS with no known missing capabilities.
        case supported = 0
        /// Some rule slots require unavailable capabilities. Critical selectors
        /// remain, but actual readability still needs to be tested.
        case degraded = 1
        /// A critical rule has no selector and requires an unavailable capability.
        case unreadable = 2

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var level: Level
    /// All roles containing JS, including supported JS. Empty for declarative sources.
    public var roles: [String]
    /// Critical roles with unavailable capabilities and no declarative selector.
    public var blockingRoles: [String]
    /// Whether any rule calls into `org.jsoup`, which needs a DOM bridge.
    public var usesDOM: Bool
    /// Whether any rule calls `java.ajax` / `java.get` / `java.put`, which needs
    /// a second request or cross-request state.
    public var usesNetwork: Bool

    /// JS presence and compatibility are separate: supported JS is still JS.
    public var hasJavaScript: Bool { !roles.isEmpty }
    public var unsupportedRoles: [String] = []
    public var unsupportedFeatures: [String] = []

    public var javaScriptNote: String? {
        guard hasJavaScript else { return nil }
        if unsupportedRoles.isEmpty {
            return "基础 JS 可执行；书源是否可用仍需实际检测。"
        }
        let features = unsupportedFeatures.joined(separator: "、")
        return "\(unsupportedRoles.joined(separator: "、"))的 JS 尚不兼容"
            + (features.isEmpty ? "。" : "（\(features)）。")
            + "基础字符串、数组与 JSON 处理已支持。"
    }

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
        var executableHere = true
    }

    public static func analyze(_ source: BookSource, supportsJavaScript: Bool = JavaScriptRuntime.isAvailable) -> SourceCompatibility {
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
            Slot(role: "发现页", rule: source.exploreURL, blocking: false, executableHere: false),
            Slot(role: "搜索地址", rule: source.searchURL, blocking: true),
            Slot(role: "章节名", rule: source.toc.chapterName, blocking: true),
            Slot(role: "章节链接", rule: source.toc.chapterURL, blocking: true),
            Slot(role: "发现列表", rule: source.explore.bookList, blocking: false),
            Slot(role: "发现书名", rule: source.explore.name, blocking: false),
            Slot(role: "发现链接", rule: source.explore.bookURL, blocking: false),
            Slot(role: "作者", rule: source.search.author, blocking: false),
            Slot(role: "详情书名", rule: source.bookInfo.name, blocking: false),
            Slot(role: "详情作者", rule: source.bookInfo.author, blocking: false),
            Slot(role: "搜索简介", rule: source.search.intro, blocking: false),
            Slot(role: "搜索分类", rule: source.search.kind, blocking: false),
            Slot(role: "详情分类", rule: source.bookInfo.kind, blocking: false),
            Slot(role: "搜索最新章节", rule: source.search.lastChapter, blocking: false),
            Slot(role: "搜索更新时间", rule: source.search.updateTime, blocking: false),
            Slot(role: "详情更新时间", rule: source.bookInfo.updateTime, blocking: false),
            Slot(role: "搜索字数", rule: source.search.wordCount, blocking: false),
            Slot(role: "付费章节判断", rule: source.toc.isVIP, blocking: false),
            Slot(role: "分卷判断", rule: source.toc.isVolume, blocking: false),
            Slot(role: "请求头脚本", rule: source.header, blocking: false, executableHere: false),
        ]

        var roles: [String] = []
        var blockingRoles: [String] = []
        var usesDOM = false
        var usesNetwork = false
        var unsupportedRoles: [String] = []
        var unsupportedFeatures = Set<String>()

        for slot in slots {
            guard let inspection = inspect(slot.rule) else { continue }
            if !roles.contains(slot.role) { roles.append(slot.role) }
            let hosts = JavaScriptRuleSyntax.unsupportedHosts(in: slot.rule)
            let validSyntax = (try? JavaScriptRuleSyntax.parse(slot.rule)) != nil
            let supported = supportsJavaScript && slot.executableHere && hosts.isEmpty && validSyntax
            if !supported {
                if !unsupportedRoles.contains(slot.role) { unsupportedRoles.append(slot.role) }
                unsupportedFeatures.formUnion(hosts)
                if !supportsJavaScript { unsupportedFeatures.insert("当前平台无 JS 引擎") }
                if !slot.executableHere { unsupportedFeatures.insert("此处脚本尚未接入") }
                if !validSyntax { unsupportedFeatures.insert("规则格式") }
            }
            if !supported && slot.blocking && !inspection.keepsSelector {
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
            level: unsupportedRoles.isEmpty ? .supported : (blockingRoles.isEmpty ? .degraded : .unreadable),
            roles: roles,
            blockingRoles: blockingRoles,
            usesDOM: usesDOM,
            usesNetwork: usesNetwork,
            unsupportedRoles: unsupportedRoles,
            unsupportedFeatures: unsupportedFeatures.sorted()
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
        do {
            if try JavaScriptRuleSyntax.parse(rule) == nil { return nil }
        } catch { /* A malformed script still needs a compatibility warning. */ }

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
