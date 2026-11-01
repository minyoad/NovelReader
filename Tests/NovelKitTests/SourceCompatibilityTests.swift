import XCTest
@testable import NovelKit

/// The source library is full of legado sources whose rules call into
/// JavaScript, which this engine does not run. The question the app has to
/// answer is not "does this source use JS" — a quarter of them do — but "will
/// this source still read", because the two failures need completely different
/// advice: a degraded source is fine to use, an unreadable one is not.
final class SourceCompatibilityTests: XCTestCase {

    private func source(
        searchBookList: String = "class.list@li",
        searchName: String = "a@text",
        searchBookURL: String = "a@href",
        tocChapterList: String = "class.list@li",
        content: String = "#content@html",
        tocURL: String = "",
        intro: String = "",
        cover: String = ""
    ) -> BookSource {
        var source = BookSource(name: "测试源", baseURL: "https://example.com")
        source.search.bookList = searchBookList
        source.search.name = searchName
        source.search.bookURL = searchBookURL
        source.search.coverURL = cover
        source.toc.chapterList = tocChapterList
        source.content.content = content
        source.bookInfo.tocURL = tocURL
        source.bookInfo.intro = intro
        return source
    }

    // MARK: - Clean sources

    func testSourceWithoutJavaScriptIsSupported() {
        let compatibility = source().compatibility
        XCTAssertEqual(compatibility.level, .supported)
        XCTAssertFalse(compatibility.hasJavaScript)
        XCTAssertTrue(compatibility.roles.isEmpty)
        XCTAssertTrue(compatibility.blockingRoles.isEmpty)
    }

    func testPlainRulesAreNotMistakenForJavaScript() {
        // `<js>` inside a regex replacement is not a JS rule; only the markers
        // legado actually uses start one.
        var source = self.source()
        source.content.replaceRegex = "<js>广告@@"
        XCTAssertEqual(source.compatibility.level, .supported)
    }

    // MARK: - Degraded: JS is skipped, but something still works

    func testJavaScriptAfterASelectorKeepsTheSourceReadable() {
        // `article@html@js:...` still selects `article` and takes its html; only
        // the post-processing is lost. The engine then falls back to guessing a
        // body element, so the book reads.
        let source = self.source(content: "article@html@js:java.t2s(result)")
        let compatibility = source.compatibility
        XCTAssertEqual(compatibility.level, .degraded)
        XCTAssertEqual(compatibility.roles, ["正文"])
        XCTAssertTrue(compatibility.blockingRoles.isEmpty)
    }

    func testJavaScriptOnlyTOCURLOnlyCostsTheTOCShortcut() {
        // A missing TOC URL falls back to the detail page, which is what many
        // sites need anyway.
        let compatibility = self.source(tocURL: "<js> var id = 1; '/read/' + id; </js>").compatibility
        XCTAssertEqual(compatibility.level, .degraded)
        XCTAssertEqual(compatibility.roles, ["目录地址"])
        XCTAssertTrue(compatibility.blockingRoles.isEmpty)
    }

    func testCosmeticJavaScriptDoesNotBlockReading() {
        let compatibility = self.source(
            intro: "class.intro@text<js> result.replace(/^/, '    ') </js>",
            cover: "<js> 'https://example.com/nocover.jpg' </js>"
        ).compatibility
        XCTAssertEqual(compatibility.level, .degraded)
        XCTAssertEqual(Set(compatibility.roles), ["简介", "封面"])
        XCTAssertTrue(compatibility.blockingRoles.isEmpty)
    }

    // MARK: - Unreadable: a rule the reader cannot do without is JS-only

    func testJavaScriptOnlyChapterListMakesTheSourceUnreadable() {
        // No selector is left, so there is not one chapter to open. This is the
        // case that used to surface as "书源规则可能已失效" after a search had
        // already found the book.
        let source = self.source(tocChapterList: """
        <js>
        base = baseUrl;
        lis = java.getElements('#list-chapterAll@dd');
        lis;
        </js>
        """)
        let compatibility = source.compatibility
        XCTAssertEqual(compatibility.level, .unreadable)
        XCTAssertEqual(compatibility.blockingRoles, ["目录"])
    }

    func testBareAppendMarkerIsNotASelector() {
        // legado's `+` means "append to the previous value". On its own it
        // selects nothing, so a `+<js>...` chapter list is JS-only too.
        let compatibility = self.source(tocChapterList: "+<js> var a; a = 1; </js>").compatibility
        XCTAssertEqual(compatibility.level, .unreadable)
        XCTAssertEqual(compatibility.blockingRoles, ["目录"])
    }

    func testJavaScriptOnlySearchListMakesTheSourceUnreadable() {
        // Nothing matches, so the source never produces a result to tap.
        let compatibility = self.source(searchBookList: "<js> return getElements(); </js>").compatibility
        XCTAssertEqual(compatibility.level, .unreadable)
        XCTAssertEqual(compatibility.blockingRoles, ["搜索列表"])
    }

    func testUnreadableWinsOverDegraded() {
        // One blocking failure is enough, and the level must say so even when
        // other rules are merely degraded.
        let source = self.source(tocChapterList: "<js> 1 </js>", content: "article@html@js:x")
        let compatibility = source.compatibility
        XCTAssertEqual(compatibility.level, .unreadable)
        XCTAssertEqual(compatibility.blockingRoles, ["目录"])
        XCTAssertTrue(compatibility.roles.contains("正文"))
    }

    // MARK: - What the JavaScript would need

    func testDetectsDOMPandNetworkDependencies() {
        let dom = self.source(content: "@js: org.jsoup.Jsoup.parse(result).text()").compatibility
        XCTAssertTrue(dom.usesDOM)
        XCTAssertFalse(dom.usesNetwork)

        let network = self.source(content: "@js: java.ajax(baseUrl)").compatibility
        XCTAssertFalse(network.usesDOM)
        XCTAssertTrue(network.usesNetwork)

        let state = self.source(content: "@js: java.put('id', 1)").compatibility
        XCTAssertTrue(state.usesNetwork)

        let plain = self.source(content: "article@html@js: java.t2s(result)").compatibility
        XCTAssertFalse(plain.usesDOM)
        XCTAssertFalse(plain.usesNetwork)
    }

    // MARK: - Ordering

    func testLevelsOrderFromUsableToBroken() {
        // `max` is how a collection is summarised, so the raw values have to
        // rank in the direction of "worse".
        XCTAssertLessThan(SourceCompatibility.Level.supported, .degraded)
        XCTAssertLessThan(SourceCompatibility.Level.degraded, .unreadable)
    }

    // MARK: - The raw JSON is not evidence

    func testOriginalJSONIsIgnored() {
        // Every legado source carries `<js>` somewhere in its comment/metadata
        // fields; treating the blob as evidence would flag the whole library.
        var source = self.source()
        source.originalJSON = """
        {"bookSourceName":"测试源","ruleContent":{"content":"#content@html"},
         "ruleToc":{"chapterList":"<js>org.jsoup.Jsoup.parse(result)</js>"},
         "bookSourceComment":"需要 js"}
        """
        XCTAssertEqual(source.compatibility.level, .supported)
    }
}
