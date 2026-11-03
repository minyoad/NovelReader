#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Browse a source's own listings instead of guessing at a keyword.
///
/// Not every source has one: legado describes discover pages through
/// `exploreUrl`, and sources that ship without it simply never appear here.
struct ExploreView: View {
    @EnvironmentObject private var app: AppModel

    @State private var selectedCategory: ExploreCategory?
    @State private var destination: Destination?
    @State private var showingSourcePicker = false

    private enum Destination: Hashable {
        case preview(SearchResult)
        case shelf(UUID)

        var id: String {
            switch self {
            case .preview(let result): return "preview|\(result.id)"
            case .shelf(let id): return "shelf|\(id.uuidString)"
            }
        }
    }

    private var sources: [BookSource] { app.explorableSources }

    private var currentSource: BookSource? {
        guard let id = app.exploreSourceID else { return sources.first }
        return sources.first { $0.id == id } ?? sources.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty {
                    EmptyStateView(
                        title: "还没有可发现的来源",
                        message: "去「书源」导入带发现页的书源，就能直接翻分类找书。",
                        systemImage: "safari"
                    )
                } else {
                    content
                }
            }
            .navigationTitle("发现")
            .navigationDestination(item: $destination) { target in
                switch target {
                case .preview(let result):
                    BookPreviewView(result: result)
                case .shelf(let id):
                    if let book = app.books.first(where: { $0.id == id }) {
                        BookDetailView(book: book)
                    } else {
                        EmptyStateView(title: "书不见了", message: "它可能已经被移出书架。", systemImage: "book.closed")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                }
                if sources.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        sourceMenu
                    }
                }
            }
            .task {
                // Opening the tab should land on real books, not an empty
                // screen the reader has to poke before anything happens.
                guard case .idle = app.exploreState,
                      let source = currentSource else { return }
                await app.startExplore(source: source)
                selectedCategory = app.exploreCategories.first
            }
        }
    }

    private var sourceMenu: some View {
        Button {
            showingSourcePicker = true
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
        .accessibilityLabel("切换书源")
        .sheet(isPresented: $showingSourcePicker) {
            ExploreSourcePicker(
                sources: sources,
                current: currentSource,
                onPick: { source in
                    showingSourcePicker = false
                    selectedCategory = nil
                    Task {
                        await app.startExplore(source: source)
                        selectedCategory = app.exploreCategories.first
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            sourceBar
            if app.exploreCategories.count > 1 {
                categoryBar
            }
            resultsArea
        }
    }

    /// Names the source being browsed.
    ///
    /// With dozens of sources the toolbar icon alone does not say which one is
    /// open, and picking the wrong one looks like a parsing bug.
    private var sourceBar: some View {
        Button {
            showingSourcePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                Text(currentSource?.name ?? "选择来源")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// Categories scroll horizontally: sources can list a dozen and a wrapped
    /// grid would push the books themselves off the first screen.
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.exploreCategories) { category in
                    Button {
                        selectedCategory = category
                        Task {
                            guard let source = currentSource else { return }
                            await app.loadExplore(category: category, source: source, page: 1)
                        }
                    } label: {
                        Text(category.name)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(
                                    category == selectedCategory
                                        ? Palette.accent.opacity(0.15)
                                        : Color.secondary.opacity(0.1)
                                )
                            )
                            .foregroundStyle(category == selectedCategory ? Palette.accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        switch app.exploreState {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(title: "没能打开发现页", message: message, systemImage: "exclamationmark.triangle")
        case .loaded(let results, _, let more):
            if results.isEmpty {
                EmptyStateView(
                    title: "这个分类没有书",
                    message: "换一个分类，或者换一个书源试试。",
                    systemImage: "tray"
                )
            } else {
                List {
                    ForEach(results) { result in
                        SearchResultRow(result: result, onShelf: app.bookOnShelf(for: result) != nil)
                            .onTapGesture {
                                destination = app.bookOnShelf(for: result)
                                    .map { .shelf($0.id) } ?? .preview(result)
                            }
                    }
                    if more, let category = selectedCategory, let source = currentSource {
                        // Sources rarely say how many pages exist, so the next
                        // one is fetched when the reader reaches the end.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task {
                                await app.loadMoreExplore(category: category, source: source)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
#endif
