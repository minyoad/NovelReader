import Foundation

/// Maps between character positions and playback time for a spoken chapter.
///
/// A chapter is synthesized in chunks, so no single audio duration exists for
/// it — each chunk arrives with its own MP3 and its own length. The Lock Screen,
/// however, wants one duration and one scrubber position, so this estimates
/// both from the only thing known up front: how much text there is.
///
/// The estimate is proportional, which is all the scrubber needs. Dragging to
/// the middle of the bar lands in the middle of the chapter, and the reader can
/// then fine-tune by sentence.
public struct SpeechTimeline: Sendable {
    /// Character count per sentence, in order. Blank sentences get zero, so
    /// they take up no time but still occupy their slot: indices here must line
    /// up with the sentence indices used for highlighting.
    public let weights: [Int]
    /// Running total of `weights`, used to place the start of each sentence.
    private let totals: [Int]

    /// Characters a natural reading pace covers in a second.
    ///
    /// Deliberately constant rather than per-voice: the point is a stable bar,
    /// not an accurate stopwatch, and a bar that jumps around between chunks
    /// looks broken.
    public static let charactersPerSecond: Double = 5

    public init(sentences: [String]) {
        let weights = sentences.map { $0.count }
        self.weights = weights
        var running = 0
        var totals: [Int] = []
        totals.reserveCapacity(weights.count)
        for weight in weights {
            running += weight
            totals.append(running)
        }
        self.totals = totals
    }

    public var isEmpty: Bool { weights.isEmpty }
    public var sentenceCount: Int { weights.count }
    /// Total characters, or zero for an empty chapter — a zero-length timeline
    /// is what makes every derived value collapse to `0`.
    public var totalCharacters: Int { totals.last ?? 0 }

    /// Seconds of speech at `rate`, where 0.5 is the engines' natural pace.
    ///
    /// The engines themselves are asked to speak faster, so the duration has to
    /// shrink by the same factor; otherwise the bar would finish early on a
    /// fast setting and the scrubber would land in the wrong place.
    public func duration(atRate rate: Double) -> Double {
        Double(totalCharacters) / Self.charactersPerSecond / Self.speedFactor(rate)
    }

    /// Seconds from the start of the chapter to the beginning of `index`.
    public func elapsed(before index: Int, atRate rate: Double) -> Double {
        guard !weights.isEmpty else { return 0 }
        let clamped = min(max(index, 0), weights.count)
        let before = clamped == 0 ? 0 : totals[clamped - 1]
        return Double(before) / Self.charactersPerSecond / Self.speedFactor(rate)
    }

    /// The sentence containing a position on the scrubber.
    ///
    /// Out-of-range positions clamp rather than fail: the system can hand back a
    /// rounded value slightly past the end of a bar the user dragged to its
    /// edge.
    public func sentenceIndex(atSeconds seconds: Double, rate: Double) -> Int {
        guard totalCharacters > 0 else { return 0 }
        let fraction = max(0, min(1, seconds / duration(atRate: rate)))
        let target = Int((Double(totalCharacters) * fraction).rounded())
        return sentenceIndex(atCharactersBefore: target)
    }

    /// The sentence containing a character offset into the chapter.
    ///
    /// Blank sentences occupy no characters, so they are stepped over: an
    /// offset can only ever land inside a sentence that has text.
    public func sentenceIndex(atCharactersBefore offset: Int) -> Int {
        guard !weights.isEmpty else { return 0 }
        for (index, weight) in weights.enumerated() where weight > 0 && totals[index] >= offset {
            return index
        }
        return weights.count - 1
    }

    /// Rate relative to the engines' natural pace, floored so a very slow
    /// setting cannot make the estimate grow without bound.
    private static func speedFactor(_ rate: Double) -> Double {
        max(rate / 0.5, 0.25)
    }
}
