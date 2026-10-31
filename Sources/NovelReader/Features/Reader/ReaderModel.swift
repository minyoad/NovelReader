#if canImport(SwiftUI)
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
    private let startIndexOverride: Int?

    init(book: Book, app: AppModel, startIndex: Int? = nil) {
        self.book = book
        self.app = app
        self.currentIndex = startIndex ?? book.progress.chapterIndex
        self.pendingOffset = startIndex == nil ? book.progress.characterOffset : 0
        self.startIndexOverride = startIndex

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
    }

    var currentChapter: Chapter? {
        guard chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    var progressFraction: Double {
        guard !chapters.isEmpty else { return 0 }
        return Double(currentIndex + 1) / Double(chapters.count)
    }

    var isSpeaking: Bool { speech.isSpeaking }

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
        let shouldSpeak = speech.isSpeaking
        speech.stop()
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
            if shouldSpeak || autoplaySpeech {
                startSpeaking()
            }
        } catch {
            content = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func goNextChapter() async {
        guard currentIndex + 1 < chapters.count else {
            app.showBanner("已经是最后一章了", isError: false)
            return
        }
        await loadChapter(at: currentIndex + 1)
    }

    func goPreviousChapter() async {
        guard currentIndex - 1 >= 0 else {
            app.showBanner("已经是第一章了", isError: false)
            return
        }
        await loadChapter(at: currentIndex - 1)
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
            showToast("已切换到「\(updated.sourceName)」")
            await reopenWithUpdatedBook()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func startSpeaking() {
        guard let text = content?.text, !text.isEmpty else { return }
        let sentences = TextProcessing.sentences(from: text)
        let startIndex = speech.sentenceIndex(forCharactersBefore: pendingOffset, in: text)
        speech.configure(app.settings.tts)
        speech.load(sentences: sentences, startAt: min(startIndex, max(sentences.count - 1, 0)), autoPlay: true)
        currentSentenceIndex = speech.currentIndex
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
        guard app.settings.tts.autoNextChapter else { return }
        if currentIndex + 1 < chapters.count {
            await loadChapter(at: currentIndex + 1, autoplaySpeech: true)
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
        let wasSpeaking = speech.isSpeaking
        if wasSpeaking { speech.stop() }

        do {
            let cleaned = try await app.aiClean(content, task: task) { [weak self] progress in
                Task { @MainActor in self?.aiProgress = progress }
            }
            self.content = cleaned
            app.persistContent(cleaned, for: book)
            app.showBanner("AI 整理完成：\(task.title)", isError: false)
            showToast("AI 整理完成：\(task.title)")
            if pendingOffset == 0 { pendingOffset = 0 }
        } catch {
            errorMessage = error.localizedDescription
        }
        aiTask = nil
        aiProgress = nil
    }

    // MARK: - Progress

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
