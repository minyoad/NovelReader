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
}

struct ChapterListView: View {
    let book: Book
    let chapters: [Chapter]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var ascending = true

    private var filtered: [(Int, Chapter)] {
        let indexed = Array(chapters.enumerated()).map { ($0.offset, $0.element) }
        let searched = query.isEmpty ? indexed : indexed.filter { $0.1.title.localizedCaseInsensitiveContains(query) }
        return ascending ? searched : searched.reversed()
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.1.id) { index, chapter in
                Button {
                    onSelect(index)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(index == currentIndex ? Palette.accent : .primary)
                        Spacer()
                        if index == currentIndex {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
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
        }
    }
}
#endif
