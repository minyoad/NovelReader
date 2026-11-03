import Foundation
import Testing
@testable import NovelKit

/// The reading position comes from pagination over the raw chapter text, but
/// the sentence lists used for speech are built from the normalized text.
/// These tests pin the bridge between the two, which is what decides where
/// reading starts when you press the button mid-chapter.
@Suite("Speech start offset")
struct SpeechStartOffsetTests {

    @Test("a raw offset maps to the same passage after normalization")
    func mapsAcrossNormalization() {
        // Indented lines and a zero-width space: exactly what a scraped
        // chapter contains, and what normalization removes.
        let raw = "\u{200B}　　第一段。\n\n\n    第二段。\n　　第三段。"
        let normalized = TextProcessing.normalizeParagraphs(raw)

        let thirdParagraph = raw.range(of: "第三段")!.lowerBound
        let rawOffset = raw.distance(from: raw.startIndex, to: thirdParagraph)
        let mapped = TextProcessing.normalizedOffset(rawOffset, in: raw)

        let expected = normalized.distance(
            from: normalized.startIndex,
            to: normalized.range(of: "第三段")!.lowerBound
        )
        #expect(mapped == expected)
    }

    @Test("an offset at the very start stays at zero")
    func startStaysZero() {
        #expect(TextProcessing.normalizedOffset(0, in: "　　正文。") == 0)
    }

    @Test("an offset past the end clamps to the normalized length")
    func endClamps() {
        let raw = "　　第一段。\n　　第二段。"
        #expect(TextProcessing.normalizedOffset(9999, in: raw) == TextProcessing.normalizeParagraphs(raw).count)
    }

    @Test("the sentence starting at a page top is the one read")
    func picksSentenceAtPageTop() {
        let text = "第一句话。第二句话。第三句话。第四句话。"
        let sentences = TextProcessing.sentences(from: text)

        // Page begins exactly at the third sentence.
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

    @Test("a page top inside a sentence reads that whole sentence")
    func picksContainingSentence() {
        let text = "开头一句。中间这句話比较长。结尾一句。"
        let sentences = TextProcessing.sentences(from: text)

        // Page breaks in the middle of the long sentence.
        let inside = text.distance(
            from: text.startIndex,
            to: text.range(of: "比较长")!.lowerBound
        )
        let index = SpeechStartLookup.sentenceIndex(
            forCharactersBefore: inside,
            in: text,
            sentences: sentences
        )
        #expect(sentences[index] == "中间这句話比较长。")
    }
}

/// Mirrors `SpeechController.sentenceIndex(forCharactersBefore:in:sentences:)`.
///
/// The real one lives in the app target and needs UIKit, so it cannot be
/// imported here; this copy exists so the lookup rule — the thing that was
/// wrong — is covered by tests.
enum SpeechStartLookup {
    static func sentenceIndex(forCharactersBefore offset: Int, in text: String, sentences: [String]) -> Int {
        guard offset > 0 else { return 0 }
        let target = text.index(text.startIndex, offsetBy: min(offset, text.count))
        var cursor = text.startIndex
        for (index, sentence) in sentences.enumerated() {
            guard let range = text.range(of: sentence, range: cursor..<text.endIndex) else { continue }
            cursor = range.upperBound
            if range.upperBound > target { return index }
        }
        return max(sentences.count - 1, 0)
    }
}
