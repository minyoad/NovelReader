#if canImport(AVFoundation) && canImport(SwiftUI)
import AVFoundation
import Foundation
import NovelKit

/// Plays a one-off sample through the configured engine.
///
/// Exists so the voice can be checked without leaving the settings screen: the
/// failures that matter here (token rejected, endpoint unreachable, model name
/// wrong) are otherwise only discovered a chapter into a book, where they look
/// like "reading doesn't work".
@MainActor
final class TTSVoiceTester: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    /// Retained for the lifetime of the tester: releasing the synthesizer
    /// cancels whatever it is speaking, which would cut the sample short.
    private let systemSynthesizer = AVSpeechSynthesizer()

    /// Short enough to synthesize in under a second, long enough to judge the
    /// voice: one comma pause and a full stop.
    static let sample = "夜色沉下来，风从窗缝里挤进来。这是朗读试听。"

    func preview(_ settings: TTSSettings) {
        stop()
        guard settings.isRemoteUsable else {
            state = .failed("请先在上面选择音色或填写接口。")
            return
        }
        state = .loading

        task = Task { [weak self] in
            do {
                var audio: Data
                switch settings.engine {
                case .system:
                    // The system engine has no renderable file to cache; its
                    // quality is judged in the reader, not here.
                    await self?.speakWithSystem(sample: Self.sample, settings: settings)
                    self?.state = .idle
                    return
                case .edge:
                    audio = try await EdgeTTSClient().synthesize(
                        text: Self.sample,
                        voice: settings.remote.edgeVoice,
                        rate: settings.rate,
                        pitch: settings.pitch,
                        volume: settings.volume
                    ).audio
                case .openAICompatible:
                    audio = try await OpenAISpeechClient().synthesize(
                        text: Self.sample,
                        settings: settings.remote,
                        rate: settings.rate
                    )
                }

                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(data: audio)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player.prepareToPlay()
                player.play()
                self?.player = player
                self?.state = .idle
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        // Keep a failure message visible; only clear the transient states.
        switch state {
        case .loading, .idle:
            state = .idle
        case .failed:
            break
        }
    }

    private func speakWithSystem(sample: String, settings: TTSSettings) async {
        let utterance = AVSpeechUtterance(string: sample)
        if let identifier = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = Float(max(0.1, min(settings.rate, 1.0)))
        utterance.pitchMultiplier = Float(max(0.5, min(settings.pitch, 2.0)))
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        systemSynthesizer.speak(utterance)
        // Wait out the sample so the caller does not report "done" (and the
        // state does not go idle) while it is still speaking.
        try? await Task.sleep(for: .seconds(6))
    }
}
#endif
