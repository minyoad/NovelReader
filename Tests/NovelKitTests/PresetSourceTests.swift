import XCTest
@testable import NovelKit

/// Regression tests for the bundled preset sources, using captured pages so
/// they run without network access.
///
/// These pin down the legado features the presets rely on — `!0` header
/// exclusion, `class.odd.1` per-row indexes, multi-paragraph bodies — which is
/// where the engine previously broke on real sources.
final class PresetSourceTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
                                "缺少测试样例 \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func scope(_ name: String, base: String = "https://www.deqitxt.com") throws -> RuleScope {
        RuleScope.html(try fixture(name), baseURL: URL(string: base)!)
    }

    private func deqi() throws -> BookSource {
        try XCTUnwrap(BuiltinContent.presetSources.first { $0.name == "得奇小说网" })
    }

    // MARK: - 得奇小说网 (deqitxt)

    func testDeqiSearch() throws {
        let source = try deqi()
        let engine = RuleEngine(variables: ["key": "剑来"])
        let items = engine.scopes(for: source.search.bookList, in: try scope("deqi-search.html"))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(engine.value(source.search.name, in: items[0]), "剑来")
        XCTAssertEqual(engine.value(source.search.author, in: items[0]), "烽火戏诸侯")
        XCTAssertEqual(engine.value(source.search.bookURL, in: items[0]), "https://www.deqitxt.com/75/")
    }

    func testDeqiDetailAndToc() throws {
        let source = try deqi()
        let engine = RuleEngine(variables: ["key": "剑来"])
        let detail = try scope("deqi-detail.html")

        XCTAssertEqual(engine.value(source.bookInfo.name, in: detail), "剑来")
        XCTAssertEqual(engine.value(source.bookInfo.author, in: detail), "烽火戏诸侯")
        XCTAssertTrue((engine.value(source.bookInfo.intro, in: detail) ?? "").contains("陈平安"))

        // The whole book is one page: every `<li><a>` under `#list` is a chapter.
        let chapters = engine.scopes(for: source.toc.chapterList, in: detail)
        XCTAssertEqual(chapters.count, 1302)
        XCTAssertEqual(engine.value(source.toc.chapterName, in: chapters[0]), "新书感言")
        XCTAssertEqual(engine.value(source.toc.chapterURL, in: chapters[0]), "https://www.deqitxt.com/75/85628.html")
        XCTAssertEqual(engine.value(source.toc.chapterName, in: chapters.last!), "第76章 灯谜")
    }

    func testDeqiBodyIsRealProse() throws {
        let source = try deqi()
        let engine = RuleEngine(variables: ["key": "剑来"])
        let html = engine.value(source.content.content, in: try scope("deqi-chapter.html")) ?? ""
        let text = TextProcessing.plainText(fromHTML: html)

        XCTAssertTrue(text.contains("仙侠世界"))
        XCTAssertFalse(TextProcessing.isPlaceholderContent(text))
    }

    /// A mid-book chapter: this is exactly where b5200/bqg6 returned
    /// "内容正在获取中，稍候重试" instead of prose. Long chapters are split into
    /// pages, so the body rule returns every `<p>` on the current page and the
    /// engine follows `nextContentUrl` to stitch the rest.
    func testDeqiDeepChapterIsRealProse() throws {
        let source = try deqi()
        let engine = RuleEngine(variables: ["key": "剑来"])
        let page1 = engine.values(source.content.content, in: try scope("deqi-chapter-mid.html")).joined(separator: "\n")
        let page2 = engine.values(source.content.content, in: try scope("deqi-chapter-mid-p2.html")).joined(separator: "\n")
        let text = TextProcessing.cleanupChapterText(
            TextProcessing.plainText(fromHTML: page1) + "\n" + TextProcessing.plainText(fromHTML: page2)
        )

        XCTAssertGreaterThan(text.count, 3000)
        XCTAssertTrue(text.contains("陈平安") || text.contains("宁姚") || text.contains("青冥天下"))
        XCTAssertFalse(TextProcessing.isPlaceholderContent(text, chapterTitle: "第六百九十九章 天下第一人"))
    }

    // MARK: - Preset bundle

    func testBuiltinPresetsAreUsable() {
        let presets = BuiltinContent.presetSources
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets.map(\.name), ["得奇小说网", "顶点小说 23uswx"])
        // Stable IDs keep library / bookmark references valid across launches.
        XCTAssertEqual(presets.map(\.id), BuiltinContent.presetSources.map(\.id))

        for preset in presets {
            XCTAssertTrue(preset.enabled, "\(preset.name) 预置后应默认启用")
            XCTAssertTrue(preset.canSearch, "\(preset.name) 应有搜索规则")
            XCTAssertFalse(preset.search.bookList.isEmpty, "\(preset.name) 缺少搜索结果列表规则")
            XCTAssertFalse(preset.toc.chapterList.isEmpty, "\(preset.name) 缺少目录规则")
            XCTAssertFalse(preset.content.content.isEmpty, "\(preset.name) 缺少正文规则")
            XCTAssertNotNil(preset.originalJSON, "\(preset.name) 应保留原始 JSON 以便导出")
        }
    }

    /// The presets must not depend on JS rules, which this engine cannot run.
    func testPresetsAvoidJSRules() {
        for preset in BuiltinContent.presetSources {
            let rules = [
                preset.searchURL, preset.search.bookList, preset.search.name, preset.search.bookURL,
                preset.bookInfo.name, preset.bookInfo.intro, preset.bookInfo.tocURL,
                preset.toc.chapterList, preset.toc.chapterName, preset.toc.chapterURL,
                preset.content.content, preset.content.nextContentURL,
            ]
            for rule in rules where !rule.isEmpty {
                XCTAssertFalse(rule.contains("@js:"), "\(preset.name) 含 JS 规则：\(rule)")
                XCTAssertFalse(rule.contains("<js>"), "\(preset.name) 含 JS 规则：\(rule)")
            }
        }
    }

    func testPresetIDsAreRecognisable() {
        for preset in BuiltinContent.presetSources {
            XCTAssertTrue(BuiltinContent.isPresetID(preset.id), "\(preset.name) 的 ID 应能被识别为预置")
        }
        XCTAssertFalse(BuiltinContent.isPresetID(UUID()), "随机 UUID 不应被当成预置")
    }
}
