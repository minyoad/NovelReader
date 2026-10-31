#if canImport(AVFoundation) && canImport(SwiftUI)
import AVFoundation
import Foundation
import NovelKit

/// Reads a chapter aloud.
///
/// Three engines share this one façade so the reader never has to care which is
/// active:
///
///  * `system` — `AVSpeechSynthesizer`, offline and instant.
///  * `edge` — Microsoft's read-aloud service, natural voices, free.
///  * `openAICompatible` — any `/audio/speech` server, including a local one.
///
/// The remote engines synthesize whole groups of sentences per request and keep
/// the resulting MP3 on disk, so pausing, jumping back or reopening a chapter
/// costs nothing. Highlighting still advances sentence by sentence: the service
/// reports timings per sentence, and when it does not the durations are
/// estimated by character count.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var sentences: [String] = []
    /// True while a remote utterance is being fetched, so the reader can show a
    /// spinner instead of a play button that appears to do nothing.
    @Published private(set) var isPreparing = false
    /// Set when a remote engine fails, so the reader can explain why the voice
    /// did not start instead of silently doing nothing.
    @Published private(set) var lastError: String?

    /// Called whenever a new sentence starts.
    var onSentenceChange: ((Int) -> Void)?
    /// Called when the queue is exhausted.
    var onFinished: (() -> Void)?
    /// Called when a remote engine could not produce audio.
    var onError: ((String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var settings = TTSSettings()
    private var didConfigureSession = false

    // MARK: Remote playback

    private var store: LibraryStore?
    private var chunks: [SpeechChunk] = []
    private var currentChunkIndex = 0
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    private var currentChunkBoundaries: [EdgeSentenceBoundary] = []
    /// Holds the chunk fetched ahead of the one playing.
    ///
    /// Needed even with the disk cache off: otherwise "prefetch" would fetch
    /// audio, throw it away and fetch it again when the chunk starts, which is
    /// worse than not prefetching at all. Only the next chunk is kept, so this
    /// never grows past one utterance.
    private var prefetched: (key: String, audio: Data, boundaries: [EdgeSentenceBoundary])?
    /// Memoised sentence-end offsets for the current chapter text; invalidated
    /// whenever the text changes (chapter switch, AI cleanup).
    private var offsetsCache: (text: String, offsets: [Int])?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var currentSentence: String? {
        guard sentences.indices.contains(currentIndex) else { return nil }
        return sentences[currentIndex]
    }

    var hasContent: Bool { !sentences.isEmpty }

    /// Whether the bar should be visible: audio is playing, paused, or being
    /// fetched. Without the preparing case, pressing play on a remote engine
    /// would hide the controls for the second before audio arrives.
    var isActive: Bool { isSpeaking || isPaused || isPreparing }

    /// True while audio is actually coming out, as opposed to paused or still
    /// being fetched. Drives the play/pause icon.
    var isPlaying: Bool { isSpeaking && !isPaused }

    var engine: TTSEngine { settings.engine }

    /// Gives the controller access to the audio cache.
    func attach(store: LibraryStore) {
        self.store = store
    }

    func configure(_ settings: TTSSettings) {
        // Changing engine, voice or speed mid-sentence would otherwise leave the
        // old audio playing while the UI claims the new one. Restarting from the
        // current sentence is what the reader expects, and it also rebuilds the
        // chunk table (which is engine specific: the system engine has none).
        let changed = settings.engine != self.settings.engine
            || (settings.engine != .system && settings.remote != self.settings.remote)
            || settings.rate != self.settings.rate
            || settings.pitch != self.settings.pitch
            || settings.voiceIdentifier != self.settings.voiceIdentifier
        guard changed else {
            self.settings = settings
            return
        }

        let wasPlaying = isActive
        stop()
        self.settings = settings
        rebuildChunks()
        guard wasPlaying else { return }
        play()
    }

    /// Replaces the queue. When `autoPlay` is true reading starts immediately.
    func load(sentences newSentences: [String], startAt index: Int = 0, autoPlay: Bool = true) {
        stop()
        sentences = newSentences
        offsetsCache = nil
        currentIndex = min(max(index, 0), max(newSentences.count - 1, 0))
        rebuildChunks()
        guard autoPlay, !newSentences.isEmpty else { return }
        play()
    }

    func play() {
        guard sentences.indices.contains(currentIndex) else { return }
        lastError = nil

        if settings.engine == .system {
            playSystem()
        } else {
            playRemote()
        }
    }

    func pause() {
        switch settings.engine {
        case .system:
            guard synthesizer.isSpeaking else { return }
            synthesizer.pauseSpeaking(at: .immediate)
        case .edge, .openAICompatible:
            if isPreparing {
                // Still waiting on the network: there is nothing to pause, so
                // cancel the fetch instead of leaving a spinner that never
                // resolves into audio.
                loadTask?.cancel()
                loadTask = nil
                isPreparing = false
            } else if let player = audioPlayer, player.isPlaying {
                player.pause()
            } else {
                return
            }
            progressTimer?.invalidate()
            progressTimer = nil
        }
        isPaused = true
        isSpeaking = false
    }

    func toggle() {
        // `isActive` also covers the paused state, so it cannot be the test
        // here: a paused reader has to resume, not pause again.
        if isSpeaking || isPreparing { pause() } else { play() }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        loadTask?.cancel()
        loadTask = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        isSpeaking = false
        isPaused = false
        isPreparing = false
        prefetched = nil
        deactivateSession()
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
        return sentenceOffsets(in: text)[index]
    }

    /// Character offset of the end of every sentence, computed in one forward
    /// pass.
    ///
    /// Searching per call was both O(n²) and wrong for repeated sentences: a
    /// chapter full of "他说。" would map every occurrence to the first one, so
    /// the saved reading position jumped backwards. Walking forward from the
    /// previous match keeps the offsets monotonic and does the work once.
    private func sentenceOffsets(in text: String) -> [Int] {
        if let cache = offsetsCache, cache.text == text { return cache.offsets }

        var offsets: [Int] = []
        offsets.reserveCapacity(sentences.count)
        var cursor = text.startIndex
        for sentence in sentences {
            if let range = text.range(of: sentence, range: cursor..<text.endIndex) {
                offsets.append(text.distance(from: text.startIndex, to: range.upperBound))
                cursor = range.upperBound
            } else {
                // The text no longer contains this sentence verbatim (AI
                // cleanup, for instance). Keep the position monotonic instead
                // of snapping back to the top.
                offsets.append(offsets.last ?? 0)
            }
        }
        offsetsCache = (text, offsets)
        return offsets
    }

    // MARK: - Chunking

    private func rebuildChunks() {
        guard settings.engine != .system else {
            chunks = []
            return
        }
        chunks = SpeechChunker.sentenceChunks(sentences)
    }

    private func chunkIndex(containing sentence: Int) -> Int? {
        chunks.firstIndex { sentence >= $0.sentenceStart && sentence < $0.sentenceStart + $0.sentenceCount }
    }

    /// Everything that changes the produced audio belongs in the key, so
    /// switching voice or speed never replays the previous recording.
    private func cacheKey(for chunk: SpeechChunk) -> String {
        SpeechCacheKey.key(
            text: chunk.text,
            engine: settings.engine,
            voice: voiceDescriptor,
            rate: settings.rate,
            pitch: settings.pitch
        )
    }

    private var voiceDescriptor: String {
        switch settings.engine {
        case .system:
            return settings.voiceIdentifier ?? "system-default"
        case .edge:
            return settings.remote.edgeVoice
        case .openAICompatible:
            // Two servers with the same voice name do not sound alike, so the
            // endpoint and model are part of the identity.
            return [
                settings.remote.baseURL,
                settings.remote.model,
                settings.remote.voice,
            ].joined(separator: "@")
        }
    }

    // MARK: - Remote playback

    private func playRemote() {
        if let player = audioPlayer, isPaused {
            player.play()
            isPaused = false
            isSpeaking = true
            startProgressTimer()
            return
        }
        guard let index = chunkIndex(containing: currentIndex) else { return }
        startChunk(at: index, fromSentence: currentIndex)
    }

    private func startChunk(at index: Int, fromSentence sentence: Int) {
        guard chunks.indices.contains(index) else {
            finishQueue()
            return
        }
        loadTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil

        currentChunkIndex = index
        currentChunkBoundaries = []
        isPreparing = true
        isSpeaking = false
        isPaused = false
        onSentenceChange?(sentence)

        let chunk = chunks[index]
        let settings = self.settings
        let key = cacheKey(for: chunk)
        let store = self.store

        // A prefetched chunk starts instantly; play it without a second trip
        // through the network or the disk cache.
        if let cached = prefetched, cached.key == key {
            prefetched = nil
            beginPlayback(audio: cached.audio, boundaries: cached.boundaries, chunkIndex: index)
            return
        }
        prefetched = nil

        loadTask = Task { [weak self] in
            do {
                let audio = try await Self.audio(
                    for: chunk,
                    key: key,
                    settings: settings,
                    store: store
                )
                guard !Task.isCancelled else { return }
                self?.beginPlayback(
                    audio: audio.audio,
                    boundaries: audio.boundaries,
                    chunkIndex: index
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    /// Fetches the audio for one chunk, from the cache when possible.
    ///
    /// `nonisolated` and free of controller state so it can run off the main
    /// actor: the network call and the disk write are the slow parts.
    nonisolated static func audio(
        for chunk: SpeechChunk,
        key: String,
        settings: TTSSettings,
        store: LibraryStore?
    ) async throws -> (audio: Data, boundaries: [EdgeSentenceBoundary]) {
        if settings.cacheEnabled, let store, let cached = await store.loadSpeech(key: key) {
            await store.touchSpeech(key: key)
            // Timings survive the round trip, so a second listen highlights
            // exactly like the first instead of falling back to an estimate.
            let boundaries = await store.loadSpeechBoundaries(key: key)
            return (cached, boundaries)
        }

        var audio: Data
        var boundaries: [EdgeSentenceBoundary] = []

        switch settings.engine {
        case .system:
            throw EdgeTTSError.noAudio
        case .edge:
            let result = try await EdgeTTSClient().synthesize(
                text: chunk.text,
                voice: settings.remote.edgeVoice,
                rate: settings.rate,
                pitch: settings.pitch,
                volume: settings.volume,
                proxy: settings.proxy
            )
            audio = result.audio
            boundaries = result.boundaries
        case .openAICompatible:
            audio = try await OpenAISpeechClient().synthesize(
                text: chunk.text,
                settings: settings.remote,
                rate: settings.rate,
                proxy: settings.proxy
            )
        }

        if settings.cacheEnabled, let store, !audio.isEmpty {
            let limit = Int64(settings.cacheLimitMB) * 1024 * 1024
            await store.saveSpeech(audio, key: key, limitBytes: limit)
            await store.saveSpeechBoundaries(boundaries, key: key)
        }
        return (audio, boundaries)
    }

    private func beginPlayback(
        audio: Data,
        boundaries: [EdgeSentenceBoundary],
        chunkIndex index: Int
    ) {
        guard chunks.indices.contains(index) else { return }
        activateSession()

        do {
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            player.volume = Float(max(0, min(settings.volume, 1)))
            player.prepareToPlay()
            guard player.play() else { throw EdgeTTSError.noAudio }
            audioPlayer = player
            currentChunkBoundaries = boundaries
            isPreparing = false
            isSpeaking = true
            isPaused = false
            startProgressTimer()
            prefetchNextChunk(after: index)
        } catch {
            fail(error)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        // 0.1s is well under a sentence, so the highlight never lags audibly,
        // and it is cheap enough to run for hours.
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHighlight() }
        }
    }

    private func updateHighlight() {
        guard let player = audioPlayer, player.isPlaying else { return }
        let elapsed = player.currentTime
        let chunk = chunks.indices.contains(currentChunkIndex) ? chunks[currentChunkIndex] : nil
        guard let chunk else { return }

        let offsetInChunk = sentenceOffset(at: elapsed, chunk: chunk, duration: player.duration)
        let sentence = min(chunk.sentenceStart + offsetInChunk,
                           chunk.sentenceStart + chunk.sentenceCount - 1)
        guard sentence != currentIndex else { return }
        currentIndex = sentence
        onSentenceChange?(sentence)
    }

    /// Where inside a chunk a given sentence begins, for seeking on "previous".
    private func seekTime(forSentence sentence: Int, chunk: SpeechChunk, duration: Double) -> Double {
        let offset = max(0, min(sentence - chunk.sentenceStart, chunk.sentenceCount - 1))
        if currentChunkBoundaries.count == chunk.sentenceCount, currentChunkBoundaries.indices.contains(offset) {
            return currentChunkBoundaries[offset].start
        }
        // No timings from the engine: split the duration by character count,
        // which is close enough for a re-read of the previous sentence.
        let texts = Array(sentences[chunk.sentenceStart..<(chunk.sentenceStart + chunk.sentenceCount)])
        let total = max(texts.reduce(0) { $0 + $1.count }, 1)
        let before = texts.prefix(offset).reduce(0) { $0 + $1.count }
        return duration * Double(before) / Double(total)
    }

    /// Which sentence of the chunk is playing at `elapsed` seconds.
    ///
    /// Uses the service's own timings when they line up one-to-one with the
    /// sentences that were sent; otherwise falls back to a character-count
    /// estimate, which is accurate enough for highlighting and works for
    /// engines that report no timings at all.
    private func sentenceOffset(at elapsed: Double, chunk: SpeechChunk, duration: Double) -> Int {
        if currentChunkBoundaries.count == chunk.sentenceCount, !currentChunkBoundaries.isEmpty {
            var result = 0
            for (index, boundary) in currentChunkBoundaries.enumerated() where boundary.start <= elapsed {
                result = index
            }
            return result
        }

        let total = max(duration, 0.01)
        let progress = max(0, min(1, elapsed / total))
        let texts = Array(sentences[chunk.sentenceStart..<(chunk.sentenceStart + chunk.sentenceCount)])
        let totalCharacters = max(texts.reduce(0) { $0 + $1.count }, 1)
        var accumulated = 0
        for (index, text) in texts.enumerated() {
            accumulated += text.count
            if Double(accumulated) / Double(totalCharacters) >= progress { return index }
        }
        return max(texts.count - 1, 0)
    }

    /// Synthesizes the following chunk while the current one plays, so a
    /// chapter does not stutter between groups of sentences.
    private func prefetchNextChunk(after index: Int) {
        let next = index + 1
        guard chunks.indices.contains(next), prefetchTasks[next] == nil else { return }

        let chunk = chunks[next]
        let key = cacheKey(for: chunk)
        let settings = self.settings
        let store = self.store

        prefetchTasks[next] = Task { [weak self] in
            defer { Task { @MainActor in self?.prefetchTasks[next] = nil } }
            guard !Task.isCancelled else { return }
            guard let result = try? await Self.audio(for: chunk, key: key, settings: settings, store: store) else {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only keep it if the reader has not moved on in the meantime;
                // otherwise this would pin a chunk that may never be played.
                guard let self, self.currentChunkIndex + 1 == next else { return }
                self.prefetched = (key: key, audio: result.audio, boundaries: result.boundaries)
            }
        }
    }

    private func advanceRemote() {
        let next = currentChunkIndex + 1
        guard chunks.indices.contains(next) else {
            finishQueue()
            return
        }
        startChunk(at: next, fromSentence: chunks[next].sentenceStart)
    }

    private func fail(_ error: Error) {
        isSpeaking = false
        isPaused = false
        isPreparing = false
        progressTimer?.invalidate()
        progressTimer = nil
        lastError = error.localizedDescription
        onError?(error.localizedDescription)
    }

    // MARK: - System playback

    private func playSystem() {
        guard sentences.indices.contains(currentIndex) else { return }
        if isPaused, synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isSpeaking = true
            return
        }
        activateSession()
        speakCurrentSystem()
    }

    private func restartCurrent() {
        let wasPlaying = isSpeaking || isPaused || isPreparing

        if settings.engine == .system {
            synthesizer.stopSpeaking(at: .immediate)
            isPaused = false
            guard wasPlaying else {
                onSentenceChange?(currentIndex)
                return
            }
            activateSession()
            speakCurrentSystem()
        } else {
            loadTask?.cancel()
            progressTimer?.invalidate()
            progressTimer = nil
            isPaused = false
            guard wasPlaying else {
                audioPlayer?.stop()
                audioPlayer = nil
                onSentenceChange?(currentIndex)
                return
            }
            guard let index = chunkIndex(containing: currentIndex) else { return }
            // Inside the chunk already loaded there is no need to refetch: seek
            // instead, which keeps "next sentence" instant.
            if index == currentChunkIndex, let player = audioPlayer {
                player.currentTime = seekTime(forSentence: currentIndex, chunk: chunks[index], duration: player.duration)
                player.play()
                isSpeaking = true
                startProgressTimer()
            } else {
                startChunk(at: index, fromSentence: currentIndex)
            }
        }
    }

    private func speakCurrentSystem() {
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

    private func advanceSystem() {
        guard isSpeaking else { return }
        if currentIndex + 1 < sentences.count {
            currentIndex += 1
            speakCurrentSystem()
        } else {
            finishQueue()
        }
    }

    private func finishQueue() {
        isSpeaking = false
        isPaused = false
        isPreparing = false
        progressTimer?.invalidate()
        progressTimer = nil
        onFinished?()
    }

    // MARK: - Audio session

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
            guard self.settings.engine == .system, self.isSpeaking else { return }
            self.advanceSystem()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Cancellation happens on stop/jump; state is already handled there.
            if self.isSpeaking && self.settings.engine == .system {
                self.isSpeaking = false
            }
        }
    }
}

extension SpeechController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.settings.engine != .system, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.advanceRemote()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.fail(error ?? EdgeTTSError.noAudio)
        }
    }
}
#endif
