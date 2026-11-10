#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 18)]

    /// The book opened by tapping a card. Reading is what a tap means on a
    /// shelf: the reader is where one continues, and the detail page is a
    /// detour on the way there. It is still reachable from the long-press
    /// menu as 「书籍信息」.
    @State private var readingBook: Book?
    /// The book whose detail page was asked for from the long-press menu.
    @State private var detailBook: Book?

    var body: some View {
        NavigationStack {
            Group {
                if app.books.isEmpty {
                    EmptyStateView(
                        title: "书架是空的",
                        message: "去「找书」搜索，或者导入书源后开始阅读。",
                        systemImage: "books.vertical"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 22) {
                            // One warning strip for every book whose source
                            // went away, above the grid rather than on each
                            // card: the fix is the same for all of them, and
                            // a badge on twelve covers is twelve things to
                            // read instead of one sentence.
                            if let warning = missingSourceWarning {
                                MissingSourceBanner(text: warning)
                                    .padding(.bottom, 4)
                            }

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
                                    Button(role: .destructive) {
                                        app.removeFromShelf(book)
                                    } label: {
                                        Label("移出书架", systemImage: "trash")
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
                    NavigationLink {
                        ReadingNowView()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .disabled(app.books.isEmpty)
                }
            }
        }
        // Full screen rather than a push: closing the reader returns to the
        // shelf, not to a detail page the user never asked to see.
        .fullScreenCover(item: $readingBook) { book in
            ReaderView(book: book, app: app)
        }
    }

    private var sortedBooks: [Book] {
        app.books.sorted { lhs, rhs in
            let lhsDate = lhs.lastReadAt ?? lhs.addedAt
            let rhsDate = rhs.lastReadAt ?? rhs.addedAt
            return lhsDate > rhsDate
        }
    }

    /// A sentence naming the books whose source a refresh removed, or nil.
    ///
    /// Books keep their `sourceName` after the source is gone, so they stay on
    /// the shelf looking normal while tapping one opens a reader with no rules.
    /// Naming them here is what turns that into a message the reader can act on
    /// — the fix is 长按 → 书籍信息 → 换源.
    private var missingSourceWarning: String? {
        let broken = app.booksWithMissingSource
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
    let book: Book
    /// Whether this book's source is gone. Drawn as a badge so the card
    /// itself says "this one cannot be read right now", not just the banner.
    var missingSource: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CoverImage(url: book.coverURL, width: 100, height: 138, cornerRadius: 8)
                if book.progress.isStarted {
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
                .lineLimit(1)
            Text(book.author.isEmpty ? book.sourceName : book.author)
                .font(.caption2)
                .foregroundStyle(missingSource ? .orange : .secondary)
                .lineLimit(1)
        }
    }

    private var progressLabel: String {
        if book.progress.chapterTitle.isEmpty {
            return "读至 \(book.progress.chapterIndex + 1) 章"
        }
        return book.progress.chapterTitle
    }
}

/// A tiny "continue reading" entry point that skips the detail screen.
private struct ReadingNowView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let book = ReadingRecents.mostRecent(in: app.books) {
            BookDetailView(book: book, autoOpenReader: true)
        } else {
            EmptyStateView(title: "还没有阅读记录", message: "先从书架打开一本书。", systemImage: "book")
        }
    }
}
#endif
