import XCTest
@testable import NovelKit

final class RuleEngineTests: XCTestCase {
    private let html = """
    <html><body>
      <div class="book-list">
        <li><a href="/book/1.html"><img src="/c/1.jpg"><span class="name">盘龙</span></a>
            <span class="author">我吃西红柿</span><span class="kind">玄幻</span></li>
        <li><a href="/book/2.html"><img src="/c/2.jpg"><span class="name">斗破苍穹</span></a>
            <span class="author">天蚕土豆</span><span class="kind">玄幻</span></li>
      </div>
      <div id="content"><p>第一段。</p><p>第二段。</p><br>第三段。</div>
    </body></html>
    """

    private var scope: RuleScope {
        RuleScope.html(html, baseURL: URL(string: "https://example.com/search?q=x")!)
    }

    func testLegadoPathListAndFields() {
        let engine = RuleEngine()
        let items = engine.scopes(for: "class.book-list@tag.li", in: scope)
        XCTAssertEqual(items.count, 2)

        XCTAssertEqual(engine.value("class.name", in: items[0]), "盘龙")
        XCTAssertEqual(engine.value("class.author@text", in: items[1]), "天蚕土豆")
        XCTAssertEqual(engine.value("tag.a@href", in: items[0]), "https://example.com/book/1.html")
    }

    func testCSSPrefixedRules() {
        let engine = RuleEngine()
        let items = engine.scopes(for: "@css:.book-list li", in: scope)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(engine.value("@css:a@href", in: items[1]), "https://example.com/book/2.html")
        XCTAssertEqual(engine.value("@css:img@src", in: items[0]), "https://example.com/c/1.jpg")
    }

    func testFallbackChain() {
        let engine = RuleEngine()
        XCTAssertEqual(engine.value("class.missing@@class.author", in: scope), "我吃西红柿")
    }

    func testRegexPostProcessing() {
        let engine = RuleEngine()
        XCTAssertEqual(engine.value("class.name##龙##龙（完）", in: scope), "盘龙（完）")
    }

    func testContentRuleProducesParagraphs() {
        let engine = RuleEngine()
        let html = engine.value("id.content@html", in: scope) ?? ""
        let text = TextProcessing.plainText(fromHTML: html)
        XCTAssertEqual(text, "第一段。\n第二段。\n第三段。")
    }

    func testXPathConversion() {
        let engine = RuleEngine()
        let items = engine.scopes(for: "@XPath://div[@class='book-list']//li", in: scope)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(engine.value("@XPath://div[@class='book-list']//span[@class='name']/text()", in: scope), "盘龙")
        XCTAssertEqual(engine.value("@XPath://div[@class='book-list']//a/@href", in: scope), "https://example.com/book/1.html")
    }

    func testJSONRules() throws {
        let json = """
        {"data":{"list":[
          {"name":"书一","author":"作者甲","url":"/b/1"},
          {"name":"书二","author":"作者乙","url":"/b/2"}
        ]}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let root = RuleScope(payload: .json(value), baseURL: URL(string: "https://example.com"))

        let engine = RuleEngine()
        let items = engine.scopes(for: "$.data.list[*]", in: root)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(engine.value("$.name", in: items[0]), "书一")
        XCTAssertEqual(engine.value("@json:$.author", in: items[1]), "作者乙")
        XCTAssertEqual(engine.value("$.data.list[0].name", in: root), "书一")
    }

    func testRecursiveDescent() throws {
        let json = #"{"a":{"b":{"name":"深"}},"c":[{"name":"浅"}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let strings = JSONPath.strings("$..name", on: value)
        XCTAssertEqual(Set(strings), Set(["深", "浅"]))
    }

    func testUnsupportedJSRuleWarns() {
        var warnings: [String] = []
        let engine = RuleEngine(onWarning: { warnings.append($0) })
        XCTAssertNil(engine.value("@js:result", in: scope))
        XCTAssertEqual(warnings.count, 1)
    }

    func testVariableInterpolation() {
        let engine = RuleEngine(variables: ["key": "盘龙"])
        XCTAssertEqual(engine.value(":盘龙", in: scope), "盘龙")
        XCTAssertEqual(engine.value("class.none@@:斗破", in: scope), "斗破")
    }

    // MARK: - legado path details

    /// `tr` headers are dropped with `!0`; the suffix is an exclusion list, not
    /// a "keep only these" list (b5200 relies on this to skip 9 header rows).
    func testSliceSuffixExcludesIndexes() {
        let html = """
        <ul class="list">
          <li>表头</li><li>一</li><li>二</li><li>三</li><li>四</li>
        </ul>
        """
        let scope = RuleScope.html(html, baseURL: nil)
        let engine = RuleEngine()

        XCTAssertEqual(engine.scopes(for: "class.list@tag.li!0", in: scope).map(\.plainText), ["一", "二", "三", "四"])
        XCTAssertEqual(engine.scopes(for: "class.list@tag.li!0:1:2", in: scope).map(\.plainText), ["三", "四"])
        XCTAssertEqual(engine.scopes(for: "class.list@tag.li!-1", in: scope).map(\.plainText), ["表头", "一", "二", "三"])
        XCTAssertEqual(engine.scopes(for: "class.list@tag.li!0", in: scope).count, 4)
    }

    /// `td.0` / `tag.a.1` pick the nth match *per parent*, which is how legado
    /// reads table rows.
    func testIndexedPathSegments() {
        let html = """
        <table>
          <tr><td class="odd"><a href="/1">书一</a></td><td class="odd">作者甲</td></tr>
          <tr><td class="odd"><a href="/2">书二</a></td><td class="odd">作者乙</td></tr>
        </table>
        """
        let scope = RuleScope.html(html, baseURL: URL(string: "https://example.com/")!)
        let engine = RuleEngine()

        let rows = engine.scopes(for: "tag.tr", in: scope)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(engine.value("class.odd.0@tag.a.0@text", in: rows[0]), "书一")
        XCTAssertEqual(engine.value("class.odd.1@text", in: rows[0]), "作者甲")
        XCTAssertEqual(engine.value("class.odd.1@text", in: rows[1]), "作者乙")
        XCTAssertEqual(engine.value("class.odd.0@tag.a.0@href", in: rows[1]), "https://example.com/2")
        // Out-of-range indexes yield nothing instead of leaking the last match.
        XCTAssertNil(engine.value("class.odd.5@text", in: rows[0]))
    }

    func testLimitFilter() {
        let html = """
        <ul><li>a</li><li>b</li><li>c</li><li>d</li></ul>
        """
        let scope = RuleScope.html(html, baseURL: nil)
        let engine = RuleEngine()
        XCTAssertEqual(engine.scopes(for: "tag.li:lt(2)", in: scope).map(\.plainText), ["a", "b"])
    }

    /// `||` falls back, `&&` concatenates — both appear in real sources.
    func testAlternativeAndConcatOperators() {
        let engine = RuleEngine()
        XCTAssertEqual(engine.value("class.missing||class.author", in: scope), "我吃西红柿")
        XCTAssertEqual(engine.value("class.kind&&class.author", in: scope), "玄幻我吃西红柿")
    }

    /// `rule##regex` without a replacement strips matches.
    func testRegexPostProcessingWithoutReplacement() {
        let engine = RuleEngine()
        XCTAssertEqual(engine.value("class.name##龙", in: scope), "盘")
    }

    func testTextNodesExtraction() {
        let html = "<div class=\"intro\">正文<span>注</span>续</div>"
        let scope = RuleScope.html(html, baseURL: nil)
        let engine = RuleEngine()
        let value = engine.value("class.intro@textNodes", in: scope) ?? ""
        XCTAssertTrue(value.contains("正文"))
        XCTAssertTrue(value.contains("续"))
    }

    /// Every paragraph of a body rule is kept; taking only the first silently
    /// truncated chapters from sources like b5200 (`id.content@tag.p@text`).
    func testMultipleParagraphsAreAllReturned() {
        let engine = RuleEngine()
        let values = engine.values("id.content@tag.p@text", in: scope)
        XCTAssertEqual(values, ["第一段。", "第二段。"])
        // Text outside the paragraphs is why `@html` + plain-text conversion is
        // preferred for body rules.
        let html = engine.value("id.content@html", in: scope) ?? ""
        XCTAssertEqual(TextProcessing.plainText(fromHTML: html), "第一段。\n第二段。\n第三段。")
    }

    func testPresetSourcesImport() {
        let sources = BuiltinContent.presetSources
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(Set(sources.map(\.name)).count, 2)
        for source in sources {
            XCTAssertTrue(source.canSearch, "\(source.name) 应有搜索规则")
            XCTAssertFalse(source.toc.chapterList.isEmpty, "\(source.name) 应有目录规则")
            XCTAssertFalse(source.content.content.isEmpty, "\(source.name) 应有正文规则")
            XCTAssertEqual(source.originalJSON != nil, true, "\(source.name) 应保留原始 JSON")
        }
        // Stable IDs so library entries survive relaunches.
        XCTAssertEqual(sources.map(\.id), BuiltinContent.presetSources.map(\.id))
    }
}
