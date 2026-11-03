import Foundation

/// Converts legado ("阅读") book sources into `BookSource` values.
///
/// The importer is intentionally forgiving: unknown fields are ignored, missing
/// rules fall back to sensible defaults, and anything it cannot map (mostly JS
/// based rules) is reported through `warnings` instead of failing the import.
public enum LegadoImporter {

    public struct ImportResult: Sendable {
        public var sources: [BookSource]
        public var warnings: [String]
    }

    public static func importSources(fromJSON text: String) throws -> ImportResult {
        guard let data = text.data(using: .utf8) else {
            throw ImportError.invalidEncoding
        }
        return try importSources(from: data)
    }

    public static func importSources(from data: Data) throws -> ImportResult {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        var objects: [[String: JSONValue]] = []

        switch value {
        case .array(let items):
            objects = items.compactMap(\.objectValue)
        case .object(let object):
            // Some exports wrap the list: { "data": [...] }
            if let nested = object["data"]?.arrayValue {
                objects = nested.compactMap(\.objectValue)
            } else {
                objects = [object]
            }
        default:
            throw ImportError.notAnObject
        }

        var sources: [BookSource] = []
        var warnings: [String] = []

        for object in objects {
            guard let name = object.string("bookSourceName") ?? object.string("name"), !name.isEmpty else {
                warnings.append("跳过一条缺少名称的书源")
                continue
            }
            guard let baseURL = object.string("bookSourceUrl") ?? object.string("url"), !baseURL.isEmpty else {
                warnings.append("书源「\(name)」缺少站点地址，已跳过")
                continue
            }

            let searchRuleObject = object.object("ruleSearch") ?? [:]
            let exploreRuleObject = object.object("ruleExplore") ?? [:]
            let infoObject = object.object("ruleBookInfo") ?? [:]
            let tocObject = object.object("ruleToc") ?? [:]
            let contentObject = object.object("ruleContent") ?? [:]

            var source = BookSource(
                name: name,
                baseURL: normalizeBase(baseURL),
                group: object.string("bookSourceGroup") ?? "",
                comment: object.string("bookSourceComment") ?? "",
                type: SourceType(rawValue: object.int("bookSourceType") ?? 0) ?? .text,
                enabled: object.bool("enabled") ?? true,
                enabledExplore: object.bool("enabledExplore") ?? false,
                header: object.string("header") ?? "",
                searchURL: object.string("searchUrl") ?? "",
                exploreURL: object.string("exploreUrl") ?? "",
                search: searchRule(from: searchRuleObject),
                explore: searchRule(from: exploreRuleObject),
                bookInfo: BookInfoRule(
                    name: infoObject.string("name") ?? "",
                    author: infoObject.string("author") ?? "",
                    intro: infoObject.string("intro") ?? "",
                    kind: infoObject.string("kind") ?? "",
                    lastChapter: infoObject.string("lastChapter") ?? "",
                    updateTime: infoObject.string("updateTime") ?? "",
                    coverURL: infoObject.string("coverUrl") ?? "",
                    tocURL: infoObject.string("tocUrl") ?? "",
                    wordCount: infoObject.string("wordCount") ?? ""
                ),
                toc: TOCRule(
                    chapterList: tocObject.string("chapterList") ?? "",
                    chapterName: tocObject.string("chapterName") ?? "",
                    chapterURL: tocObject.string("chapterUrl") ?? "",
                    isVIP: tocObject.string("isVip") ?? "",
                    isVolume: tocObject.string("isVolume") ?? "",
                    updateTime: tocObject.string("updateTime") ?? "",
                    nextTOCURL: tocObject.string("nextTocUrl") ?? ""
                ),
                content: ContentRule(
                    content: contentObject.string("content") ?? "",
                    nextContentURL: contentObject.string("nextContentUrl") ?? "",
                    sourceRegex: contentObject.string("sourceRegex") ?? "",
                    replaceRegex: contentObject.string("replaceRegex") ?? "",
                    imageStyle: contentObject.string("imageStyle") ?? ""
                ),
                originalJSON: JSONValue.object(object).jsonText
            )

            if source.toc.chapterName.isEmpty { source.toc.chapterName = "@text" }
            if source.toc.chapterURL.isEmpty { source.toc.chapterURL = "@href" }
            if source.type != .text {
                warnings.append("书源「\(name)」类型为音频/图片，当前版本按文本处理")
            }
            sources.append(source)
        }

        if sources.isEmpty {
            warnings.append("没有导入任何书源")
        }
        return ImportResult(sources: sources, warnings: warnings)
    }

    private static func searchRule(from object: [String: JSONValue]) -> SearchRule {
        SearchRule(
            bookList: object.string("bookList") ?? "",
            name: object.string("name") ?? "",
            author: object.string("author") ?? "",
            intro: object.string("intro") ?? "",
            kind: object.string("kind") ?? "",
            lastChapter: object.string("lastChapter") ?? "",
            updateTime: object.string("updateTime") ?? "",
            bookURL: object.string("bookUrl") ?? "",
            coverURL: object.string("coverUrl") ?? "",
            wordCount: object.string("wordCount") ?? "",
            checkKeyWord: object.string("checkKeyWord")
        )
    }

    /// Legado lets a source carry a trailing `#分组` after its address — the
    /// real source above ends with `#🎃` — and that fragment is a label, not
    /// part of the site. Left in place it becomes part of every request URL.
    private static func normalizeBase(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = text.firstIndex(of: "#") {
            text = String(text[..<hash])
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public enum ImportError: LocalizedError {
        case invalidEncoding
        case notAnObject

        public var errorDescription: String? {
            switch self {
            case .invalidEncoding: return "书源文件编码无法识别"
            case .notAnObject: return "这不是一个有效的书源 JSON"
            }
        }
    }
}

private extension [String: JSONValue] {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func int(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func object(_ key: String) -> [String: JSONValue]? {
        self[key]?.objectValue
    }
}
