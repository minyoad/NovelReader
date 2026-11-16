#if canImport(UIKit)
import Testing
import UIKit
import NovelKit
@testable import NovelReader

@Suite("Background reader pagination")
@MainActor
struct PageLayoutTests {
    @Test("Pages preserve Unicode text and paragraph starts across a long chapter")
    func unicodeCoverage() async {
        let raw = Array(repeating: "　　😀长段落中的文字。" + String(repeating: "继续阅读。", count: 40), count: 30)
            .joined(separator: "\n\n")
        let document = PagedDocument.make(
            content: ChapterContent(chapterURL: "local://long", text: raw),
            reading: ReadingSettings(), theme: .of(.paper)
        )
        let pages = await PageLayout.prepare(document: document, in: CGSize(width: 300, height: 500))
        #expect(pages.count > 1)
        let body = document.attributed.string as NSString
        var pieces: [String] = []
        var previousEnd = 0
        for page in pages {
            #expect(page.range.location >= previousEnd)
            #expect(NSMaxRange(page.range) <= body.length)
            let skipped = body.substring(with: NSRange(
                location: previousEnd, length: page.range.location - previousEnd
            ))
            #expect(skipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let piece = body.substring(with: page.range)
            pieces.append(piece)
            let expectedStart = page.range.location == 0 || body.character(at: page.range.location - 1) == 10
            #expect(page.startsParagraph == expectedStart)
            // Drawing a continuation must retain all of the measured text.
            #expect(page.drawable(from: document.attributed).string == piece)
            previousEnd = NSMaxRange(page.range)
        }
        let expected = document.attributed.string.filter { !$0.isWhitespace }
        #expect(pieces.joined().filter { !$0.isWhitespace } == expected)
    }

    @Test("A changed page size produces valid layouts for both chapter edges")
    func pageSizeChange() async {
        let document = PagedDocument.make(
            content: ChapterContent(chapterURL: "local://resize", text: String(repeating: "章节正文，不应遗漏。", count: 400)),
            reading: ReadingSettings(), theme: .of(.night)
        )
        let small = await PageLayout.prepare(document: document, in: CGSize(width: 240, height: 320))
        let large = await PageLayout.prepare(document: document, in: CGSize(width: 400, height: 700))
        #expect(small.count > large.count)
        #expect(small.first?.range.location == 0)
        #expect(large.first?.range.location == 0)
        #expect(small.last.map { NSMaxRange($0.range) } == document.attributed.length)
        #expect(large.last.map { NSMaxRange($0.range) } == document.attributed.length)
    }
}
#endif
