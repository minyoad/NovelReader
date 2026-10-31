#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 18)]

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
                            ForEach(sortedBooks) { book in
                                NavigationLink {
                                    BookDetailView(book: book)
                                } label: {
                                    BookCard(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        app.removeFromShelf(book)
                                    } label: {
                                        Label("移出书架", systemImage: "trash")
                                    }
                                    Button {
                                        app.updateProgress(bookID: book.id, chapterIndex: 0, chapterTitle: "", characterOffset: 0)
                                    } label: {
                                        Label("标记为未读", systemImage: "arrow.counterclockwise")
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("书架")
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
    }

    private var sortedBooks: [Book] {
        app.books.sorted { lhs, rhs in
            let lhsDate = lhs.lastReadAt ?? lhs.addedAt
            let rhsDate = rhs.lastReadAt ?? rhs.addedAt
            return lhsDate > rhsDate
        }
    }
}

private struct BookCard: View {
    let book: Book

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
            Text(book.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Text(book.author.isEmpty ? book.sourceName : book.author)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
