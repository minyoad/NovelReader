import Foundation
import Testing
@testable import NovelKit

/// Reading aloud may start partway into a chunk.
///
/// Chunks are cut from the whole chapter, so the chunk holding sentence 80 can
/// begin at sentence 75. Playing it from 0 re-read 75 through 79 and — worse —
/// reported sentence 75 as the current one, which dragged the reader back a
/// page the instant reading started.
@Suite("Speech starts partway into its chunk")
struct SpeechChunkStartTests {

    static func chunk(containing sentence: Int, in sentences: [String]) -> SpeechChunk? {
        SpeechChunker.sentenceChunks(sentences).first {
            sentence >= $0.sentenceStart && sentence < $0.sentenceStart + $0.sentenceCount
        }
    }

    @Test("a chunk that holds the requested sentence starts earlier than it")
    func chunkStartsEarlier() {
        // Long enough sentences that several fit under the 300-character limit
        // but not all of them.
        let sentences = (1...120).map { "第\($0)句话，写的是一些用来占位的内容。" }
        guard let chunk = Self.chunk(containing: 80, in: sentences) else {
            Issue.record("找不到包含第 80 句的分块")
            return
        }
        #expect(chunk.sentenceStart < 80)
        #expect(80 < chunk.sentenceStart + chunk.sentenceCount)
    }

    @Test("seeking to a sentence inside a chunk lands inside the audio")
    func seekLandsInsideAudio() {
        let sentences = (1...120).map { "第\($0)句话，写的是一些用来占位的内容。" }
        guard let chunk = Self.chunk(containing: 80, in: sentences) else {
            Issue.record("找不到包含第 80 句的分块")
            return
        }
        // Mirrors the character-proportional estimate `seekTime` falls back to
        // when the engine reports no per-sentence timings.
        let offset = 80 - chunk.sentenceStart
        let texts = Array(sentences[chunk.sentenceStart..<(chunk.sentenceStart + chunk.sentenceCount)])
        let total = max(texts.reduce(0) { $0 + $1.count }, 1)
        let before = texts.prefix(offset).reduce(0) { $0 + $1.count }
        let duration = 10.0
        let start = duration * Double(before) / Double(total)

        #expect(start > 0)
        #expect(start < duration)
    }

    @Test("starting on a chunk's first sentence needs no seek")
    func firstSentenceNoSeek() {
        let sentences = (1...10).map { "第\($0)句话。" }
        guard let chunk = Self.chunk(containing: 0, in: sentences) else {
            Issue.record("找不到第一个分块")
            return
        }
        #expect(chunk.sentenceStart == 0)
    }
}
