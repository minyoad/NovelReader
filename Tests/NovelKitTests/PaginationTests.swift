import Testing
import Foundation
@testable import NovelKit

@Suite("Pagination offset mapping")
struct PaginationTests {

    private let raw = """
      　　这是第一段，有一些内容。
    　　这是第二段，也有内容。

    　　这是第四段。

    """

    @Test("paragraphs drop blank lines and keep original starts")
    func paragraphs() {
        let paginated = PaginatedText(rawText: raw)
        #expect(paginated.paragraphs.count == 3)
        #expect(paginated.paragraphs[0].text == "这是第一段，有一些内容。")
        #expect(paginated.paragraphs[1].text == "这是第二段，也有内容。")
        #expect(paginated.paragraphs[2].text == "这是第四段。")

        // Each recorded start must actually point at the trimmed text.
        let ns = raw as NSString
        for paragraph in paginated.paragraphs {
            let slice = ns.substring(from: paragraph.originalStart)
            #expect(slice.hasPrefix(paragraph.text), "start \(paragraph.originalStart) does not match")
        }
    }

    @Test("body joins paragraphs with single newlines")
    func body() {
        let paginated = PaginatedText(rawText: raw)
        #expect(paginated.body == "这是第一段，有一些内容。\n这是第二段，也有内容。\n这是第四段。")
    }

    @Test("offset mapping round-trips inside paragraphs")
    func roundTrip() {
        let paginated = PaginatedText(rawText: raw)
        for original in 0...raw.count {
            let body = paginated.bodyOffset(forOriginal: original)
            #expect(body >= 0)
            #expect(body <= paginated.body.count)
        }
        for paragraph in paginated.paragraphs {
            for local in 0...paragraph.text.count {
                let original = paragraph.originalStart + local
                let bodyOffset = paginated.bodyOffset(forOriginal: original)
                #expect(paginated.originalOffset(forBody: bodyOffset) == original)
            }
        }
    }

    @Test("offsets clamp instead of trapping on stale progress")
    func clamping() {
        let paginated = PaginatedText(rawText: raw)
        #expect(paginated.bodyOffset(forOriginal: -50) == 0)
        #expect(paginated.bodyOffset(forOriginal: 99_999) == paginated.body.count)
        #expect(paginated.originalOffset(forBody: -10) == paginated.paragraphs[0].originalStart)
        #expect(paginated.originalOffset(forBody: 99_999) == paginated.paragraphs.last!.originalStart + paginated.paragraphs.last!.text.count)
    }

    @Test("UTF-16 offsets stay on grapheme boundaries")
    func utf16() {
        let text = PaginatedText(rawText: "😀表情符号和汉字混排。\n第二段。")
        for offset in 0...text.body.count {
            let utf16 = text.utf16Offset(forBodyCharacter: offset)
            let back = text.bodyCharacterOffset(forUTF16: utf16)
            #expect(back == offset)
        }
        // A UTF-16 offset in the middle of an emoji must round down safely.
        let insideEmoji = text.bodyCharacterOffset(forUTF16: 1)
        #expect(insideEmoji == 0)
    }

    @Test("empty text is handled")
    func empty() {
        let paginated = PaginatedText(rawText: "\n\n   \n")
        #expect(paginated.paragraphs.isEmpty)
        #expect(paginated.body.isEmpty)
        #expect(paginated.bodyOffset(forOriginal: 5) == 0)
        #expect(paginated.originalOffset(forBody: 5) == 0)
    }
}
