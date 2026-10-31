import XCTest
@testable import NovelKit

final class PlaceholderContentTests: XCTestCase {

    func testDetectsPaywallPlaceholder() {
        // Exactly what bqg6.xyz serves from chapter 7 onward.
        let text = """
        小说《剑来》的最新章节《第七百九十六章 不浩然》内容正在获取中，稍候重试。。。
        """
        XCTAssertTrue(TextProcessing.isPlaceholderContent(text, chapterTitle: "第七百九十六章 不浩然"))
    }

    func testDetectsShortJunk() {
        XCTAssertTrue(TextProcessing.isPlaceholderContent("正在手打中，请稍候"))
        XCTAssertTrue(TextProcessing.isPlaceholderContent("   "))
    }

    func testAcceptsRealProse() {
        let body = String(repeating: "陈平安抬头看了看天，雨落在青石板上，溅起一层薄薄的白雾。\n", count: 30)
        XCTAssertFalse(TextProcessing.isPlaceholderContent(body, chapterTitle: "第一百章 雨夜"))
    }

    func testAcceptsLongProseMentioningPlaceholderOnce() {
        // The phrase can legitimately appear inside dialogue; only a short or
        // dominated page should be rejected.
        let prose = String(repeating: "他笑着说这句话的时候，屋里没有人接茬，只有风把窗纸吹得哗哗响。\n", count: 60)
        let text = prose + "\u{201C}内容正在获取中。\u{201D}\n" + prose
        XCTAssertFalse(TextProcessing.isPlaceholderContent(text))
    }
}
