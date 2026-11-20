#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 18)]

    /// The book opened by tapping a card. Reading is what a tap means on a
    /// shelf: the reader is where one continues, and the detail page is a
    /// detour on the way there. It is still reachable from the long-press
    /// menu as 「书籍信息」.
    @State private var readingBook: Book?
    /// The book whose detail page was asked for from the long-press menu.
    @State private var detailBook: Book?
    @State private var purificationBook: Book?
    @State private var pendingRemoval: Book?
    @State private var recentProgress: ShelfReadingProgress?

    var body: some View {
        NavigationStack {
            Group {
                if sortedBooks.isEmpty {
                    ContentUnavailableView {
                        Label("书架是空的", systemImage: "books.vertical")
                    } description: {
                        Text("找一本喜欢的书，开始阅读。")
                    } actions: {
                        Button("搜索书籍") { app.isSearching = true }.buttonStyle(.borderedProminent)
                        NavigationLink("添加书源") { SourcesView() }.buttonStyle(.bordered)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let recent = ReadingRecents.mostRecent(in: sortedBooks) {
                                continueReading(recent)
                            }
                            if let warning = missingSourceWarning {
                                MissingSourceBanner(text: warning)
                            }
                            Text("我的书架 · \(sortedBooks.count) 本").font(.headline)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                ForEach(sortedBooks) { book in
                                    Button {
                                        readingBook = book
                                    } label: {
                                        BookCard(book: book, missingSource: app.source(for: book) == nil)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            detailBook = book
                                        } label: {
                                            Label("书籍信息", systemImage: "info.circle")
                                        }
                                        Button {
                                            app.updateProgress(bookID: book.id, chapterIndex: 0, chapterTitle: "", characterOffset: 0)
                                        } label: {
                                            Label("标记为未读", systemImage: "arrow.counterclockwise")
                                        }
                                        Button {
                                            purificationBook = book
                                        } label: {
                                            Label("文本净化", systemImage: "line.3.horizontal.decrease.circle")
                                        }
                                        Button(role: .destructive) {
                                            stageRemoval(book)
                                        } label: {
                                            Label("移出书架", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("书架")
            .navigationDestination(item: $detailBook) { book in
                BookDetailView(book: book)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.isSearching = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索书籍")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let removed = pendingRemoval {
                    HStack {
                        Text("已移出《\(removed.name)》").font(.footnote).lineLimit(2)
                        Spacer()
                        Button("撤销") { pendingRemoval = nil }.fontWeight(.semibold)
                    }
                    .padding().background(.regularMaterial)
                    .accessibilityElement(children: .contain)
                }
            }
            .task(id: pendingRemoval?.id) {
                guard let id = pendingRemoval?.id else { return }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard !Task.isCancelled, pendingRemoval?.id == id else { return }
                commitRemoval()
            }
            .onDisappear { commitRemoval() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { commitRemoval() }
            }
        }
        // Full screen rather than a push: closing the reader returns to the
        // shelf, not to a detail page the user never asked to see.
        .sheet(item: $purificationBook) { book in
            NavigationStack { TextPurificationView(book: book) }
        }
        .fullScreenCover(item: $readingBook) { book in
            ReaderView(book: book, app: app)
        }
    }

    private var sortedBooks: [Book] {
        app.books.filter { $0.id != pendingRemoval?.id }.sorted { lhs, rhs in
            let lhsDate = lhs.lastReadAt ?? lhs.addedAt
            let rhsDate = rhs.lastReadAt ?? rhs.addedAt
            return lhsDate > rhsDate
        }
    }

    private func continueReading(_ book: Book) -> some View {
        Button { readingBook = book } label: {
            HStack(spacing: 14) {
                CoverImage(url: book.coverURL, width: 58, height: 80, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 6) {
                    Text("继续阅读").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                    Text(book.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Text(book.progress.chapterTitle.isEmpty ? "第 \(book.progress.chapterIndex + 1) 章" : book.progress.chapterTitle)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let progress = recentProgress {
                        Text(progress.label).font(.caption).foregroundStyle(.secondary)
                        if let value = progress.fraction { ProgressView(value: value) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "book.fill").font(.title3).foregroundStyle(Palette.accent)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
        .task(id: "\(book.hashValue)-\(app.purificationSettings(for: book.id).hashValue)") {
            recentProgress = nil
            let chapters = await app.store.loadChapters(bookID: book.id) ?? []
            var length: Int?
            if chapters.indices.contains(book.progress.chapterIndex),
               let content = await app.store.loadContent(bookID: book.id, chapterURL: chapters[book.progress.chapterIndex].url) {
                length = app.purifiedContent(content, bookID: book.id).text.count
            }
            guard !Task.isCancelled else { return }
            recentProgress = ShelfReadingProgress(progress: book.progress, chapterCount: chapters.count, textLength: length)
        }
    }

    private func stageRemoval(_ book: Book) {
        commitRemoval()
        pendingRemoval = book
    }

    private func commitRemoval() {
        guard let book = pendingRemoval else { return }
        pendingRemoval = nil
        // Stage only the visible removal during the undo window. The original
        // record and chapter cache remain intact until this commit.
        app.removeFromShelf(book)
    }

    /// A sentence naming the books whose source a refresh removed, or nil.
    ///
    /// Books keep their `sourceName` after the source is gone, so they stay on
    /// the shelf looking normal while tapping one opens a reader with no rules.
    /// Naming them here is what turns that into a message the reader can act on
    /// — the fix is 长按 → 书籍信息 → 换源.
    private var missingSourceWarning: String? {
        let broken = app.booksWithMissingSource.filter { $0.id != pendingRemoval?.id }
        guard !broken.isEmpty else { return nil }
        let names = broken.prefix(3).map(\.name).joined(separator: "、")
        let suffix = broken.count > 3 ? " 等 \(broken.count) 本" : ""
        return "「\(names)」\(suffix)的书源已被移除，长按书名 → 书籍信息可以换源。"
    }
}

/// The shelf's source warning strip.
private struct MissingSourceBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct BookCard: View {
    @EnvironmentObject private var app: AppModel
    @State private var progress = ShelfReadingProgress(progress: ReadingProgress(), chapterCount: 0)
    let book: Book
    /// Whether this book's source is gone. Drawn as a badge so the card
    /// itself says "this one cannot be read right now", not just the banner.
    var missingSource: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CoverImage(url: book.coverURL, width: 100, height: 138, cornerRadius: 8)
                if progress.label != "未读" {
                    Text(progressLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if missingSource {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.orange, in: Circle())
                        .padding(5)
                }
            }
            Text(book.name)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .frame(minHeight: 36, alignment: .topLeading)
            Text(book.author.isEmpty ? book.sourceName : book.author)
                .font(.caption2)
                .foregroundStyle(missingSource ? .orange : .secondary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.label).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fraction = progress.fraction { ProgressView(value: fraction).tint(Palette.accent) }
            }
        }
        .task(id: "\(book.hashValue)-\(app.purificationSettings(for: book.id).hashValue)") {
            let chapters = await app.store.loadChapters(bookID: book.id) ?? []
            var length: Int?
            if chapters.indices.contains(book.progress.chapterIndex),
               let content = await app.store.loadContent(bookID: book.id, chapterURL: chapters[book.progress.chapterIndex].url) {
                length = app.purifiedContent(content, bookID: book.id).text.count
            }
            guard !Task.isCancelled else { return }
            progress = ShelfReadingProgress(progress: book.progress, chapterCount: chapters.count, textLength: length)
        }
    }

    private var progressLabel: String {
        if book.progress.chapterTitle.isEmpty {
            return "读至 \(book.progress.chapterIndex + 1) 章"
        }
        return book.progress.chapterTitle
    }
}

#endif
