#if canImport(AVFoundation) && canImport(SwiftUI)
import AVFoundation
import Foundation
import NovelKit

/// Wraps `AVSpeechSynthesizer` with the bits a reader needs: sentence level
/// progress, pause/resume, voice selection and background playback.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var sentences: [String] = []

    /// Called whenever a new sentence starts.
    var onSentenceChange: ((Int) -> Void)?
    /// Called when the queue is exhausted.
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var settings = TTSSettings()
    private var didConfigureSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var currentSentence: String? {
        guard sentences.indices.contains(currentIndex) else { return nil }
        return sentences[currentIndex]
    }

    var hasContent: Bool { !sentences.isEmpty }

    func configure(_ settings: TTSSettings) {
        self.settings = settings
    }

    /// Replaces the queue. When `autoPlay` is true reading starts immediately.
    func load(sentences newSentences: [String], startAt index: Int = 0, autoPlay: Bool = true) {
        stop()
        sentences = newSentences
        currentIndex = min(max(index, 0), max(newSentences.count - 1, 0))
        guard autoPlay, !newSentences.isEmpty else { return }
        play()
    }

    func play() {
        guard sentences.indices.contains(currentIndex) else { return }
        if isPaused, synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isSpeaking = true
            return
        }
        activateSession()
        speakCurrent()
    }

    func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPaused = true
        isSpeaking = false
    }

    func toggle() {
        if isSpeaking { pause() } else { play() }
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
    }

    func next() {
        guard currentIndex + 1 < sentences.count else {
            finishQueue()
            return
        }
        currentIndex += 1
        restartCurrent()
    }

    func previous() {
        currentIndex = max(currentIndex - 1, 0)
        restartCurrent()
    }

    func jump(to index: Int) {
        guard sentences.indices.contains(index) else { return }
        currentIndex = index
        restartCurrent()
    }

    /// Jump to the sentence that best matches an offset inside the chapter text.
    func sentenceIndex(forCharactersBefore offset: Int, in text: String) -> Int {
        guard offset > 0 else { return 0 }
        let target = text.index(text.startIndex, offsetBy: min(offset, text.count))
        let prefix = String(text[..<target])
        var accumulated = 0
        for (index, sentence) in sentences.enumerated() {
            accumulated += sentence.count
            if accumulated >= prefix.count { return index }
        }
        return max(sentences.count - 1, 0)
    }

    func characterOffset(ofSentence index: Int, in text: String) -> Int {
        guard sentences.indices.contains(index) else { return 0 }
        var offset = 0
        for i in 0..<index {
            if let range = text.range(of: sentences[i], range: text.startIndex..<text.endIndex) {
                offset = text.distance(from: text.startIndex, to: range.upperBound)
            }
        }
        return offset
    }

    // MARK: - Private

    private func restartCurrent() {
        let wasPlaying = isSpeaking || isPaused
        synthesizer.stopSpeaking(at: .immediate)
        isPaused = false
        guard wasPlaying else {
            onSentenceChange?(currentIndex)
            return
        }
        activateSession()
        speakCurrent()
    }

    private func speakCurrent() {
        guard sentences.indices.contains(currentIndex) else {
            finishQueue()
            return
        }
        let utterance = AVSpeechUtterance(string: sentences[currentIndex])
        if let identifier = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = Float(max(0.1, min(settings.rate, 1.0)))
        utterance.pitchMultiplier = Float(max(0.5, min(settings.pitch, 2.0)))
        utterance.volume = Float(max(0, min(settings.volume, 1)))

        isSpeaking = true
        isPaused = false
        onSentenceChange?(currentIndex)
        synthesizer.speak(utterance)
    }

    private func advance() {
        guard isSpeaking else { return }
        if currentIndex + 1 < sentences.count {
            currentIndex += 1
            speakCurrent()
        } else {
            finishQueue()
        }
    }

    private func finishQueue() {
        isSpeaking = false
        isPaused = false
        onFinished?()
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            didConfigureSession = true
        } catch {
            // Reading still works without a properly configured session; it just
            // may not continue in the background.
        }
    }

    private func deactivateSession() {
        guard didConfigureSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        didConfigureSession = false
    }

    static func availableChineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name < $1.name }
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isSpeaking else { return }
            self.advance()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Cancellation happens on stop/jump; state is already handled there.
            if self.isSpeaking {
                self.isSpeaking = false
            }
        }
    }
}
#endif
