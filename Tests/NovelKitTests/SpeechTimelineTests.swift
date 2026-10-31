import Foundation
import Testing
@testable import NovelKit

@Suite("Speech timeline")
struct SpeechTimelineTests {

    private let sentences = ["第一句话。", "第二句话更长一些。", "第三句。"]

    @Test("duration follows character count and speed")
    func durationScalesWithRate() {
        let timeline = SpeechTimeline(sentences: sentences)
        let total = sentences.reduce(0) { $0 + $1.count }
        let base = Double(total) / SpeechTimeline.charactersPerSecond

        #expect(abs(timeline.duration(atRate: 0.5) - base) < 0.001)
        // Double speed halves the time; half speed doubles it.
        #expect(abs(timeline.duration(atRate: 1.0) - base / 2) < 0.001)
        #expect(abs(timeline.duration(atRate: 0.25) - base / 0.5) < 0.001)
    }

    @Test("elapsed time is the sum of the sentences before the index")
    func elapsedAccumulates() {
        let timeline = SpeechTimeline(sentences: sentences)
        let rate = 0.5
        #expect(timeline.elapsed(before: 0, atRate: rate) == 0)

        let expected = Double(sentences[0].count) / SpeechTimeline.charactersPerSecond
        #expect(abs(timeline.elapsed(before: 1, atRate: rate) - expected) < 0.001)

        // Past the end clamps to the whole chapter rather than overrunning.
        #expect(abs(timeline.elapsed(before: 99, atRate: rate) - timeline.duration(atRate: rate)) < 0.001)
    }

    @Test("a scrub position lands on the sentence that occupies it")
    func seekMapsBack() {
        let timeline = SpeechTimeline(sentences: sentences)
        let rate = 0.5
        let duration = timeline.duration(atRate: rate)

        #expect(timeline.sentenceIndex(atSeconds: 0, rate: rate) == 0)
        #expect(timeline.sentenceIndex(atSeconds: duration, rate: rate) == sentences.count - 1)
        // The middle of the chapter is the second of three sentences.
        #expect(timeline.sentenceIndex(atSeconds: duration / 2, rate: rate) == 1)
    }

    @Test("dragging past either end clamps instead of crashing")
    func seekClamps() {
        let timeline = SpeechTimeline(sentences: sentences)
        #expect(timeline.sentenceIndex(atSeconds: -30, rate: 0.5) == 0)
        #expect(timeline.sentenceIndex(atSeconds: 1_000_000, rate: 0.5) == sentences.count - 1)
    }

    @Test("character offsets map to the containing sentence")
    func sentenceForOffset() {
        let timeline = SpeechTimeline(sentences: sentences)
        #expect(timeline.sentenceIndex(atCharactersBefore: 0) == 0)
        #expect(timeline.sentenceIndex(atCharactersBefore: 1) == 0)
        #expect(timeline.sentenceIndex(atCharactersBefore: sentences[0].count) == 0)
        #expect(timeline.sentenceIndex(atCharactersBefore: sentences[0].count + 1) == 1)
        #expect(timeline.sentenceIndex(atCharactersBefore: 100_000) == sentences.count - 1)
    }

    @Test("blank sentences still occupy a slot so indices stay aligned")
    func blankSentencesKeepIndices() {
        let timeline = SpeechTimeline(sentences: ["", "有内容。", ""])
        #expect(timeline.sentenceCount == 3)
        // A blank takes no time, but it keeps its slot so index 1 is still the
        // sentence with text.
        #expect(timeline.weights[0] == 0)
        #expect(timeline.sentenceIndex(atCharactersBefore: 1) == 1)
        #expect(timeline.sentenceIndex(atCharactersBefore: 0) == 1)
    }

    @Test("an empty chapter reports a zero-length, harmless timeline")
    func emptyIsSafe() {
        let timeline = SpeechTimeline(sentences: [])
        #expect(timeline.isEmpty)
        #expect(timeline.duration(atRate: 0.5) == 0)
        #expect(timeline.elapsed(before: 3, atRate: 0.5) == 0)
        #expect(timeline.sentenceIndex(atSeconds: 12, rate: 0.5) == 0)
        #expect(timeline.sentenceIndex(atCharactersBefore: 5) == 0)
    }
}
