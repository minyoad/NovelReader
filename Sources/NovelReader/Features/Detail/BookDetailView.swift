#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct BookDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let book: Book
    var autoOpenReader: Bool = false

    @State private var chapters: [Chapter] = []
    @State private var isLoadingChapters = false
    @State private var showReader = false
    @State private var showTOC = false
    @State private var startIndex: Int?
    @State private var openReaderAfterTOC = false
    @State private var intro: String = ""
    @State private var aiIntroBusy = false
    @State private var errorMessage: String?
    @State private var otherSources: [SearchResult] = []
    @State private var didLoadOtherSources = false
    @State private var switchingSource = false
    @State private var isCaching = false
    @State private var cacheProgress: Double?

    private var currentBook: Book {
        app.books.first { $0.id == book.id } ?? book
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !intro.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("简介").font(.headline)
                            Spacer()
                            Button {
                                Task { await summarizeIntro() }
                            } label: {
                                if aiIntroBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("AI 整理", systemImage: "sparkles")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(aiIntroBusy || !app.settings.ai.isUsable)
                        }
                        Text(intro)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                actions

                if !chapters.isEmpty {
                    chapterPreview
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .navigationTitle(currentBook.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            intro = currentBook.intro
            await loadChapters()
            if autoOpenReader, !showReader {
                showReader = true
            }
        }
        .onAppear {
            // Load candidate sources once the detail page settles; searching
            // every source is too slow to do in `.task` alongside the TOC.
            Task { await loadOtherSourcesIfNeeded() }
        }
        .sheet(isPresented: $showTOC, onDismiss: {
            if openReaderAfterTOC {
                openReaderAfterTOC = false
                showReader = true
            }
        }) {
            ChapterListView(book: currentBook, chapters: chapters, currentIndex: currentBook.progress.chapterIndex) { index in
                startIndex = index
                openReaderAfterTOC = true
                showTOC = false
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showReader) {
            ReaderView(book: currentBook, app: app, startIndex: startIndex)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(url: currentBook.coverURL, width: 104, height: 142, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(currentBook.name).font(.title3.weight(.semibold))
                Text(currentBook.author.isEmpty ? "佚名" : currentBook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !currentBook.kind.isEmpty {
                    Text(currentBook.kind)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                if !currentBook.lastChapterTitle.isEmpty {
                    Text("最新：\(currentBook.lastChapterTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("来源：\(currentBook.sourceName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                startIndex = currentBook.progress.chapterIndex
                showReader = true
            } label: {
                Label(
                    currentBook.progress.isStarted ? "继续阅读 · \(currentBook.progress.chapterTitle)" : "开始阅读",
                    systemImage: "book.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(chapters.isEmpty)

            HStack(spacing: 10) {
                Button {
                    showTOC = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(chapters.isEmpty)

                Button {
                    Task { await refreshChapters() }
                } label: {
                    if isLoadingChapters {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label("更新目录", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingChapters || app.source(for: currentBook) == nil)
            }

            HStack(spacing: 10) {
                Menu {
                    if otherSources.isEmpty {
                        Button("正在查找…") {}
                            .disabled(true)
                    } else {
                        ForEach(otherSources) { source in
                            Button(source.name) {
                                Task { await switchSource(to: source) }
                            }
                        }
                    }
                } label: {
                    if switchingSource {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("切换中…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("换源", systemImage: "arrow.left.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(switchingSource || otherSources.isEmpty)

                Button {
                    Task { await cacheWholeBook() }
                } label: {
                    Label("缓存全本", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isCaching || chapters.isEmpty)
            }

            if let cacheProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: cacheProgress)
                    Text("正在缓存全本…\(Int(cacheProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chapterPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目录").font(.headline)
                Text("\(chapters.count) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部") { showTOC = true }
                    .font(.footnote)
            }
            ForEach(Array(chapters.prefix(5).enumerated()), id: \.element.id) { offset, chapter in
                Button {
                    startIndex = offset
                    showReader = true
                } label: {
                    HStack {
                        Text(chapter.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        if chapter.isVIP {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func loadChapters() async {
        isLoadingChapters = true
        defer { isLoadingChapters = false }
        do {
            chapters = try await app.chapters(for: currentBook)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChapters() async {
        isLoadingChapters = true
        defer { isLoadingChapters = false }
        do {
            chapters = try await app.chapters(for: currentBook, forceReload: true)
            app.showBanner("目录已更新（\(chapters.count) 章）", isError: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func summarizeIntro() async {
        aiIntroBusy = true
        defer { aiIntroBusy = false }
        if let summary = await app.summarizeIntro(currentBook) {
            intro = TextProcessing.normalizeParagraphs(summary)
        } else {
            errorMessage = AIError.notConfigured.localizedDescription
        }
    }

    /// Loads candidate sources lazily: the menu is opened rarely, and searching
    /// every source is slow.
    private func loadOtherSourcesIfNeeded() async {
        guard !didLoadOtherSources, !switchingSource else { return }
        didLoadOtherSources = true
        otherSources = await app.alternatives(for: currentBook)
        if otherSources.isEmpty {
            app.showBanner("没有找到其他收录这本书的书源", isError: false)
        }
    }

    private func switchSource(to candidate: SearchResult) async {
        switchingSource = true
        defer { switchingSource = false }
        guard await app.canReadChapter(candidate, of: currentBook, chapterTitle: chapters[safe: currentBook.progress.chapterIndex]?.title) else {
            errorMessage = "这个书源读不到当前章节，没有切换"
            return
        }
        do {
            let updated = try await app.switchSource(of: currentBook, to: candidate)
            chapters = try await app.chapters(for: updated)
            otherSources = []
            app.showBanner("已切换到「\(updated.sourceName)」", isError: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cacheWholeBook() async {
        guard !isCaching else { return }
        isCaching = true
        cacheProgress = 0
        defer {
            isCaching = false
            cacheProgress = nil
        }

        let book = currentBook
        let list = chapters
        let cached = await app.store.cachedChapterURLs(bookID: book.id)
        let cachedIndices = Set(list.enumerated().filter { cached.contains($0.element.url) }.map { $0.offset })
        let plan = CachePlanner.missingForWholeBook(
            chapterCount: list.count,
            alreadyCached: cachedIndices,
            excluding: book.progress.chapterIndex
        )
        guard !plan.isEmpty else {
            app.showBanner("全本已缓存", isError: false)
            return
        }

        var done = 0
        var failed = 0
        for index in plan {
            if Task.isCancelled { break }
            if await app.cacheChapter(book: book, chapter: list[index]) {
                done += 1
            } else {
                failed += 1
            }
            cacheProgress = Double(done + failed) / Double(plan.count)
        }
        app.showBanner(
            failed == 0 ? "全本缓存完成（\(done) 章）" : "缓存完成，\(failed) 章失败",
            isError: failed > 0
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ChapterListView: View {
    let book: Book
    let chapters: [Chapter]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var ascending = true
    /// Set once the list has been scrolled to its anchor, so the user's own
    /// scrolling is never overridden afterwards.
    @State private var didScrollToAnchor = false

    private var filtered: [(Int, Chapter)] {
        let indexed = Array(chapters.enumerated()).map { ($0.offset, $0.element) }
        let searched = query.isEmpty ? indexed : indexed.filter { $0.1.title.localizedCaseInsensitiveContains(query) }
        return ascending ? searched : searched.reversed()
    }

    /// Row to anchor on when the sheet opens, or when the list is re-filtered.
    ///
    /// A book can run to thousands of chapters, so opening the table of contents
    /// at the top and expecting the reader to hunt for the current one is not
    /// usable.
    ///
    /// Three cases, in order:
    ///  * a search is active — anchor on the first match, which is what the
    ///    search was for;
    ///  * otherwise anchor on the chapter being read;
    ///  * the current chapter is filtered out — nothing sensible to anchor on.
    private var anchorRowID: String? {
        if !query.isEmpty {
            return filtered.first?.1.id
        }
        guard chapters.indices.contains(currentIndex) else { return nil }
        let id = chapters[currentIndex].id
        return filtered.contains { $0.1.id == id } ? id : nil
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(filtered, id: \.1.id) { index, chapter in
                    row(index: index, chapter: chapter)
                        .listRowBackground(
                            index == currentIndex
                                ? Palette.accent.opacity(0.12)
                                : Color.clear
                        )
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "搜索章节")
                .navigationTitle("目录 · \(chapters.count) 章")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            ascending.toggle()
                        } label: {
                            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        }
                    }
                }
                .onAppear {
                    scrollToAnchor(proxy: proxy)
                }
                .onChange(of: query) { _, _ in
                    didScrollToAnchor = false
                    scrollToAnchor(proxy: proxy)
                }
                .onChange(of: ascending) { _, _ in
                    didScrollToAnchor = false
                    scrollToAnchor(proxy: proxy)
                }
            }
        }
    }

    /// Scrolls to the anchor row.
    ///
    /// `scrollTo` is a no-op when the target row has not been laid out yet, which
    /// is exactly the state during `onAppear` in a sheet — the list has not
    /// measured its rows at that point. A single deferred call therefore lands
    /// nowhere on a large table of contents. Instead, retry a few times with a
    /// short gap, and stop as soon as the row can actually be found.
    ///
    /// Retrying is safe because the call is idempotent; it either moves to the
    /// anchor or does nothing.
    private func scrollToAnchor(proxy: ScrollViewProxy) {
        // One retry task per list configuration; `onAppear` can fire more than
        // once (keyboard dismissal, detent change) and overlapping tasks would
        // fight over the scroll position.
        guard !didScrollToAnchor, let id = anchorRowID else { return }
        didScrollToAnchor = true

        Task { @MainActor in
            // Four short attempts (~110ms total): enough for a sheet's list to
            // measure its rows, short enough that it never fights a user who
            // starts scrolling immediately.
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func row(index: Int, chapter: Chapter) -> some View {
        let isCurrent = index == currentIndex
        Button {
            onSelect(index)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                if isCurrent {
                    // A bar marker in addition to colour: colour alone is easy
                    // to miss when the row happens to be near the top of the
                    // list as it lands.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.accent)
                        .frame(width: 3)
                }
                Text(chapter.title)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Palette.accent : .primary)
                Spacer()
                if isCurrent {
                    Text("在读")
                        .font(.caption2)
                        .foregroundStyle(Palette.accent)
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
