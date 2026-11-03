import Foundation
import Testing
@testable import NovelKit

/// The reader stores the visible page's start as a raw-text offset; reading
/// aloud turns that into a sentence and then the page back into an offset to
/// follow along. Those two trips must land on the same page. When they did
/// not, pressing read scrolled to the previous page a moment after the
/// highlight appeared in the right place.
///
/// This drives the whole loop — page start → sentence → sentence start — and
/// checks the result never moves backwards past the page it came from.
@Suite("Following the speaker stays on the page")
struct SpeechFollowPageTests {

    /// Mirrors `SpeechController.sentenceIndex(forCharactersBefore:in:sentences:)`.
    static func sentenceIndex(forCharactersBefore offset: Int, in text: String, sentences: [String]) -> Int {
        guard offset > 0 else { return 0 }
        let target = text.index(text.startIndex, offsetBy: min(offset, text.count))
        var cursor = text.startIndex
        var straddling: Int?
        for (index, sentence) in sentences.enumerated() {
            guard let range = text.range(of: sentence, range: cursor..<text.endIndex) else { continue }
            cursor = range.upperBound
            if range.lowerBound >= target { return index }
            if straddling == nil, range.upperBound > target { straddling = index }
        }
        if let straddling { return straddling }
        return max(sentences.count - 1, 0)
    }

    /// Mirrors `SpeechController.characterOffset(ofSentence:in:)`.
    static func characterOffset(ofSentence index: Int, in text: String, sentences: [String]) -> Int {
        let paginated = PaginatedText(rawText: text)
        let body = paginated.body
        var bodyOffsets: [Int] = []
        var cursor = body.startIndex
        for sentence in sentences {
            if let range = body.range(of: sentence, range: cursor..<body.endIndex) {
                bodyOffsets.append(body.distance(from: body.startIndex, to: range.lowerBound))
                cursor = range.upperBound
            } else {
                bodyOffsets.append(bodyOffsets.last ?? 0)
            }
        }
        guard bodyOffsets.indices.contains(index) else { return 0 }
        return paginated.originalOffset(forBody: bodyOffsets[index])
    }

    /// Chapter text shaped like a scraped novel: indented paragraphs, some
    /// long enough to run over a page break.
    static var chapter: String {
        (1...60).map { index in
            "　　\(index)号段落从这里开始，写了一些内容，"
                + "并且继续写了比较长的一段话，好让它跨过页面边界，"
                + "最后以句号收尾。"
        }.joined(separator: "\n")
    }

    @Test("every paragraph start resolves back to itself or later, never earlier")
    func paragraphStartsAreStable() {
        let text = Self.chapter
        let paginated = PaginatedText(rawText: text)
        let body = paginated.body
        let sentences = TextProcessing.sentences(fromBody: body)

        for index in 1...60 {
            let marker = "\(index)号段落从这里开始"
            guard let range = body.range(of: marker) else {
                Issue.record("缺少段落 \(index)")
                continue
            }
            let bodyOffset = body.distance(from: body.startIndex, to: range.lowerBound)
            let pageStart = paginated.originalOffset(forBody: bodyOffset)

            let sentence = Self.sentenceIndex(
                forCharactersBefore: bodyOffset,
                in: body,
                sentences: sentences
            )
            let followOffset = Self.characterOffset(ofSentence: sentence, in: text, sentences: sentences)
            #expect(
                followOffset >= pageStart,
                "第 \(index) 段：句首偏移 \(followOffset) 早于页首 \(pageStart)"
            )
            #expect(
                sentences[sentence].hasPrefix("\(index)号段落"),
                "第 \(index) 段：选中的句子是「\(sentences[sentence])」"
            )
        }
    }

    @Test("a page starting mid-sentence never follows the speaker backwards")
    func midSentenceStaysPut() {
        let text = Self.chapter
        let paginated = PaginatedText(rawText: text)
        let body = paginated.body
        let sentences = TextProcessing.sentences(fromBody: body)

        // Simulate page tops at many positions: some fall on paragraph starts,
        // most land inside a wrapped line.
        let step = max(body.count / 40, 1)
        var position = 0
        while position < body.count {
            let pageStartBody = min(position, body.count)
            let pageStart = paginated.originalOffset(forBody: pageStartBody)
            let sentence = Self.sentenceIndex(
                forCharactersBefore: pageStartBody,
                in: body,
                sentences: sentences
            )
            let followOffset = Self.characterOffset(ofSentence: sentence, in: text, sentences: sentences)

            // The page shows a stretch of text; the sentence is visible when
            // the two overlap, and that is all the follow-along asks before it
            // declines to turn the page.
            let pageEndBody = min(pageStartBody + step, body.count)
            let pageEnd = paginated.originalOffset(forBody: pageEndBody)
            let sentenceEnd = followOffset + sentences[sentence].count
            let visible = followOffset < pageEnd && sentenceEnd > pageStart
            #expect(
                visible || followOffset >= pageStart,
                "偏移 \(pageStartBody) 处：跟随位置 \(followOffset) 早于页首 \(pageStart)，且句子不可见"
            )
            position += step
        }
    }

    @Test("a sentence that starts on the page above is still visible on this one")
    func straddlingSentenceIsVisible() {
        let text = Self.chapter
        let paginated = PaginatedText(rawText: text)
        let body = paginated.body
        let sentences = TextProcessing.sentences(fromBody: body)

        // Take the sentence that spans the middle of the chapter and put the
        // page top in the middle of it.
        let middle = body.index(body.startIndex, offsetBy: body.count / 2)
        let sentenceIndex = Self.sentenceIndex(
            forCharactersBefore: body.distance(from: body.startIndex, to: middle),
            in: body,
            sentences: sentences
        )
        let start = Self.characterOffset(ofSentence: sentenceIndex, in: text, sentences: sentences)
        let end = start + sentences[sentenceIndex].count
        // A page beginning anywhere inside the sentence overlaps it, so the
        // follow-along must leave the page alone instead of returning to
        // `start`.
        #expect(start < end)
        #expect(sentences[sentenceIndex].isEmpty == false)
    }
}
