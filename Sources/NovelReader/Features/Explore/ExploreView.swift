#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Browse a source's own listings instead of guessing at a keyword.
///
/// Not every source has one: legado describes discover pages through
/// `exploreUrl`, and sources that ship without it simply never appear here.
struct ExploreView: View {
    @EnvironmentObject private var app: AppModel

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
                    emptyState
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
                // Also shown with a single source when some were hidden: the
                // footer there is the only way to bring them back.
                if sources.count > 1 || !app.hiddenExploreSources.isEmpty || app.exploreProbe.isRunning {
                    ToolbarItem(placement: .topBarTrailing) {
                        sourceMenu
                    }
                }
            }
            .task {
                // A fresh install or an update that discarded old verdicts
                // checks the imported collection once: with a few hundred dead
                // sources, tapping through them is not a realistic way to find
                // the live ones.
                if app.shouldProbeExplore {
                    app.shouldProbeExplore = false
                    app.probeExploreSources()
                    guard let source = currentSource else { return }
                    await app.startExploreAtProbedCategory(source: source)
                    return
                }
                // Opening the tab should land on real books, not an empty
                // screen the reader has to poke before anything happens.
                guard case .idle = app.exploreState,
                      let source = currentSource else { return }
                await app.startExplore(source: source)
            }
        }
    }

    /// Shown when nothing is left to browse.
    ///
    /// Recover-and-check in one tap: restoring alone would put the dead
    /// sources back on screen with the same errors, so the probe runs right
    /// after and keeps only the ones that answered.
    private var emptyState: some View {
        VStack(spacing: 20) {
            EmptyStateView(
                title: app.hiddenExploreSources.isEmpty ? "还没有可发现的来源" : "没有能打开的来源",
                message: app.hiddenExploreSources.isEmpty
                    ? "去「书源」导入带发现页的书源，就能直接翻分类找书。"
                    : "打不开的书源已被隐藏。恢复后检测一遍，只留下真正能打开的。",
                systemImage: "safari"
            )
            if !app.hiddenExploreSources.isEmpty {
                VStack(spacing: 12) {
                    Button {
                        app.restoreHiddenExploreSources()
                        app.probeExploreSources()
                    } label: {
                        Label("重新检测书源", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    probeStatus
                }
            }
        }
    }

    @ViewBuilder
    private var probeStatus: some View {
        switch app.exploreProbe {
        case .idle:
            EmptyView()
        case .running(let done, let total, let working):
            VStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(maxWidth: 220)
                Text("正在检测 \(done)/\(total)，\(working) 个可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .finished(let working, let total):
            Text("检测完成：\(total) 个书源里 \(working) 个可用")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                hiddenCount: app.hiddenExploreSources.count,
                categoryCount: { app.openCategories(of: $0).count },
                probe: app.exploreProbe,
                onRestore: { app.restoreHiddenExploreSources() },
                onProbe: { app.probeExploreSources() },
                onCancelProbe: { app.cancelExploreProbe() },
                onPick: { source in
                    showingSourcePicker = false
                    Task { await app.startExploreAtProbedCategory(source: source) }
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
                                    category == app.exploreCategory
                                        ? Palette.accent.opacity(0.15)
                                        : Color.secondary.opacity(0.1)
                                )
                            )
                            .foregroundStyle(category == app.exploreCategory ? Palette.accent : .primary)
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
                    if more, let category = app.exploreCategory, let source = currentSource {
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
