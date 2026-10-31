import XCTest
@testable import NovelKit

final class PipelineTests: XCTestCase {

    // MARK: - Legado import

    private let sourceJSON = """
    [
      {
        "bookSourceName": "测试源",
        "bookSourceUrl": "https://novel.example.com/",
        "bookSourceGroup": "测试",
        "searchUrl": "/search?q={{key}}",
        "ruleSearch": {
          "bookList": "@css:.result li",
          "name": "@css:.title@text",
          "author": "@css:.author@text",
          "bookUrl": "@css:a@href"
        },
        "ruleToc": {
          "chapterList": "@css:#list dd",
          "chapterName": "@css:a@text",
          "chapterUrl": "@css:a@href"
        },
        "ruleContent": {
          "content": "@css:#content@html",
          "replaceRegex": "广告.*?##"
        }
      },
      {
        "bookSourceName": "没有地址的源",
        "ruleSearch": { "bookList": ".x" }
      },
      {
        "bookSourceName": "JS 源",
        "bookSourceUrl": "https://js.example.com",
        "searchUrl": "/s?q={{key}}",
        "ruleSearch": {
          "bookList": "@css:.list li",
          "name": "@js:result.name"
        }
      }
    ]
    """

    func testImportMapsLegadoFields() throws {
        let result = try LegadoImporter.importSources(fromJSON: sourceJSON)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(result.warnings.count, 1, "缺少站点地址的源应被跳过并提示")

        let source = try XCTUnwrap(result.sources.first { $0.name == "测试源" })
        XCTAssertEqual(source.baseURL, "https://novel.example.com")
        XCTAssertEqual(source.group, "测试")
        XCTAssertEqual(source.search.bookList, "@css:.result li")
        XCTAssertEqual(source.content.replaceRegex, "广告.*?##")
        XCTAssertEqual(source.toc.chapterName, "@css:a@text")
        XCTAssertNotNil(source.originalJSON)
        XCTAssertTrue(source.canSearch)
    }

    func testImporterFillsChapterDefaults() throws {
        let json = """
        [{"bookSourceName":"默认值","bookSourceUrl":"https://a.example.com",
          "ruleToc":{"chapterList":"@css:#list a"}}]
        """
        let result = try LegadoImporter.importSources(fromJSON: json)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.toc.chapterName, "@text")
        XCTAssertEqual(source.toc.chapterURL, "@href")
    }

    func testImportRejectsGarbage() {
        XCTAssertThrowsError(try LegadoImporter.importSources(fromJSON: "\"just a string\""))
    }

    // MARK: - Text processing

    func testCleanupDropsSiteBoilerplate() {
        let raw = """
        第一章 起点

        这是一段正常的小说正文，主角推开了门。

        本章未完，请点击下一页继续阅读

        本站域名 www.example-novel.com
        于是他又走了出去，雨还在下。
        """

        let cleaned = TextProcessing.cleanupChapterText(raw)
        XCTAssertTrue(cleaned.contains("主角推开了门"))
        XCTAssertTrue(cleaned.contains("雨还在下"))
        XCTAssertFalse(cleaned.contains("本章未完"))
        XCTAssertFalse(cleaned.contains("www.example-novel.com"))
    }

    func testCleanupDeduplicatesParagraphs() {
        let raw = "重复的一段。\n重复的一段。\n新的段落。"
        XCTAssertEqual(TextProcessing.cleanupChapterText(raw), "重复的一段。\n新的段落。")
    }

    func testSentencesSplitOnChinesePunctuation() {
        let sentences = TextProcessing.sentences(from: "第一句。第二句！第三句？\n换段了。")
        XCTAssertEqual(sentences, ["第一句。", "第二句！", "第三句？", "换段了。"])
    }

    func testLongSentenceIsSplit() {
        let long = String(repeating: "字", count: 130) + "。"
        let sentences = TextProcessing.sentences(from: long, maxLength: 60)
        XCTAssertGreaterThan(sentences.count, 1)
        XCTAssertTrue(sentences.allSatisfy { $0.count <= 61 })
    }

    func testHTMLParagraphsBecomeLines() {
        let html = "<div><p>一</p><p>二</p><br>三</div>"
        XCTAssertEqual(TextProcessing.plainText(fromHTML: html), "一\n二\n三")
    }

    func testEntitiesDecoded() {
        XCTAssertEqual(TextProcessing.unescapeEntities("&lt;书&gt;&nbsp;&#20320;"), "<书> 你")
    }

    // MARK: - AI helpers

    func testChunkingKeepsEverythingUnderLimit() {
        let paragraphs = (1...40).map { "第\($0)段。" + String(repeating: "内容", count: 30) }
        let chunks = AIPrompt.chunk(paragraphs.joined(separator: "\n"), maxLength: 600)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 600 })
        XCTAssertEqual(chunks.joined(separator: "\n").replacingOccurrences(of: "\n", with: ""),
                       paragraphs.joined(separator: ""))
    }

    func testCleanReplyStripsCodeFenceAndPreamble() {
        let reply = """
        ```text
        以下是整理后的正文：
        正文第一段。

        正文第二段。
        ```
        """
        let cleaned = AIPrompt.cleanReply(reply)
        XCTAssertEqual(cleaned, "正文第一段。\n\n正文第二段。")
    }

    func testAIConfigurationBuildsEndpoint() {
        var configuration = AIConfiguration(preset: .deepseek, apiKey: "sk-test")
        configuration.enabled = true
        XCTAssertEqual(configuration.chatCompletionsURL?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertTrue(configuration.isUsable)

        configuration.baseURL = "https://proxy.example.com/v1/chat/completions"
        XCTAssertEqual(configuration.chatCompletionsURL?.absoluteString, "https://proxy.example.com/v1/chat/completions")

        configuration.apiKey = ""
        XCTAssertFalse(configuration.isUsable, "需要 key 的服务不应被认为可用")
    }

    // MARK: - Storage

    func testStoreRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelReadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LibraryStore(directory: directory)
        let book = BuiltinContent.sampleBook
        let chapters = BuiltinContent.sampleChapters

        await store.saveBooks([book])
        let loadedBooks = await store.loadBooks()
        XCTAssertEqual(loadedBooks.map(\.id), [book.id])
        XCTAssertEqual(loadedBooks.first?.name, "长夜灯下")

        await store.saveChapters(chapters, bookID: book.id)
        let loadedChapters = await store.loadChapters(bookID: book.id)
        XCTAssertEqual(loadedChapters?.count, chapters.count)

        let content = ChapterContent(chapterURL: chapters[0].url, text: "正文")
        await store.saveContent(content, bookID: book.id)
        let loadedContent = await store.loadContent(bookID: book.id, chapterURL: chapters[0].url)
        XCTAssertEqual(loadedContent?.text, "正文")

        let count = await store.cachedChapterCount(bookID: book.id)
        XCTAssertEqual(count, 1)

        await store.clearChapterCache(bookID: book.id)
        let cleared = await store.loadContent(bookID: book.id, chapterURL: chapters[0].url)
        XCTAssertNil(cleared)
    }

    func testStableHashIsDeterministic() {
        let first = StableHash.hex("https://example.com/chapter/1")
        let second = StableHash.hex("https://example.com/chapter/1")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, StableHash.hex("https://example.com/chapter/2"))
    }

    func testBootstrapFlagsPersist() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let store = LibraryStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var flagged = await store.isFlagSet("presetSourcesSeeded")
        XCTAssertFalse(flagged)

        await store.setFlag("presetSourcesSeeded")
        flagged = await store.isFlagSet("presetSourcesSeeded")
        XCTAssertTrue(flagged)

        // Settings live in a separate file, so resetting them must not re-seed.
        await store.saveSettings(AppSettings())
        let stillFlagged = await store.isFlagSet("presetSourcesSeeded")
        XCTAssertTrue(stillFlagged)

        // A fresh store in the same directory keeps the flag.
        let reopened = LibraryStore(directory: dir)
        let persisted = await reopened.isFlagSet("presetSourcesSeeded")
        XCTAssertTrue(persisted)
    }

    /// Upgrading must swap the preset generation without touching user sources.
    func testPresetMigrationReplacesStalePresets() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let store = LibraryStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate an install that ran the previous build: seeded flag is set,
        // the preset version flag is not, and a dead b5200 preset is on disk.
        await store.setFlag("presetSourcesSeeded")
        let mine = BookSource(name: "我导入的源", baseURL: "https://example.org", enabled: true)
        var stale = BuiltinContent.presetSources[0]
        stale.id = UUID(uuidString: "B5200000-0000-4000-8000-000000000009")!
        stale.name = "笔趣阁 b5200"
        await store.saveSources([BuiltinContent.sampleSource, mine, stale])

        XCTAssertTrue(BuiltinContent.isPresetID(stale.id))
        let versionFlagSet = await store.isFlagSet(BuiltinContent.presetVersionFlag)
        XCTAssertFalse(versionFlagSet, "旧版本装机不应带新版本标记")
    }
}
