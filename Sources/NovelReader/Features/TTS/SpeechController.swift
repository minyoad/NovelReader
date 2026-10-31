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
    /// Called when the system asks to move between chapters — headphone
    /// buttons, Control Center, CarPlay. Bubbled up to the reader because only
    /// it knows the table of contents.
    var onNextChapterRequest: (() -> Void)?
    var onPreviousChapterRequest: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var settings = TTSSettings()
    private var didConfigureSession = false

    /// Lock Screen / Control Center / headset integration.
    let nowPlaying = NowPlayingCenter()
    /// Set by the reader so the system UI can show what is being read.
    private var trackInfo = NowPlayingCenter.Track.empty
    /// Turns the sentence list into the position and duration the system
    /// progress bar needs. Rebuilt with the queue, so it always matches
    /// `sentences`.
    private var timeline = SpeechTimeline(sentences: [])

    // MARK: Remote playback

    private var store: LibraryStore?
    private var chunks: [SpeechChunk] = []
    private var currentChunkIndex = 0
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    private var currentChunkBoundaries: [EdgeSentenceBoundary] = []
    /// Keeps the app alive across the silent gap while the next chunk or
    /// chapter is still being fetched with the screen locked.
    private let grace = BackgroundGrace()
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
        nowPlaying.onTogglePlayPause = { [weak self] in self?.toggle() }
        nowPlaying.onPlay = { [weak self] in self?.resumeOrPlay() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onNextChapter = { [weak self] in self?.onNextChapterRequest?() }
        nowPlaying.onPreviousChapter = { [weak self] in self?.onPreviousChapterRequest?() }
        nowPlaying.onNextSentence = { [weak self] in self?.next(resuming: false) }
        nowPlaying.onPreviousSentence = { [weak self] in self?.previous(resuming: false) }
        nowPlaying.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
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
        stop(keepingSession: wasPlaying)
        self.settings = settings
        rebuildChunks()
        guard wasPlaying else { return }
        play()
    }

    /// Replaces the queue. When `autoPlay` is true reading starts immediately.
    ///
    /// The audio session stays alive whenever a queue is loaded, not just while
    /// audio is playing. That is how a paused player is expected to behave — the
    /// Lock Screen card and its buttons remain available — and a chapter change
    /// made from the background must not drop the session even for a moment, or
    /// iOS suspends the app before the next chapter's audio has been fetched.
    func load(sentences newSentences: [String], startAt index: Int = 0, autoPlay: Bool = true) {
        stop(keepingSession: !newSentences.isEmpty)
        sentences = newSentences
        offsetsCache = nil
        currentIndex = min(max(index, 0), max(newSentences.count - 1, 0))
        rebuildChunks()
        rebuildTimeline()
        // Publish the new chapter's opening position right away: the previous
        // chapter's progress would otherwise sit on the Lock Screen until the
        // first audio of this one has been fetched.
        publishNowPlaying()
        guard !newSentences.isEmpty else { return }
        guard autoPlay else {
            // Loaded but silent: report "paused" so the reader keeps showing its
            // controls and the system keeps the chapter as a paused track the
            // user can resume, rather than pretending nothing is loaded.
            isPaused = true
            publishNowPlaying()
            return
        }
        play()
    }

    /// Names what is being read in the system UI.
    ///
    /// Provides the book and chapter, not the sentence: the Lock Screen is a
    /// glance away from the app, and "第三章 风起" is what identifies the
    /// reading session, while the sentence would change every few seconds.
    func describe(bookTitle: String, author: String, chapterTitle: String, artworkURL: String?) {
        trackInfo = NowPlayingCenter.Track(
            title: chapterTitle,
            artist: author.isEmpty ? bookTitle : "\(bookTitle) · \(author)",
            album: bookTitle,
            artworkURL: artworkURL
        )
        // Registering here too, not only in `play()`: a chapter can be loaded
        // paused, and the card should still be visible and controllable.
        nowPlaying.activate()
        nowPlaying.setTrack(trackInfo)
        publishNowPlaying()
    }

    func play() {
        guard sentences.indices.contains(currentIndex) else { return }
        lastError = nil
        // Session first: iOS only treats an app as the Now Playing source once
        // its session is an active, non-mixable playback session. Publishing
        // before that is silently dropped.
        activateSession()
        nowPlaying.activate()

        if settings.engine == .system {
            playSystem()
        } else {
            playRemote()
        }
        publishNowPlaying()
    }

    /// Play button semantics from the system: resume when there is a paused
    /// queue, start from the current sentence otherwise.
    private func resumeOrPlay() {
        // A fetch already in flight is not something to restart: doing so would
        // cancel the request and begin the same download again.
        guard !isPreparing else { return }
        if !isPlaying { play() }
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
        grace.end()
        publishNowPlaying()
    }

    func toggle() {
        // `isSpeaking` covers the paused state too, so the test has to be
        // "audio is coming out right now": a paused reader has to resume, and a
        // playing one has to pause. `isPreparing` pauses the pending fetch.
        if isSpeaking || isPreparing { pause() } else { play() }
    }

    /// Stops playback.
    ///
    /// `keepingSession` exists for chapter changes: the audio session has to
    /// stay active across the gap while the next chapter is fetched, otherwise
    /// iOS suspends the app in the background and the fetch never completes —
    /// which is exactly when hands-free listening matters.
    func stop(keepingSession: Bool = false) {
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
        // The system UI is cleared only when reading ends for good; a chapter
        // switch keeps it up and the pending play() refreshes the progress.
        if !keepingSession {
            grace.end()
            nowPlaying.deactivate()
            deactivateSession()
        }
    }

    func next(resuming: Bool = true) {
        guard currentIndex + 1 < sentences.count else {
            // While paused there is no audio to finish, and ending the queue
            // would auto-advance to the next chapter — which must not start
            // talking just because a skip button was pressed.
            if isPaused { return }
            finishQueue()
            return
        }
        step(to: currentIndex + 1, resuming: resuming)
    }

    func previous(resuming: Bool = true) {
        step(to: max(currentIndex - 1, 0), resuming: resuming)
    }

    func jump(to index: Int, resuming: Bool = true) {
        step(to: index, resuming: resuming)
    }

    /// Moves to a sentence, optionally keeping a paused reader paused.
    ///
    /// `resuming` is false for the Lock Screen controls, where a skip or a
    /// scrub is a position change rather than a command to start talking; the
    /// in-app buttons keep their old behaviour of continuing playback.
    private func step(to index: Int, resuming: Bool) {
        guard sentences.indices.contains(index) else { return }
        if isPaused && !resuming {
            park(at: index)
        } else {
            currentIndex = index
            restartCurrent()
        }
    }

    /// Moves to a sentence without producing audio, leaving the queue paused.
    private func park(at index: Int) {
        synthesizer.stopSpeaking(at: .immediate)
        loadTask?.cancel()
        loadTask = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        currentIndex = index
        isPaused = true
        isSpeaking = false
        isPreparing = false
        // The session is deliberately kept: a paused reader still has to answer
        // the Lock Screen, and an app whose session went away gets suspended
        // and stops receiving those commands.
        onSentenceChange?(index)
        publishNowPlaying()
    }

    /// Turns a position from the Lock Screen scrubber into a sentence.
    ///
    /// The chapter has no single duration — it is synthesized in chunks — so
    /// the total comes from `SpeechTimeline`. That keeps the scrubber
    /// proportional to the text, which is what it is used for: jumping to a
    /// rough place, then letting the reader adjust by sentence.
    private func seek(to seconds: Double) {
        guard !sentences.isEmpty else { return }
        jump(to: timeline.sentenceIndex(atSeconds: seconds, rate: settings.rate), resuming: false)
    }

    /// Pushes the current state to the Lock Screen.
    ///
    /// Skipped while no chapter has been named yet: an empty title would show up
    /// as a blank Now Playing card, which looks like a bug.
    private func publishNowPlaying() {
        guard !trackInfo.title.isEmpty else { return }
        nowPlaying.update(
            elapsed: timeline.elapsed(before: currentIndex, atRate: settings.rate),
            duration: timeline.duration(atRate: settings.rate),
            isPlaying: isPlaying
        )
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

    /// Rebuilds the mapping used for the system progress bar.
    private func rebuildTimeline() {
        timeline = SpeechTimeline(sentences: sentences)
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
            // The session may have been deactivated by an interruption or a
            // route change, in which case the player is silent until it is
            // reactivated.
            activateSession()
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
        grace.end()

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
            // Audio is now actually coming out, so publish the playing state:
            // the pre-play publish said "paused", and nothing else would correct
            // it until the first sentence change.
            publishNowPlaying()
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
        publishNowPlaying()
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
        grace.end()
        lastError = error.localizedDescription
        publishNowPlaying()
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
        grace.end()
        onSentenceChange?(currentIndex)
        publishNowPlaying()
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
        grace.end()
        publishNowPlaying()
        onFinished?()
    }

    // MARK: - Audio session

    /// Configures a **non-mixable** long-form playback session.
    ///
    /// The options matter more than they look: `.duckOthers` implies
    /// `.mixWithOthers`, and a mixing session is never promoted to the system's
    /// Now Playing source. That single option was why the Lock Screen and the
    /// Now Playing widget stayed empty while audio played fine — the info
    /// dictionary was published, but the system had no reason to show it.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.longFormAudio` is what tells the system this is a podcast-like
            // session rather than a sound effect: it is what earns the Lock
            // Screen card and the remote command routing. It is also the default
            // policy, but asking for it explicitly costs nothing.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
        } catch {
            // The policy overload can be rejected on some configurations; the
            // category itself is what matters, so retry without it rather than
            // silently ending up in the default, mixable session — that is
            // exactly what keeps the Now Playing card away.
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        do {
            try session.setActive(true)
            didConfigureSession = true
        } catch {
            // Reading still works without a properly configured session; it just
            // may not continue in the background.
            didConfigureSession = false
        }
    }

    private func deactivateSession() {
        guard didConfigureSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        didConfigureSession = false
    }

    /// Winds down after the last sentence without tearing down Now Playing.
    ///
    /// The session is deliberately left active. Media apps keep theirs for a
    /// paused player, and deactivating it is what makes the Lock Screen card
    /// vanish even though the info was published — the exact symptom of "audio
    /// stopped and the widget went blank". Only the background allowance is
    /// returned, since nothing more is being fetched.
    func releaseSessionWhenIdle() {
        grace.end()
    }

    /// Holds the app awake while the next chapter is fetched with the screen
    /// locked.
    ///
    /// Audio keeps a background app alive only while something is playing, and
    /// a chapter boundary is a silent gap: the download, the sentence split and
    /// the first chunk's synthesis can easily outlast the few seconds iOS
    /// waits before suspending. Called by the reader, released as soon as audio
    /// starts or playback stops.
    func beginBackgroundFetch() {
        grace.begin(reason: "继续朗读")
    }

    // MARK: - Audio interruptions

    /// Pauses for a phone call or another app taking the session, and resumes
    /// afterwards only if the system says it is appropriate.
    ///
    /// Resuming unconditionally would start talking over whatever interrupted
    /// it — a call in particular — so the interruption options are respected.
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            guard isActive else { return }
            wasPlayingBeforeInterruption = isPlaying
            pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume), isPaused else { return }
            wasPlayingBeforeInterruption = false
            play()
        @unknown default:
            break
        }
    }

    /// Pausing when the headphones are unplugged.
    ///
    /// Without this a chapter keeps reading out loud through the phone speaker,
    /// which is the worst possible outcome of taking an earbud out.
    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        guard reason == .oldDeviceUnavailable, isActive else { return }
        pause()
    }

    /// Remembers whether audio was actually coming out, so an interrupted pause
    /// does not turn into an unexpected resume of something already paused.
    private var wasPlayingBeforeInterruption = false

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
