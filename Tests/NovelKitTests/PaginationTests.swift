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

    @Test("only paragraph starts are reported as such")
    func startsParagraph() {
        let paginated = PaginatedText(rawText: raw)
        // Body is: 这是第一段，有一些内容。\n这是第二段，也有内容。\n这是第四段。
        #expect(paginated.body == "这是第一段，有一些内容。\n这是第二段，也有内容。\n这是第四段。")

        // Page top: a real paragraph start, keeps the indent.
        #expect(paginated.startsParagraph(atBody: 0))

        // Mid-paragraph: pages cut here must drop the indent.
        #expect(!paginated.startsParagraph(atBody: 1))
        #expect(!paginated.startsParagraph(atBody: 5))

        // Right after the separator is the next paragraph's first character.
        let second = paginated.bodyOffset(forOriginal: paginated.paragraphs[1].originalStart)
        #expect(second == paginated.paragraphs[0].text.count + 1)
        #expect(paginated.startsParagraph(atBody: second))

        let third = paginated.bodyOffset(forOriginal: paginated.paragraphs[2].originalStart)
        #expect(paginated.startsParagraph(atBody: third))
    }

    @Test("startsParagraph survives emoji before the cut")
    func startsParagraphWithEmoji() {
        // Two UTF-16 units per emoji: the check must read characters, not
        // UTF-16 units, or an offset inside a surrogate pair would misfire.
        let paginated = PaginatedText(rawText: "😀😀第一段\n第二段")
        let body = paginated.body
        #expect(body == "😀😀第一段\n第二段")
        #expect(paginated.startsParagraph(atBody: 0))
        #expect(!paginated.startsParagraph(atBody: 1))
        #expect(!paginated.startsParagraph(atBody: 2))

        // The cut the layout actually reports is a UTF-16 offset; mid-emoji it
        // must round back to the emoji's own character, never to the newline.
        let secondParagraph = body.firstIndex(of: "\n").map { body.distance(from: body.startIndex, to: $0) + 1 } ?? 0
        #expect(paginated.startsParagraph(atBody: secondParagraph))
        let firstParagraphEndUTF16 = paginated.utf16Offset(forBodyCharacter: secondParagraph - 1)
        #expect(paginated.startsParagraph(atBody: paginated.bodyCharacterOffset(forUTF16: firstParagraphEndUTF16 + 1)))
    }
}
