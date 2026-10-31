import Foundation

/// A group of consecutive sentences synthesized in one request.
///
/// `sentenceStart`/`sentenceCount` let the player map the service's per-sentence
/// timings back onto the reader's sentence list without re-splitting the text,
/// which is the only reliable way to keep the highlight in step with the audio.
public struct SpeechChunk: Sendable, Equatable {
    public var text: String
    public var sentenceStart: Int
    public var sentenceCount: Int

    public init(text: String, sentenceStart: Int, sentenceCount: Int) {
        self.text = text
        self.sentenceStart = sentenceStart
        self.sentenceCount = sentenceCount
    }
}

/// Turns a chapter into the individual utterances sent to a speech engine.
///
/// Pure and engine agnostic so the chunking rules — which decide cache keys and
/// therefore how much work is redone when something changes — can be tested
/// without a synthesizer.
public enum SpeechChunker {
    /// One request per chunk. Kept well under the 4096-byte limit Edge enforces
    /// so a single failure only costs a fraction of a second of audio, and so a
    /// chapter can start playing before it has finished synthesizing.
    public static let maxCharacters = 300

    /// Splits `text` into chunks that each end on a sentence boundary where
    /// possible.
    ///
    /// Paragraph breaks are honoured first: reading across a paragraph break
    /// as if it were continuous sounds wrong, because the author's pause is
    /// longer than the one the synthesizer inserts for a comma.
    public static func chunks(from text: String, maxCharacters: Int = maxCharacters) -> [String] {
        let limit = max(maxCharacters, 20)
        var result: [String] = []

        for paragraph in text.components(separatedBy: .newlines) {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result.append(contentsOf: split(trimmed, limit: limit))
        }
        return result
    }

    /// Groups `sentences` into chunks for the remote engines.
    ///
    /// Grouping by whole sentences (rather than by character count) keeps the
    /// service's per-sentence timings aligned with the reader's sentence list,
    /// so highlighting stays correct without any duration guessing.
    public static func sentenceChunks(
        _ sentences: [String],
        maxCharacters: Int = maxCharacters
    ) -> [SpeechChunk] {
        let limit = max(maxCharacters, 20)
        var result: [SpeechChunk] = []
        var buffer: [String] = []
        var length = 0
        var start = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(
                SpeechChunk(
                    text: buffer.joined(),
                    sentenceStart: start,
                    sentenceCount: buffer.count
                )
            )
            start += buffer.count
            buffer = []
            length = 0
        }

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !buffer.isEmpty && length + trimmed.count > limit {
                flush()
            }
            buffer.append(trimmed)
            length += trimmed.count
        }
        flush()
        return result
    }

    private static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }

        var chunks: [String] = []
        var buffer = ""

        for character in text {
            buffer.append(character)
            let atSentenceEnd = "。！？…!?".contains(character)
            if atSentenceEnd && buffer.count >= limit / 3 {
                chunks.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            } else if buffer.count >= limit {
                // No sentence end in reach: fall back to a softer break so a
                // run-on paragraph still gets split near a natural pause.
                if let cut = softBreak(in: buffer) {
                    let head = String(buffer[..<cut])
                    chunks.append(head.trimmingCharacters(in: .whitespaces))
                    buffer = String(buffer[cut...])
                } else {
                    chunks.append(buffer)
                    buffer = ""
                }
            }
        }

        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    /// Index just past the last comma-like pause in the second half of `text`,
    /// or `nil` when there is none.
    private static func softBreak(in text: String) -> String.Index? {
        let half = text.count / 2
        var best: String.Index?
        var index = text.startIndex
        for offset in 0..<text.count {
            if "，、,：:；; ".contains(text[index]), offset > half {
                best = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return best
    }
}

/// Cache keys for synthesized audio.
public enum SpeechCacheKey {
    /// Everything that changes the produced audio has to be in the key,
    /// otherwise switching voices or speeds would replay the old recording.
    public static func key(
        text: String,
        engine: TTSEngine,
        voice: String,
        rate: Double,
        pitch: Double
    ) -> String {
        // Two decimals on rate/pitch: finer granularity is inaudible, and
        // rounding keeps the key stable across tiny slider noise.
        let descriptor = [
            engine.rawValue,
            voice,
            String(format: "%.2f", rate),
            String(format: "%.2f", pitch),
            text,
        ].joined(separator: "|")
        return StableHash.hex(descriptor)
    }
}

/// Least-recently-used bookkeeping for the speech cache.
///
/// Mirrors `CachePlanner`'s approach: the policy lives in NovelKit where it can
/// be tested, while the file IO stays in the app layer.
public enum SpeechCachePolicy {
    /// Files to delete so the total stays under `limitBytes`.
    ///
    /// `entries` carries the last-use timestamps, oldest first is what this
    /// returns, so the caller can delete in order until it is under the cap.
    public static func evictionOrder(
        entries: [(key: String, size: Int64, lastUsed: Date)],
        limitBytes: Int64
    ) -> [String] {
        guard limitBytes > 0 else { return [] }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return [] }

        var remaining = total
        var doomed: [String] = []
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard remaining > limitBytes else { break }
            doomed.append(entry.key)
            remaining -= entry.size
        }
        return doomed
    }
}
