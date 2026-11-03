import Foundation
import Testing
@testable import NovelKit

/// The reader paginates `PaginatedText.body`, and reading positions are
/// rounded-trip through it. Splitting sentences from the raw chapter instead
/// meant two normalizations had to agree, and they did not: every indented
/// paragraph shifted them slightly further apart, so a page's top resolved to
/// a sentence earlier in the page the deeper the chapter went.
///
/// These tests pin the one-text rule: sentences come from the same `body` the
/// layout uses, so an offset into that body lands on the sentence actually
/// there.
@Suite("Speech positions in paginated body coordinates")
struct SpeechBodyCoordinateTests {

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

    /// Mirrors `SpeechController.sentenceBodyOffsets(in:)`.
    static func sentenceBodyOffsets(in body: String, sentences: [String]) -> [Int] {
        var offsets: [Int] = []
        var cursor = body.startIndex
        for sentence in sentences {
            if let range = body.range(of: sentence, range: cursor..<body.endIndex) {
                offsets.append(body.distance(from: body.startIndex, to: range.lowerBound))
                cursor = range.upperBound
            } else {
                offsets.append(offsets.last ?? 0)
            }
        }
        return offsets
    }

    @Test("a body offset resolves to the sentence that starts there, deep into the chapter")
    func deepIntoChapter() {
        // Forty indented paragraphs: 40 × 2 ideographic spaces that the old
        // raw-text route failed to account for, 80 characters of drift.
        let paragraphs = (1...40).map { "　　第\($0)段的内容，写了一些事情来占版面。" }
        let raw = paragraphs.joined(separator: "\n")
        let paginated = PaginatedText(rawText: raw)
        let body = paginated.body
        let sentences = TextProcessing.sentences(fromBody: body)

        // Pretend a page starts at the 38th paragraph.
        let target = body.range(of: "第38段")!.lowerBound
        let bodyOffset = body.distance(from: body.startIndex, to: target)
        let index = Self.sentenceIndex(forCharactersBefore: bodyOffset, in: body, sentences: sentences)
        #expect(sentences[index].hasPrefix("第38段"))
    }

    @Test("a page top mid-sentence starts on the first sentence beginning on the page")
    func midSentence() {
        let raw = "　　第一段。\n　　第二段里有一句比较长的话，它中间被分页截断了。后面还有。"
        let paginated = PaginatedText(rawText: raw)
        let body = paginated.body
        let sentences = TextProcessing.sentences(fromBody: body)

        // The page top sits inside "它中间被分页截断了。", which began on the
        // previous page. Reading from it would scroll back, so the first
        // sentence that starts on this page wins.
        let inside = body.range(of: "它中间")!.lowerBound
        let bodyOffset = body.distance(from: body.startIndex, to: inside)
        let index = Self.sentenceIndex(forCharactersBefore: bodyOffset, in: body, sentences: sentences)
        #expect(sentences[index] == "后面还有。")
    }

    @Test("sentence body offsets round-trip back to raw offsets monotonically")
    func roundTripsToRaw() {
        let raw = "　　第一段。\n\n\n　　第二段。\n　　第三段。"
        let paginated = PaginatedText(rawText: raw)
        let sentences = TextProcessing.sentences(fromBody: paginated.body)
        let bodyOffsets = Self.sentenceBodyOffsets(in: paginated.body, sentences: sentences)
        let rawOffsets = bodyOffsets.map { paginated.originalOffset(forBody: $0) }

        #expect(rawOffsets == rawOffsets.sorted(), "原文偏移必须单调不减")
        #expect(rawOffsets.first == raw.distance(from: raw.startIndex, to: raw.range(of: "第一段")!.lowerBound))
        #expect(rawOffsets.last == raw.distance(from: raw.startIndex, to: raw.range(of: "第三段")!.lowerBound))
    }

    @Test("body text collapses indentation and blank runs")
    func bodyShape() {
        let raw = "　　第一段。\n\n\n　　第二段。"
        #expect(PaginatedText(rawText: raw).body == "第一段。\n第二段。")
    }
}
