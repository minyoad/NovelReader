import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SourceError: LocalizedError {
    case unsupported(String)
    case noResults(String)
    case notFound(String)
    case emptyContent(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return detail
        case .noResults(let detail): return detail
        case .notFound(let detail): return detail
        case .emptyContent(let detail): return detail
        }
    }
}

/// Executes a `BookSource` against the network: search, detail, table of
/// contents and chapter body.
public struct SourceEngine {
    public var client: HTTPClient
    public var onWarning: ((String) -> Void)?

    public init(client: HTTPClient, onWarning: ((String) -> Void)? = nil) {
        self.client = client
        self.onWarning = onWarning
    }

    // MARK: - Search

    public func search(keyword: String, source: BookSource) async throws -> [SearchResult] {
        guard source.canSearch else { throw SourceError.unsupported("书源「\(source.name)」没有配置搜索规则") }

        let (urlString, options) = splitURLOptions(source.searchURL)
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let rawURL = interpolate(urlString, variables: ["key": encoded, "page": "1"])
        // Sources often use a relative `searchUrl` (`/search.php?q=`) plus an
        // absolute `bookSourceUrl`; resolve against the site root.
        let url = TextProcessing.resolveURL(rawURL, base: URL(string: source.baseURL)) ?? rawURL
        let page = try await client.fetch(
            try makeRequest(url: url, options: options, source: source, referer: source.baseURL, variables: ["key": keyword, "page": "1"]),
            referer: source.baseURL
        )

        let root = try scope(for: page, source: source)
        let engine = makeEngine(variables: ["key": keyword, "page": "1"], baseURL: page.finalURL)
        let items = engine.scopes(for: source.search.bookList, in: root)
        if items.isEmpty {
            // A JS-only search list never matches, whatever the site returns.
            if source.compatibility.blockingRoles.contains("搜索列表") {
                throw SourceError.noResults("这个书源的搜索规则是纯 JavaScript，本应用无法执行，请换一个书源")
            }
            // Fall back to the explore rule when it shares the same shape.
            if source.explore.bookList.isEmpty {
                throw SourceError.noResults("没有解析到搜索结果，书源规则可能已失效")
            }
        }

        var results: [SearchResult] = []
        for item in items {
            guard let name = engine.value(source.search.name, in: item), !name.isEmpty else { continue }
            if let check = source.search.checkKeyWord, !check.isEmpty {
                let pageText = page.text
                let keywords = check.components(separatedBy: "|").filter { !$0.isEmpty }
                if !keywords.isEmpty, !keywords.contains(where: { pageText.contains($0) }) { continue }
            }
            guard let detail = engine.value(source.search.bookURL, in: item),
                  let detailURL = TextProcessing.resolveURL(detail, base: page.finalURL) else { continue }
            let cover = engine.value(source.search.coverURL, in: item)
            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                name: name,
                author: engine.value(source.search.author, in: item) ?? "",
                kind: engine.value(source.search.kind, in: item) ?? "",
                lastChapterTitle: engine.value(source.search.lastChapter, in: item) ?? "",
                updateTime: engine.value(source.search.updateTime, in: item) ?? "",
                intro: engine.value(source.search.intro, in: item) ?? "",
                coverURL: cover.flatMap { TextProcessing.resolveURL($0, base: page.finalURL) },
                detailURL: detailURL
            ))
        }
        return results
    }

    // MARK: - Explore (discover page)

    /// One page of a source's discover category.
    ///
    /// Reuses the `explore` rules, which describe the same list shape the
    /// search rules do: a container selector plus per-item name/author/cover.
    /// A category may carry its own option block, and real sources use it to
    /// override the parsing rules for that one category — so those win over
    /// the source-level rules.
    public func explore(
        category: ExploreCategory,
        page: Int,
        source: BookSource
    ) async throws -> [SearchResult] {
        logSource(source, category: category, page: page)

        guard source.canExplore else {
            log("REJECT 书源不可探索 name=\(source.name) enabledExplore=\(source.enabledExplore) exploreURL空=\(source.exploreURL.isEmpty)")
            throw SourceError.unsupported("书源「\(source.name)」没有配置发现页")
        }

        // The page number must be substituted before the address is resolved:
        // categories are written as `/list/{{page}}.html`, and `{{` is not
        // valid in a URL, so resolving first leaves the token in place.
        let pagedURL = ExploreParser.url(for: category, page: page)
        let base = TextProcessing.normalizedBaseURL(source.baseURL)
        let resolved = TextProcessing.resolveURL(pagedURL, base: base) ?? pagedURL
        var variables = ["page": String(max(page, 1)), "key": ""]
        var options = category.options
        if let body = ExploreParser.body(for: category, page: page) {
            options["body"] = .string(body)
            variables["key"] = body
        }
        log("REQUEST url=\(resolved) method=\(options["method"]?.stringValue ?? "GET") body=\(options["body"]?.stringValue ?? "-")")
        let fetched = try await client.fetch(
            try makeRequest(
                url: resolved,
                options: options,
                source: source,
                referer: source.baseURL,
                variables: variables
            ),
            referer: source.baseURL
        )
        log("RESPONSE finalURL=\(fetched.finalURL.absoluteString) status=\(fetched.statusCode) bytes=\(fetched.text.count)")
        ExploreLog.block("HTML_HEAD", String(fetched.text.prefix(600)))

        let root = try scope(for: fetched, source: source)
        let engine = makeEngine(variables: variables, baseURL: fetched.finalURL)
        let rules = Self.exploreRules(for: category, source: source)
        log("RULES 来源=\(Self.exploreRuleOrigin(for: category, source: source)) bookList=\(rules.bookList) name=\(rules.name) bookURL=\(rules.bookURL)")
        if rules.bookList.isEmpty {
            log("REJECT 列表规则为空")
            throw SourceError.unsupported("书源「\(source.name)」的分类「\(category.name)」没有配置列表规则")
        }
        let items = engine.scopes(for: rules.bookList, in: root)
        log("MATCH bookList 命中=\(items.count)")
        guard !items.isEmpty else {
            // The page loaded but the selector matched nothing. Saying so
            // separately from a network failure is what tells us whether to
            // chase the address or the rule.
            throw SourceError.noResults(
                "页面能打开，但列表规则「\(rules.bookList)」没匹配到内容（\(category.url)）"
            )
        }
        if rules.name.isEmpty || rules.bookURL.isEmpty {
            throw SourceError.unsupported(
                "分类「\(category.name)」匹配到 \(items.count) 条，但缺少书名或链接规则"
            )
        }

        var results: [SearchResult] = []
        var dropped = 0
        for item in items {
            guard let name = engine.value(rules.name, in: item), !name.isEmpty else { dropped += 1; continue }
            guard let detail = engine.value(rules.bookURL, in: item),
                  let detailURL = TextProcessing.resolveURL(detail, base: fetched.finalURL) else { dropped += 1; continue }
            let cover = engine.value(rules.coverURL, in: item)
            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                name: name,
                author: engine.value(rules.author, in: item) ?? "",
                kind: engine.value(rules.kind, in: item) ?? "",
                lastChapterTitle: engine.value(rules.lastChapter, in: item) ?? "",
                updateTime: engine.value(rules.updateTime, in: item) ?? "",
                intro: engine.value(rules.intro, in: item) ?? "",
                coverURL: cover.flatMap { TextProcessing.resolveURL($0, base: fetched.finalURL) },
                detailURL: detailURL
            ))
        }
        log("RESULT 解析成功=\(results.count) 丢弃(缺书名或链接)=\(dropped)")
        return results
    }

    private func log(_ message: String) {
        ExploreLog.line(message)
    }

    /// Dumps everything the discover page needs to explain itself.
    private func logSource(_ source: BookSource, category: ExploreCategory, page: Int) {
        log("=== OPEN source=\(source.name) id=\(source.id) page=\(page) ===")
        log("baseURL=\(source.baseURL) enabled=\(source.enabled) enabledExplore=\(source.enabledExplore) canExplore=\(source.canExplore)")
        ExploreLog.block("EXPLORE_URL", source.exploreURL)
        log("SOURCE_RULES bookList=\(source.explore.bookList) name=\(source.explore.name) bookURL=\(source.explore.bookURL) author=\(source.explore.author) coverURL=\(source.explore.coverURL)")
        log("CATEGORY name=\(category.name) url=\(category.url) hasOwnRules=\(category.hasRules)")
        ExploreLog.block("CATEGORY_OPTIONS", category.optionsJson)
        let categories = ExploreParser.categories(from: source.exploreURL)
        log("CATEGORIES total=\(categories.count) openable=\(source.openableExploreCategories.count)")
        for item in categories {
            log("  - name=\(item.name) url=\(item.url) own=\(item.hasRules) openable=\(item.canOpen(exploreRules: source.fallbackExploreRule))")
        }
    }

    /// Legado's per-category `ruleExplore` uses the same field names as
    /// `ruleSearch`, so the importer's mapping applies unchanged.
    ///
    /// Resolution order: the category's own block, then the source's
    /// `ruleExplore`, then `ruleSearch`. The last step matters because a great
    /// many sources ship `"ruleExplore": {}` next to a long `exploreUrl` — the
    /// author relied on the listing page using the same markup as search.
    static func exploreRules(for category: ExploreCategory, source: BookSource) -> SearchRule {
        if let own = category.options["ruleExplore"]?.objectValue.map(Self.searchRule(from:)),
           !own.bookList.isEmpty {
            return own
        }
        return source.fallbackExploreRule
    }

    static func exploreRuleOrigin(for category: ExploreCategory, source: BookSource) -> String {
        if let own = category.options["ruleExplore"]?.objectValue.map(Self.searchRule(from:)),
           !own.bookList.isEmpty {
            return "分类自带"
        }
        return source.explore.bookList.isEmpty ? "回退到搜索规则" : "书源级"
    }

    static func searchRule(from object: [String: JSONValue]) -> SearchRule {
        func text(_ key: String) -> String { object[key]?.stringValue ?? "" }
        return SearchRule(
            bookList: text("bookList"),
            name: text("name"),
            author: text("author"),
            intro: text("intro"),
            kind: text("kind"),
            lastChapter: text("lastChapter"),
            updateTime: text("updateTime"),
            bookURL: text("bookUrl"),
            coverURL: text("coverUrl"),
            wordCount: text("wordCount"),
            checkKeyWord: object["checkKeyWord"]?.stringValue
        )
    }

    // MARK: - Book detail

    public func fetchBookDetail(_ result: SearchResult, source: BookSource) async throws -> Book {
        let page = try await client.fetch(
            try makeRequest(url: result.detailURL, options: [:], source: source, referer: source.baseURL),
            referer: source.baseURL
        )
        let root = try scope(for: page, source: source)
        let engine = makeEngine(variables: ["key": result.name], baseURL: page.finalURL)
        let rule = source.bookInfo

        func field(_ rule: String, _ fallback: String) -> String {
            guard !rule.isEmpty else { return fallback }
            return engine.value(rule, in: root) ?? fallback
        }

        let cover = field(rule.coverURL, result.coverURL ?? "")
        let toc = field(rule.tocURL, "")

        var book = Book(
            sourceID: source.id,
            sourceName: source.name,
            detailURL: page.finalURL.absoluteString,
            name: field(rule.name, result.name),
            author: field(rule.author, result.author),
            intro: field(rule.intro, result.intro),
            kind: field(rule.kind, result.kind),
            coverURL: cover.isEmpty ? nil : TextProcessing.resolveURL(cover, base: page.finalURL),
            lastChapterTitle: field(rule.lastChapter, result.lastChapterTitle),
            updateTime: field(rule.updateTime, result.updateTime),
            wordCount: field(rule.wordCount, ""),
            tocURL: toc.isEmpty ? nil : TextProcessing.resolveURL(toc, base: page.finalURL)
        )
        book.intro = TextProcessing.normalizeParagraphs(book.intro)
        return book
    }

    // MARK: - Table of contents

    public func fetchChapters(book: Book, source: BookSource) async throws -> [Chapter] {
        let startURL = book.tocURL ?? book.detailURL
        var url = startURL
        var chapters: [Chapter] = []
        var visited = Set<String>()

        for _ in 0..<8 {
            if !visited.insert(url).inserted { break }
            let page = try await client.fetch(
                try makeRequest(url: url, options: [:], source: source, referer: book.detailURL),
                referer: book.detailURL
            )
            let root = try scope(for: page, source: source)
            let engine = makeEngine(variables: ["key": book.name], baseURL: page.finalURL)

            let items = engine.scopes(for: source.toc.chapterList, in: root)
            if items.isEmpty && chapters.isEmpty {
                // Say which kind of failure this is. A source whose chapter
                // list is JavaScript-only will never match, no matter what the
                // site returns, so "规则可能已失效" would send the user looking
                // for a page change that never happened.
                if source.compatibility.blockingRoles.contains("目录") {
                    throw SourceError.notFound("这个书源的目录规则是纯 JavaScript，本应用无法执行，请换一个书源")
                }
                throw SourceError.notFound("没有解析到目录，书源规则可能已失效")
            }

            for item in items {
                guard let name = engine.value(source.toc.chapterName, in: item) else { continue }
                guard let href = engine.value(source.toc.chapterURL, in: item),
                      let resolved = TextProcessing.resolveURL(href, base: page.finalURL) else { continue }
                let isVIP = engine.boolValue(source.toc.isVIP, in: item)
                let isVolume = engine.boolValue(source.toc.isVolume, in: item)
                chapters.append(Chapter(index: chapters.count, title: name, url: resolved, isVIP: isVIP, isVolume: isVolume))
            }

            guard !source.toc.nextTOCURL.isEmpty else { break }
            guard let next = engine.value(source.toc.nextTOCURL, in: root),
                  let nextURL = TextProcessing.resolveURL(next, base: page.finalURL),
                  nextURL != url else { break }
            url = nextURL
        }

        return chapters
    }

    // MARK: - Chapter body

    public func fetchContent(book: Book, chapter: Chapter, source: BookSource) async throws -> ChapterContent {
        var url = chapter.url
        var visited = Set<String>()
        var htmlChunks: [String] = []

        for _ in 0..<6 {
            if !visited.insert(url).inserted { break }
            let page = try await client.fetch(
                try makeRequest(url: url, options: [:], source: source, referer: book.detailURL),
                referer: book.detailURL
            )
            let root = try scope(for: page, source: source)
            let engine = makeEngine(variables: ["key": book.name], baseURL: page.finalURL)

            var html = engine.values(source.content.content, in: root).joined(separator: "\n")
            if html.isEmpty {
                html = fallbackContentHTML(from: root) ?? ""
            }
            if html.isEmpty {
                throw SourceError.emptyContent("章节内容为空，书源规则可能已失效")
            }
            htmlChunks.append(html)

            guard !source.content.nextContentURL.isEmpty,
                  let next = engine.value(source.content.nextContentURL, in: root),
                  let nextURL = TextProcessing.resolveURL(next, base: page.finalURL),
                  nextURL != url else { break }
            url = nextURL
        }

        var text = htmlChunks.map { TextProcessing.plainText(fromHTML: $0) }.joined(separator: "\n")
        text = applyContentRules(text, rule: source.content.replaceRegex)
        text = TextProcessing.cleanupChapterText(text)

        guard !text.isEmpty else {
            throw SourceError.emptyContent("章节正文为空")
        }
        if TextProcessing.isPlaceholderContent(text, chapterTitle: chapter.title) {
            throw SourceError.emptyContent("站点未返回正文（付费墙或占位内容），请换一个书源")
        }
        return ChapterContent(chapterURL: chapter.url, text: text)
    }

    // MARK: - Helpers

    private func fallbackContentHTML(from scope: RuleScope) -> String? {
        guard let root = scope.element else { return nil }
        let candidates = [
            "#content", "#chaptercontent", ".content", ".chapter-content", ".read-content",
            "#chapterContent", "#booktext", ".text", "article", ".article-content", "#htmlContent",
            ".showtxt", "#nr1", "#nr", ".yd_text2",
        ]
        for selector in candidates {
            if let element = try? root.select(selector).first(), let html = try? element.html(), !html.isEmpty {
                onWarning?("书源正文规则失效，已回退到 \(selector)")
                return html
            }
        }
        return nil
    }

    private func applyContentRules(_ text: String, rule: String) -> String {
        guard !rule.isEmpty else { return text }
        var result = text
        // `regex##replacement##regex2##replacement2`
        let parts = rule.components(separatedBy: "##")
        var index = 0
        while index + 1 < parts.count {
            let pattern = parts[index]
            let replacement = parts[index + 1]
            if !pattern.isEmpty {
                result = RegexHelper.replace(pattern, in: result, with: replacement)
            }
            index += 2
        }
        return result
    }

    private func makeEngine(variables: [String: String], baseURL: URL) -> RuleEngine {
        RuleEngine(variables: variables, onWarning: onWarning)
    }

    private func scope(for page: FetchedPage, source: BookSource) throws -> RuleScope {
        let trimmed = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return RuleScope(payload: .json(json), baseURL: page.finalURL)
            }
        }
        return .html(page.text, baseURL: page.finalURL)
    }

    private func interpolate(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Splits `url,{"method":"POST"}` into the URL and its options.
    private func splitURLOptions(_ raw: String) -> (String, [String: JSONValue]) {
        guard let range = raw.range(of: ",{", options: .backwards) else { return (raw, [:]) }
        let url = String(raw[..<range.lowerBound])
        let optionsText = String(raw[range.lowerBound...].dropFirst())
        // legado sources frequently use single-quoted keys/values, which strict
        // JSON rejects; normalise quotes when the strict parse fails.
        if let data = optionsText.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let options = value.objectValue {
            return (url, options)
        }
        let normalized = optionsText
            .replacingOccurrences(of: "'", with: "\"")
        if let data = normalized.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let options = value.objectValue {
            return (url, options)
        }
        return (raw, [:])
    }

    private func makeRequest(url: String, options: [String: JSONValue], source: BookSource, referer: String?, variables: [String: String] = [:]) throws -> HTTPRequest {
        guard !url.isEmpty else { throw SourceError.unsupported("书源「\(source.name)」规则生成的链接为空") }

        var headers = parseHeaders(source.header)
        if let extra = options["headers"]?.objectValue {
            for (key, value) in extra {
                if let text = value.stringValue { headers[key] = text }
            }
        }

        let method = (options["method"]?.stringValue ?? "GET").uppercased() == "POST" ? HTTPRequest.Method.post : .get
        var body: Data?
        if let bodyValue = options["body"]?.stringValue, !bodyValue.isEmpty {
            body = Data(interpolate(bodyValue, variables: variables).utf8)
        }
        if let charset = options["charset"]?.stringValue {
            headers["Content-Type"] = headers["Content-Type"] ?? "application/x-www-form-urlencoded; charset=\(charset)"
        }
        return HTTPRequest(url: url, method: method, headers: headers, body: body, charset: options["charset"]?.stringValue)
    }

    private func parseHeaders(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let object = value.objectValue {
            var headers: [String: String] = [:]
            for (key, item) in object {
                if let text = item.stringValue { headers[key] = text }
            }
            return headers
        }

        var headers: [String: String] = [:]
        for line in trimmed.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
}
