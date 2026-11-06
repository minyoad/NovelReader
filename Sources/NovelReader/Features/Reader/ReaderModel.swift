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
    /// Whether the chrome (top bar, bottom bar) is showing.
    ///
    /// Starts hidden: the reader opens full screen with just the chapter title,
    /// and a tap brings the rest in. Playback does not bring it back either —
    /// the Lock Screen and headphones drive it while the page stays clean.
    @Published var showBars = false
    @Published var currentSentenceIndex = 0
    @Published var aiTask: AIPrompt.ChapterTask?
    @Published var aiProgress: Double?
    @Published var showSettings = false
    @Published var showChapterList = false
    @Published var pendingOffset: Int = 0
    /// How far the reader is into the current chapter, 0...1.
    ///
    /// The bottom bar used to show only chapter position, which says nothing
    /// about how much of a 40-page chapter is left. `PagedReader` owns the page
    /// count and writes it here as pages turn.
    @Published var chapterProgress: Double = 0
    /// Where to land when the chapter loaded next opens at its end.
    ///
    /// Pages do not exist until the chapter has been laid out, so a swipe that
    /// leaves a chapter backwards can only say "the end"; the reader converts
    /// it into a page once it has the layout, and the chapter's last page is
    /// what the swipe showed moving in.
    @Published var pendingEndOfChapter = false
    @Published var toast: (text: String, isError: Bool)?
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
    /// Chapters handed over by a preview screen.
    ///
    /// Non-nil means this reader is a trial read of a book that is not on the
    /// shelf yet; see `ReadingMode` for what that forbids.
    private let previewChapters: [Chapter]?

    /// What this session may write back to the library.
    let mode: ReadingMode
    private var prefetchTask: Task<Void, Never>?
    /// Cleans the next chapters ahead of the reader so a page turn never waits
    /// on the model. Separate from `prefetchTask`: that one only downloads.
    private var cleanAheadTask: Task<Void, Never>?
    /// Fetches the next chapter's text early, for the speech look-ahead.
    private var nextChapterPrefetchTask: Task<Void, Never>?
    /// Keeps `ReaderModel` translating the speech controller's state changes.
    ///
    /// `speech` is a separate `ObservableObject`, and views only observe
    /// `ReaderModel`. Without this bridge, stopping playback changed nothing the
    /// views could see: the sentence highlight stayed painted on the page even
    /// though the queue was gone, because no published property of the model
    /// changed and SwiftUI never redrew.
    private var speechObserver: AnyCancellable?

    init(book: Book, app: AppModel, startIndex: Int? = nil, previewChapters: [Chapter]? = nil) {
        self.book = book
        self.app = app
        self.currentIndex = startIndex ?? book.progress.chapterIndex
        self.pendingOffset = startIndex == nil ? book.progress.characterOffset : 0
        self.startIndexOverride = startIndex
        self.previewChapters = previewChapters
        self.mode = ReadingMode(previewChapters: previewChapters)

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
            // Through `showToast`, not a bare assignment: that is what arms the
            // timer that hides it again. Assigning `toast` directly left the
            // banner on screen for good, with no way to dismiss it.
            self?.showToast(message, isError: true)
        }
        // The controller synthesizes the next chapter's opening chunk before
        // the current one ends, which needs that chapter's text — and only the
        // reader has the table of contents.
        speech.nextChapterSentences = { [weak self] in
            guard let self, let text = self.nextChapterText else { return nil }
            // Refuse a leftover copy: the reader may have skipped chapters
            // since it was fetched, and playing the wrong opening over the
            // right chapter title is worse than one normal gap.
            guard self.chapters.indices.contains(self.currentIndex + 1),
                  self.nextChapterTextURL == self.chapters[self.currentIndex + 1].url else {
                return nil
            }
            // Same body text the next chapter will be paginated from, so the
            // chunk synthesized here is byte-identical to the one playback
            // will ask for — otherwise the look-ahead misses its cache entry.
            let body = PaginatedText(rawText: text).body
            return TextProcessing.sentences(fromBody: body)
        }
        speech.onNextChapterReady = { [weak self] in
            // Audio for the next chapter exists now, so the boundary no longer
            // needs the short-lived background allowance.
            self?.speech.releaseSessionWhenIdle()
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

    /// The book's position as a whole, for the label beside the chapter bar.
    ///
    /// Chapters differ wildly in length, so counting chapters alone misreports
    /// how much of the book is behind the reader. The current chapter counts
    /// as far as `chapterProgress` has taken it.
    var bookProgressFraction: Double {
        guard !chapters.isEmpty else { return 0 }
        let finished = Double(currentIndex)
        return (finished + chapterProgress) / Double(chapters.count)
    }

    /// Same value as a whole percentage, always rounding up from zero so a
    /// freshly opened book does not announce "0%" while text is on screen.
    var bookProgressPercent: Int {
        guard bookProgressFraction > 0 else { return 0 }
        return max(1, min(100, Int((bookProgressFraction * 100).rounded())))
    }

    var isSpeaking: Bool { speech.isActive }

    // MARK: - Loading
    func start() async {
        guard chapters.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            chapters = try await loadChapterList()
            let preferred = startIndexOverride ?? book.progress.chapterIndex
            let startIndex = min(max(preferred, 0), max(chapters.count - 1, 0))
            currentIndex = startIndex
            await loadChapter(at: startIndex, offset: pendingOffset, autoplaySpeech: false)
            await refreshCacheStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The table of contents for this reader.
    ///
    /// A preview already fetched it, and it must not be written into the
    /// library: the book is not on the shelf, so `chapters/<id>-toc.json` would
    /// be a file nothing ever reads or cleans up.
    private func loadChapterList() async throws -> [Chapter] {
        if let previewChapters { return previewChapters }
        return try await app.chapters(for: book)
    }

    func reloadChapters() async {
        guard mode.cachesChapters else {
            showToast("试读时不能刷新目录，先加入书架")
            return
        }
        do {
            let fetched = try await app.chapters(for: book, forceReload: true)
            chapters = fetched
            currentIndex = min(currentIndex, max(fetched.count - 1, 0))
            app.showBanner("目录已更新（\(fetched.count) 章）", isError: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadChapter(
        at index: Int,
        offset: Int = 0,
        autoplaySpeech: Bool = false,
        opensAtEnd: Bool = false
    ) async {
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
        pendingEndOfChapter = opensAtEnd
        isLoading = true
        errorMessage = nil

        let chapter = chapters[index]
        do {
            let fetched = try await app.chapterContentPrepared(
                book: book,
                chapter: chapter,
                cache: mode.cachesChapters,
                // Reading aloud starts from the text it is given, so the ads
                // have to be gone before playback; silent reading shows the
                // chapter at once and relies on the cleaning-ahead queue.
                synchronous: shouldSpeak
            )
            content = fetched
            // A trial read has no shelf entry to record progress against: the
            // book may never be added, and writing here would also bump
            // `lastReadAt` and so change which book the app resumes.
            if mode.recordsProgress {
                app.updateProgress(bookID: book.id, chapterIndex: index, chapterTitle: chapter.title, characterOffset: offset)
            }
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
            // Nothing to prefetch for a trial read: those downloads would be
            // cached files belonging to a book that is not on the shelf.
            if mode.cachesChapters {
                schedulePrefetch()
                scheduleCleanAhead()
            }
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

    /// Text of the chapter after the current one, once it is known.
    ///
    /// Kept in memory so `SpeechController` can read it synchronously while
    /// looking ahead. Filled by `prefetchNextChapterForSpeech()`, which runs as
    /// soon as a chapter starts loading — a chapter takes minutes to listen to,
    /// so the text is there long before the look-ahead asks for it.
    private var nextChapterText: String?
    /// The chapter `nextChapterText` belongs to, so a stale copy left over from
    /// a skipped chapter is never handed to the speech controller.
    private var nextChapterTextURL: String?

    /// Downloads the next few chapters in the background so a dropped
    /// connection does not stop the reader mid-chapter.
    ///
    /// Two jobs, in this order:
    ///
    /// 1. The chapter after this one, always, regardless of `prefetchCount`.
    ///    Reading aloud crosses that boundary by itself, and hitting an
    ///    uncached chapter there meant a full page download inside the
    ///    silent gap between chapters. The setting controls how much extra
    ///    is kept, not whether the one that is about to be needed is.
    /// 2. The remaining `prefetchCount` chapters ahead.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        prefetchNextChapterForSpeech()

        let count = app.settings.cache.prefetchCount
        guard !chapters.isEmpty else { return }

        let index = currentIndex
        let book = self.book
        let chapters = self.chapters
        let app = self.app

        prefetchTask = Task { [weak self] in
            let cachedURLs = await app.store.cachedChapterURLs(bookID: book.id)
            let cachedIndices = Set(chapters.enumerated()
                .filter { cachedURLs.contains($0.element.url) }
                .map { $0.offset })
            var plan = count > 0
                ? CachePlanner.prefetchIndices(
                    currentIndex: index,
                    chapterCount: chapters.count,
                    prefetchCount: count,
                    alreadyCached: cachedIndices
                )
                : []
            // The next chapter is already being fetched above; do not queue it
            // twice, and do not let the plan skip it just because `count` is 0.
            let immediate = index + 1
            plan.removeAll { $0 == immediate }
            if chapters.indices.contains(immediate), !cachedIndices.contains(immediate) {
                plan.insert(immediate, at: 0)
            }
            for chapterIndex in plan {
                if Task.isCancelled { return }
                await app.cacheChapter(book: book, chapter: chapters[chapterIndex])
                await MainActor.run { self?.cachedChapterCount += 1 }
            }
            await self?.evictIfNeeded()
        }
    }

    /// Fetches the next chapter's text for the speech look-ahead, and caches
    /// the chapter for reading at the same time.
    ///
    /// Runs alongside `schedulePrefetch`'s download rather than before it: the
    /// two want the same bytes, and whichever gets there first wins while the
    /// other finds the file already cached.
    private func prefetchNextChapterForSpeech() {
        nextChapterPrefetchTask?.cancel()
        let target = currentIndex + 1
        guard chapters.indices.contains(target) else {
            nextChapterText = nil
            nextChapterTextURL = nil
            return
        }
        let chapter = chapters[target]
        let book = self.book
        let app = self.app
        let cache = mode.cachesChapters

        nextChapterPrefetchTask = Task { [weak self] in
            let fetched: ChapterContent?
            do {
                fetched = try await app.chapterContent(book: book, chapter: chapter, cache: cache)
            } catch {
                return
            }
            guard let text = fetched?.text, !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.currentIndex + 1 == target else { return }
                self.nextChapterText = text
                self.nextChapterTextURL = chapter.url
            }
        }
    }

    func refreshCacheStats() async {
        // Everything cache-related is keyed by book id, and a trial read has no
        // shelf entry to key it on: reporting counts here would show whatever
        // happens to share that id, which is nothing.
        guard mode.cachesChapters else {
            cachedChapterCount = 0
            return
        }
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

    /// Cleans the next few chapters while the reader is on this one.
    ///
    /// This is the whole reason the automatic option is usable: the model call
    /// happens during the minutes spent reading, so the next chapter is already
    /// clean on disk when the page turn happens. Runs after `schedulePrefetch`
    /// starts downloading, and is cancelled whenever the chapter changes — the
    /// queue is rebuilt from the new position.
    private func scheduleCleanAhead() {
        cleanAheadTask?.cancel()
        let ahead = app.settings.aiCleanAhead
        guard app.settings.aiAutoClean, app.settings.ai.isUsable, ahead > 0 else { return }
        let book = self.book
        let chapters = self.chapters
        let index = currentIndex
        let app = self.app
        cleanAheadTask = Task { [weak self] in
            await app.cleanAhead(
                book: book,
                chapters: chapters,
                from: index,
                ahead: ahead
            ) { cachedIndex in
                guard let self, self.currentIndex == index, cachedIndex > index else { return }
                self.cachedChapterCount += 1
            }
        }
    }

    /// Downloads every chapter of the book; used by the "缓存全本" action.
    func cacheWholeBook() async {
        guard !isCachingBook, !chapters.isEmpty else { return }
        guard mode.cachesChapters else {
            showToast("试读时不能缓存，先加入书架")
            return
        }
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
        if mode.cachesChapters {
            await app.store.deleteContent(bookID: book.id, chapterURL: chapter.url)
        }
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

    /// Arrives at the previous chapter's last page, for a swipe out of the top
    /// of a chapter. Paged readers pass this; `goPreviousChapter` opens at the
    /// beginning, which is what chapter lists and the bottom bar want.
    func goPreviousChapterBackwards(autoPlaySpeech: Bool = false) async {
        guard currentIndex - 1 >= 0 else {
            app.showBanner("已经是第一章了", isError: false)
            return
        }
        await loadChapter(at: currentIndex - 1, autoplaySpeech: autoPlaySpeech, opensAtEnd: true)
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
        guard mode.canSwitchSource else {
            showToast("试读时不能换源，先加入书架")
            return
        }
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
        guard mode.canSwitchSource else {
            showToast("试读时不能换源，先加入书架")
            return
        }
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
        // Sentences are split from the same paragraph-segmented text the pages
        // were laid out from, and positions are read in that same coordinate
        // space. `TextProcessing.sentences(from:)` normalizes on its own rules,
        // which do not match `PaginatedText`'s — every paragraph that opened
        // with an indent shifted the two apart, and the drift grew with the
        // distance into the chapter. One text, one set of offsets, no
        // translation.
        let paginated = PaginatedText(rawText: text)
        let body = paginated.body
        // Everything from here on works in `body` coordinates — the same text
        // the pages were laid out from. `pendingOffset` is an offset into the
        // raw chapter; translating it once here is the only conversion needed.
        // Splitting sentences from the raw text instead left two normalizations
        // disagreeing at every indented paragraph, which is what made reading
        // start earlier and earlier into the page.
        let sentences = TextProcessing.sentences(fromBody: body)
        let startIndex = speech.sentenceIndex(
            forCharactersBefore: paginated.bodyOffset(forOriginal: pendingOffset),
            in: body,
            sentences: sentences
        )
        speech.configure(app.settings.tts)
        speech.attach(store: app.store)
        if app.settings.tts.engine.needsNetwork && !app.settings.tts.isRemoteUsable {
            showToast(
                app.settings.tts.engine == .edge
                    ? "还没有选择 Edge 音色，请到设置里选一个"
                    : "自定义朗读接口还不完整，请到设置里填写地址和模型",
                isError: true
            )
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

    /// Gives the Lock Screen the book being read.
    ///
    /// Called on every chapter load too: the system UI outlives the reader, and
    /// a stale title there is worse than none.
    private func describeForSystemPlayback() {
        speech.describe(
            bookTitle: book.name,
            author: book.author,
            artworkURL: book.coverURL
        )
    }

    func toggleSpeech() {
        // Only a paused or playing queue has something to resume. `hasContent`
        // alone is not enough: `stop()` leaves `sentences` in place, so after
        // a finished or exited reading it is still true — and resuming from
        // where the old reading stopped ignores whatever page the reader has
        // turned to since. Picking up from the visible page is what pressing
        // read again should mean.
        if speech.isActive, speech.hasContent {
            speech.toggle()
        } else {
            startSpeaking()
        }
    }

    func stopSpeaking() {
        speech.stop()
        // Exiting playback returns to the clean page. The bar was only there
        // because the reader opened it to press pause/exit; leaving it up would
        // mean the page stays half covered after the audio is gone.
        showBars = false
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
        guard mode.recordsProgress else { return }
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
            // A trial read keeps the cleanup in memory only: writing it would
            // create a chapter file for a book the library does not know about.
            if mode.cachesChapters {
                app.persistContent(cleaned, for: book)
            }
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
        if mode.cachesChapters {
            app.persistContent(restored, for: book)
        }
        showToast("已还原为站点原文")
    }

    // MARK: - Progress

    /// Stops background work when the reader closes, so prefetch does not keep
    /// hitting the network after the user leaves the book.
    func stopBackgroundWork() {
        prefetchTask?.cancel()
        prefetchTask = nil
        cleanAheadTask?.cancel()
        cleanAheadTask = nil
        nextChapterPrefetchTask?.cancel()
        nextChapterPrefetchTask = nil
        nextChapterText = nil
        nextChapterTextURL = nil
        speech.stop()
    }

    /// Shows a transient message. `isError` colours it as a failure; either way
    /// it disappears on its own *and* on a tap, since a message that stays
    /// forever has no way out.
    private func showToast(_ text: String, isError: Bool = false) {
        let entry = (text: text, isError: isError)
        toast = entry
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            // Only clear our own message, not one that replaced it meanwhile.
            if self.toast?.text == text { self.toast = nil }
        }
    }

    /// Dismisses the passthrough message — used by the banner's tap.
    func dismissToast() {
        toast = nil
    }

    func saveProgress(characterOffset: Int = 0) {
        // A trial read records nothing: there is no shelf entry, and progress
        // written against a book that was never added is invisible forever.
        guard mode.recordsProgress else { return }
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
