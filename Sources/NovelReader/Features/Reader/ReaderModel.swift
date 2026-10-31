#if canImport(SwiftUI)
import Combine
import Foundation
import SwiftUI
import NovelKit

@MainActor
final class ReaderModel: ObservableObject {
    /// Updated in place when the reader switches to another source, so chapter
    /// fetches afterwards use the new source instead of the dead one.
    @Published private(set) var book: Book
    private let app: AppModel
    let speech = SpeechController()

    @Published var chapters: [Chapter] = []
    @Published var currentIndex: Int
    @Published var content: ChapterContent?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showBars = true
    @Published var currentSentenceIndex = 0
    @Published var aiTask: AIPrompt.ChapterTask?
    @Published var aiProgress: Double?
    @Published var showSettings = false
    @Published var showChapterList = false
    @Published var pendingOffset: Int = 0
    @Published var toast: String?
    /// Source candidates for the current book, shown in the switch sheet.
    @Published var sourceCandidates: [SearchResult] = []
    @Published var isSearchingSources = false
    @Published var showSourcePicker = false
    /// Index of the candidate being probed, so the sheet can show a spinner.
    @Published var probingSourceID: String?
    @Published var cachedChapterCount = 0
    @Published var isCachingBook = false
    @Published var bookCacheProgress: Double?
    private let startIndexOverride: Int?
    private var prefetchTask: Task<Void, Never>?
    /// Keeps `ReaderModel` translating the speech controller's state changes.
    ///
    /// `speech` is a separate `ObservableObject`, and views only observe
    /// `ReaderModel`. Without this bridge, stopping playback changed nothing the
    /// views could see: the sentence highlight stayed painted on the page even
    /// though the queue was gone, because no published property of the model
    /// changed and SwiftUI never redrew.
    private var speechObserver: AnyCancellable?

    init(book: Book, app: AppModel, startIndex: Int? = nil) {
        self.book = book
        self.app = app
        self.currentIndex = startIndex ?? book.progress.chapterIndex
        self.pendingOffset = startIndex == nil ? book.progress.characterOffset : 0
        self.startIndexOverride = startIndex

        speech.attach(store: app.store)
        speech.configure(app.settings.tts)
        speech.onSentenceChange = { [weak self] index in
            guard let self else { return }
            self.currentSentenceIndex = index
            self.saveProgressFromSpeech()
        }
        speech.onFinished = { [weak self] in
            guard let self else { return }
            Task { await self.advanceAfterSpeech() }
        }
        speech.onError = { [weak self] message in
            guard let self else { return }
            self.toast = message
        }
        // Headphone buttons move between chapters, so they need the table of
        // contents, which only the reader has.
        speech.onNextChapterRequest = { [weak self] in
            guard let self else { return }
            // `isActive` also covers paused and still-loading, so a press while
            // paused moves on and keeps reading. An idle reader ignores it:
            // there is no reading session for these buttons to move.
            guard self.isSpeaking else { return }
            Task { await self.goNextChapter(autoPlaySpeech: true) }
        }
        speech.onPreviousChapterRequest = { [weak self] in
            guard let self else { return }
            guard self.isSpeaking else { return }
            Task { await self.goPreviousChapter(autoPlaySpeech: true) }
        }

        // Re-publish the speech state through this model so the page redraws
        // when playback starts or stops. `objectWillChange` of the controller is
        // not observed by any view; this is the bridge that makes "no speaking"
        // actually clear the highlight.
        speechObserver = speech.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var currentChapter: Chapter? {
        guard chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    var progressFraction: Double {
        guard !chapters.isEmpty else { return 0 }
        return Double(currentIndex + 1) / Double(chapters.count)
    }

    var isSpeaking: Bool { speech.isActive }

    // MARK: - Loading
    func start() async {
        guard chapters.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            chapters = try await app.chapters(for: book)
            let preferred = startIndexOverride ?? book.progress.chapterIndex
            let startIndex = min(max(preferred, 0), max(chapters.count - 1, 0))
            currentIndex = startIndex
            await loadChapter(at: startIndex, offset: pendingOffset, autoplaySpeech: false)
            await refreshCacheStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadChapters() async {
        do {
            let fetched = try await app.chapters(for: book, forceReload: true)
            chapters = fetched
            currentIndex = min(currentIndex, max(fetched.count - 1, 0))
            app.showBanner("目录已更新（\(fetched.count) 章）", isError: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadChapter(at index: Int, offset: Int = 0, autoplaySpeech: Bool = false) async {
        guard chapters.indices.contains(index) else { return }
        // Reading across a chapter boundary has to keep the audio session: iOS
        // suspends a backgrounded app the moment the session goes inactive, and
        // the next chapter would never finish downloading. `autoplaySpeech`
        // covers the auto-advance case, where the queue has already drained so
        // `isActive` is false even though reading is about to continue.
        let shouldSpeak = speech.isActive || autoplaySpeech
        // A paused listener stays paused: switching chapter is a position
        // change, not a command to start talking. This matches what the system
        // does with a paused track when you press next.
        let wasPaused = speech.isPaused
        speech.stop(keepingSession: shouldSpeak)
        // The session keeps the app alive only once audio is playing again; the
        // fetch before that needs its own short-lived allowance.
        if shouldSpeak { speech.beginBackgroundFetch() }
        currentIndex = index
        currentSentenceIndex = 0
        pendingOffset = offset
        isLoading = true
        errorMessage = nil

        let chapter = chapters[index]
        do {
            let fetched = try await app.chapterContent(book: book, chapter: chapter)
            content = fetched
            app.updateProgress(bookID: book.id, chapterIndex: index, chapterTitle: chapter.title, characterOffset: offset)
            if shouldSpeak {
                // Name the chapter before playback starts, so the Lock Screen
                // never shows the previous one even for a moment.
                describeForSystemPlayback()
                // A paused listener stays paused: with `autoPlay: false` the
                // chapter is loaded and named but no audio is fetched, which is
                // both correct and cheaper than starting and immediately
                // pausing.
                startSpeaking(autoPlay: !wasPaused)
            }
            schedulePrefetch()
        } catch {
            content = nil
            errorMessage = error.localizedDescription
            // Nothing is going to play, so release the session kept alive for
            // the chapter that failed to load.
            speech.stop()
        }
        isLoading = false
        await refreshCacheStats()
    }

    // MARK: - Offline cache

    /// Downloads the next few chapters in the background so a dropped
    /// connection does not stop the reader mid-chapter.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let count = app.settings.cache.prefetchCount
        guard count > 0, !chapters.isEmpty else { return }

        let index = currentIndex
        let book = self.book
        let chapters = self.chapters
        let app = self.app

        prefetchTask = Task { [weak self] in
            let cachedURLs = await app.store.cachedChapterURLs(bookID: book.id)
            let cachedIndices = Set(chapters.enumerated()
                .filter { cachedURLs.contains($0.element.url) }
                .map { $0.offset })
            let plan = CachePlanner.prefetchIndices(
                currentIndex: index,
                chapterCount: chapters.count,
                prefetchCount: count,
                alreadyCached: cachedIndices
            )
            for chapterIndex in plan {
                if Task.isCancelled { return }
                await app.cacheChapter(book: book, chapter: chapters[chapterIndex])
                await MainActor.run { self?.cachedChapterCount += 1 }
            }
            await self?.evictIfNeeded()
        }
    }

    func refreshCacheStats() async {
        cachedChapterCount = await app.store.cachedChapterCount(bookID: book.id)
    }

    /// Trims the oldest cached bodies once the book exceeds its configured cap.
    private func evictIfNeeded() async {
        let limit = app.settings.cache.maxCachedChaptersPerBook
        guard limit > 0 else { return }
        let chapters = self.chapters
        let bookID = book.id
        let cachedURLs = await app.store.cachedChapterURLs(bookID: bookID)
        let cachedIndices = chapters.enumerated()
            .filter { cachedURLs.contains($0.element.url) }
            .map { $0.offset }
        let drop = CachePlanner.evictionCandidates(
            cachedChapterIndices: cachedIndices,
            currentIndex: currentIndex,
            limit: limit
        )
        for index in drop where chapters.indices.contains(index) {
            await app.store.deleteContent(bookID: bookID, chapterURL: chapters[index].url)
        }
        await refreshCacheStats()
    }

    /// Downloads every chapter of the book; used by the "缓存全本" action.
    func cacheWholeBook() async {
        guard !isCachingBook, !chapters.isEmpty else { return }
        isCachingBook = true
        bookCacheProgress = 0
        defer {
            isCachingBook = false
            bookCacheProgress = nil
        }

        let book = self.book
        let chapters = self.chapters
        let app = self.app
        let cachedURLs = await app.store.cachedChapterURLs(bookID: book.id)
        let cachedIndices = Set(chapters.enumerated()
            .filter { cachedURLs.contains($0.element.url) }
            .map { $0.offset })
        let plan = CachePlanner.missingForWholeBook(
            chapterCount: chapters.count,
            alreadyCached: cachedIndices,
            excluding: currentIndex
        )
        guard !plan.isEmpty else {
            showToast("全本已缓存")
            return
        }

        var done = 0
        var failures = 0
        for index in plan {
            if Task.isCancelled { break }
            let ok = await app.cacheChapter(book: book, chapter: chapters[index])
            if ok {
                done += 1
            } else {
                failures += 1
            }
            bookCacheProgress = Double(done + failures) / Double(plan.count)
            await refreshCacheStats()
        }
        showToast(failures == 0 ? "全本缓存完成（\(done) 章）" : "缓存完成，\(failures) 章失败")
    }

    /// Clears every cached body for this book.
    func clearCache() async {
        await app.store.clearChapterCache(bookID: book.id)
        await refreshCacheStats()
        showToast("本书缓存已清理")
    }

    /// Re-downloads the current chapter, discarding any cached copy.
    func redownloadChapter() async {
        guard let chapter = currentChapter else { return }
        await app.store.deleteContent(bookID: book.id, chapterURL: chapter.url)
        await loadChapter(at: currentIndex, offset: pendingOffset)
    }

    func goNextChapter() async {
        await goNextChapter(autoPlaySpeech: false)
    }

    /// `autoPlaySpeech` is what the system controls need: a headset press while
    /// reading should continue reading the next chapter rather than just moving
    /// the page and going quiet.
    func goNextChapter(autoPlaySpeech: Bool) async {
        guard currentIndex + 1 < chapters.count else {
            app.showBanner("已经是最后一章了", isError: false)
            return
        }
        await loadChapter(at: currentIndex + 1, autoplaySpeech: autoPlaySpeech)
    }

    func goPreviousChapter() async {
        await goPreviousChapter(autoPlaySpeech: false)
    }

    func goPreviousChapter(autoPlaySpeech: Bool) async {
        guard currentIndex - 1 >= 0 else {
            app.showBanner("已经是第一章了", isError: false)
            return
        }
        await loadChapter(at: currentIndex - 1, autoplaySpeech: autoPlaySpeech)
    }

    func retry() async {
        guard let chapter = currentChapter else { return }
        let cached = await app.store.loadContent(bookID: book.id, chapterURL: chapter.url)
        if cached != nil {
            await app.store.deleteContent(bookID: book.id, chapterURL: chapter.url)
        }
        await loadChapter(at: currentIndex)
    }

    // MARK: - Switching sources

    /// Loads every other source that has this book, without probing the body
    /// yet, so the sheet can list candidates quickly.
    func loadSourceCandidates() async {
        guard !isSearchingSources else { return }
        isSearchingSources = true
        defer { isSearchingSources = false }

        let found = await app.alternatives(for: book)
        sourceCandidates = found.filter { $0.sourceID != book.sourceID }
        if sourceCandidates.isEmpty {
            showToast("没有找到其他可用书源")
        }
    }

    /// Verifies a candidate really serves the chapter being read before
    /// switching, and reports the result to the sheet.
    func canRead(_ candidate: SearchResult) async -> Bool {
        guard probingSourceID == nil else { return false }
        probingSourceID = candidate.id
        defer { probingSourceID = nil }
        return await app.canReadChapter(candidate, of: book, chapterTitle: currentChapter?.title)
    }

    /// Looks for the same book on the other enabled sources and returns the
    /// first candidate that can actually serve the current chapter.
    func findBetterSource() async -> SearchResult? {
        let candidates = await app.alternatives(for: book)
        guard !candidates.isEmpty else {
            showToast("没有找到其他可用书源")
            return nil
        }
        let title = currentChapter?.title
        for candidate in candidates {
            if await app.canReadChapter(candidate, of: book, chapterTitle: title) {
                return candidate
            }
        }
        showToast("其他书源也取不到这一章")
        return nil
    }

    /// Applies a source switch, reopens the same chapter and retries loading.
    func applySourceSwitch(_ result: SearchResult) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let updated = try await app.switchSource(of: book, to: result)
            self.book = updated
            sourceCandidates = []
            showToast("已切换到「\(updated.sourceName)」")
            await reopenWithUpdatedBook()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Switch initiated from the picker sheet, where the body was already
    /// probed by `canRead`.
    func switchSource(to candidate: SearchResult) async {
        showSourcePicker = false
        await applySourceSwitch(candidate)
    }

    /// The reader keeps its own `book` copy; reload matching state from the app.
    private func reopenWithUpdatedBook() async {
        let refreshedChapters = (try? await app.chapters(for: book, forceReload: false)) ?? []
        chapters = refreshedChapters
        guard !refreshedChapters.isEmpty else {
            await start()
            return
        }
        // `switchSource` already mapped the old progress onto the new table of
        // contents (by chapter title), so trust the book's index over the stale
        // local one.
        let index = min(max(book.progress.chapterIndex, 0), refreshedChapters.count - 1)
        await loadChapter(at: index)
    }

    // MARK: - Speech

    func startSpeaking(autoPlay: Bool = true) {
        guard let text = content?.text, !text.isEmpty else { return }
        let sentences = TextProcessing.sentences(from: text)
        let startIndex = speech.sentenceIndex(forCharactersBefore: pendingOffset, in: text)
        speech.configure(app.settings.tts)
        speech.attach(store: app.store)
        if app.settings.tts.engine.needsNetwork && !app.settings.tts.isRemoteUsable {
            toast = app.settings.tts.engine == .edge
                ? "还没有选择 Edge 音色，请到设置里选一个"
                : "自定义朗读接口还不完整，请到设置里填写地址和模型"
            return
        }
        // Name the chapter before playback starts, so the Lock Screen never
        // shows the previous chapter even for a moment.
        describeForSystemPlayback()
        speech.load(
            sentences: sentences,
            startAt: min(startIndex, max(sentences.count - 1, 0)),
            autoPlay: autoPlay
        )
        currentSentenceIndex = speech.currentIndex
    }

    /// Gives the Lock Screen the book and chapter being read.
    ///
    /// Called on every chapter load too: the system UI outlives the reader, and
    /// a stale chapter title on the Lock Screen is worse than none.
    private func describeForSystemPlayback() {
        speech.describe(
            bookTitle: book.name,
            author: book.author,
            chapterTitle: currentChapter?.title ?? book.name,
            artworkURL: book.coverURL
        )
    }

    func toggleSpeech() {
        if speech.hasContent {
            speech.toggle()
        } else {
            startSpeaking()
        }
    }

    func stopSpeaking() {
        speech.stop()
    }

    private func advanceAfterSpeech() async {
        guard app.settings.tts.autoNextChapter else {
            // Ended on the last chapter (or with auto-advance off): drop audio
            // focus but keep the Lock Screen entry, so the reader can resume.
            speech.releaseSessionWhenIdle()
            return
        }
        if currentIndex + 1 < chapters.count {
            await loadChapter(at: currentIndex + 1, autoplaySpeech: true)
        } else {
            speech.releaseSessionWhenIdle()
        }
    }

    private func saveProgressFromSpeech() {
        guard let text = content?.text else { return }
        let offset = speech.characterOffset(ofSentence: currentSentenceIndex, in: text)
        app.updateProgress(bookID: book.id, chapterIndex: currentIndex, chapterTitle: currentChapter?.title ?? "", characterOffset: offset)
    }

    // MARK: - AI

    func runAI(task: AIPrompt.ChapterTask) async {
        guard let content else { return }
        guard app.settings.ai.isUsable else {
            errorMessage = AIError.notConfigured.localizedDescription
            return
        }
        aiTask = task
        aiProgress = 0
        let wasSpeaking = speech.isActive
        if wasSpeaking { speech.stop() }

        do {
            let cleaned = try await app.aiClean(
                content,
                task: task,
                format: app.settings.aiOutputFormat
            ) { [weak self] progress in
                Task { @MainActor in self?.aiProgress = progress }
            }
            self.content = cleaned
            app.persistContent(cleaned, for: book)
            app.showBanner("AI 整理完成：\(task.title)", isError: false)
            showToast("AI 整理完成：\(task.title)")
        } catch {
            errorMessage = error.localizedDescription
        }
        aiTask = nil
        aiProgress = nil
    }

    /// Restores the text exactly as downloaded, undoing a previous AI cleanup.
    func restoreOriginalText() async {
        guard let content, content.originalText != nil else {
            showToast("这一章还没有可还原的原文")
            return
        }
        let restored = content.restored()
        self.content = restored
        app.persistContent(restored, for: book)
        showToast("已还原为站点原文")
    }

    // MARK: - Progress

    /// Stops background work when the reader closes, so prefetch does not keep
    /// hitting the network after the user leaves the book.
    func stopBackgroundWork() {
        prefetchTask?.cancel()
        prefetchTask = nil
        speech.stop()
    }

    private func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self.toast == text { self.toast = nil }
        }
    }

    func saveProgress(characterOffset: Int = 0) {
        guard let chapter = currentChapter else { return }
        app.updateProgress(
            bookID: book.id,
            chapterIndex: currentIndex,
            chapterTitle: chapter.title,
            characterOffset: characterOffset
        )
    }
}
#endif
