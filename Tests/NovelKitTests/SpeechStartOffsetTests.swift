import Foundation
import Testing
@testable import NovelKit

/// The sentence lookup that decides where reading starts when the queue is
/// loaded. Positions now come from the paginated body, so these tests work in
/// that same coordinate space.
@Suite("Speech start offset")
struct SpeechStartOffsetTests {

    @Test("an offset at the very start stays at zero")
    func startStaysZero() {
        let text = "第一句话。第二句话。"
        let sentences = TextProcessing.sentences(fromBody: text)
        #expect(SpeechStartLookup.sentenceIndex(forCharactersBefore: 0, in: text, sentences: sentences) == 0)
    }

    @Test("the sentence starting at a page top is the one read")
    func picksSentenceAtPageTop() {
        let text = "第一句话。第二句话。第三句话。第四句话。"
        let sentences = TextProcessing.sentences(fromBody: text)

        let pageTop = text.distance(
            from: text.startIndex,
            to: text.range(of: "第三句话")!.lowerBound
        )
        let index = SpeechStartLookup.sentenceIndex(
            forCharactersBefore: pageTop,
            in: text,
            sentences: sentences
        )
        #expect(sentences[index] == "第三句话。")
    }

    @Test("a page top inside a sentence skips to the next sentence that starts there")
    func picksNextSentenceStart() {
        // The long middle sentence began on the previous page. Reading starts
        // on the sentence after it, which is fully on this page — starting
        // mid-sentence would turn the page back to its beginning.
        let text = "开头一句。中间这一句比较长。结尾一句。"
        let sentences = TextProcessing.sentences(fromBody: text)

        let inside = text.distance(
            from: text.startIndex,
            to: text.range(of: "比较长")!.lowerBound
        )
        let index = SpeechStartLookup.sentenceIndex(
            forCharactersBefore: inside,
            in: text,
            sentences: sentences
        )
        #expect(sentences[index] == "结尾一句。")
    }

    @Test("a sentence straddling the page break does not drag reading back a page")
    func skipsStraddlingSentence() {
        // The page top falls inside the long middle sentence, which began on
        // the previous page. Reading must start on the first sentence that
        // actually begins on this page — otherwise the follow-along turns back
        // to where that sentence starts.
        let text = "开头一句。中间这一句比较长，它跨过了页面的边界。结尾一句。"
        let sentences = TextProcessing.sentences(fromBody: text)

        let inside = text.distance(
            from: text.startIndex,
            to: text.range(of: "跨过了页面")!.lowerBound
        )
        let index = SpeechStartLookup.sentenceIndex(
            forCharactersBefore: inside,
            in: text,
            sentences: sentences
        )
        #expect(sentences[index] == "结尾一句。")
    }

    @Test("a page holding only the tail of one sentence still reads it")
    func keepsStraddlingSentenceWhenItIsAllThere() {
        let text = "前面一句很长的话，一直写到了这一页的顶上才结束。"
        let sentences = TextProcessing.sentences(fromBody: text)

        let inside = text.distance(
            from: text.startIndex,
            to: text.range(of: "这一页的顶上")!.lowerBound
        )
        let index = SpeechStartLookup.sentenceIndex(
            forCharactersBefore: inside,
            in: text,
            sentences: sentences
        )
        #expect(index == 0)
    }

    @Test("an offset past the end clamps to the last sentence")
    func clampsAtEnd() {
        let text = "第一句话。第二句话。"
        let sentences = TextProcessing.sentences(fromBody: text)
        let index = SpeechStartLookup.sentenceIndex(forCharactersBefore: 9999, in: text, sentences: sentences)
        #expect(sentences[index] == "第二句话。")
    }
}

/// Mirrors `SpeechController.sentenceIndex(forCharactersBefore:in:sentences:)`.
///
/// The real one lives in the app target and needs UIKit, so it cannot be
/// imported here; this copy exists so the lookup rule is covered by tests.
enum SpeechStartLookup {
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
}
