#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Cached, small-source discovery first. The source-by-source browser remains
/// an explicit destination, so merely opening this tab never probes every site.
struct ExploreView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = DiscoveryFeedModel()
    @State private var destination: Destination?
    @State private var showingSources = false
    @State private var showingBrowser = false
    @State private var isVisible = false

    private enum Destination: Hashable {
        case preview(SearchResult)
        case shelf(UUID)
    }

    private var candidates: [BookSource] {
        app.sources.filter { $0.enabled && $0.type == .text && $0.canExplore }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("发现新书").font(.headline)
                            Text(model.selectedSourceIDs.isEmpty ? "自动选择少量来源，先返回先展示" : "聚合 \(model.selectedSourceIDs.count) 个指定来源")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("换一批") { model.nextBatch() }
                            .buttonStyle(.bordered)
                            .disabled(!model.canChangeBatch || !model.hasLoadedCache || (candidates.isEmpty && model.entries.isEmpty))
                    }
                    HStack {
                        Button { showingSources = true } label: {
                            Label("发现来源", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .disabled(!model.hasLoadedCache)
                        Spacer()
                        Button { showingBrowser = true } label: {
                            Label("按书源浏览", systemImage: "books.vertical")
                        }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }

                if model.isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在更新 \(model.completed)/\(model.total) 个来源")
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("停止") { model.stopLoading() }
                                .font(.footnote)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let message = model.message {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !model.visibleEntries.isEmpty {
                    Section {
                        ForEach(model.visibleEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                SearchResultRow(result: entry.primary,
                                                onShelf: DiscoveryCatalog.shelfBook(for: entry, in: app.books) != nil)
                                    .onTapGesture { open(entry.primary, entry: entry) }
                                    .accessibilityAddTraits(.isButton)
                                if entry.variants.count > 1 {
                                    Menu {
                                        ForEach(entry.variants) { variant in
                                            Button("\(variant.sourceName) · \(variant.author.isEmpty ? "作者未知" : variant.author)") {
                                                destination = app.bookOnShelf(for: variant).map { .shelf($0.id) } ?? .preview(variant)
                                            }
                                        }
                                    } label: {
                                        Label(entry.sourceCount > 1 ? "\(entry.sourceCount) 个来源可选" : "\(entry.variants.count) 个版本可选",
                                              systemImage: "arrow.triangle.branch")
                                            .font(.caption)
                                    }
                                    .padding(.leading, 64)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("这一批 \(model.visibleEntries.count) 本")
                            Spacer()
                            if let updated = model.updatedAt {
                                Text("缓存于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).textCase(nil)
                            }
                        }
                    } footer: {
                        Text("来自书源的推荐与分类列表；同名同作者合并展示，所有来源均可选择。")
                    }
                } else if !model.isLoading && model.hasLoadedCache {
                    Section {
                        ContentUnavailableView {
                            Label(candidates.isEmpty ? "还没有发现来源" : "暂未取得书籍", systemImage: "safari")
                        } description: {
                            Text(candidates.isEmpty ? "在「书源」导入并启用带发现页的书源。" : "可以调整发现来源，或刷新重试。上次缓存会在有内容时保留。")
                        } actions: {
                            Button("调整发现来源") { showingSources = true }
                            if !candidates.isEmpty { Button("刷新重试") { model.refresh() } }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refreshAndWait() }
            .navigationTitle("发现")
            .navigationDestination(item: $destination) { target in
                switch target {
                case .preview(let result): BookPreviewView(result: result)
                case .shelf(let id):
                    if let book = app.books.first(where: { $0.id == id }) { BookDetailView(book: book) }
                    else { ContentUnavailableView("书籍已移出书架", systemImage: "book.closed") }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.isSearching = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索书籍")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isLoading || !model.hasLoadedCache)
                        .accessibilityLabel("刷新发现")
                }
            }
            .sheet(isPresented: $showingSources) {
                DiscoverySourceSelectionView(sources: candidates, selected: model.selectedSourceIDs) { selected in
                    model.configure(selected)
                }
            }
            .sheet(isPresented: $showingBrowser) { SourceExploreView() }
            .onChange(of: showingBrowser) { _, showing in
                if showing { model.cancel() }
                else if isVisible { openFeed() }
            }
            .onAppear { isVisible = true; openFeed() }
            .onDisappear { isVisible = false; model.cancel() }
            .onChange(of: app.sources) { _, _ in
                if isVisible && !showingBrowser { openFeed() }
            }
            .onChange(of: app.settings.network) { _, _ in
                if isVisible && !showingBrowser { openFeed() }
            }
        }
    }

    private func openFeed() {
        model.open(sources: app.sources, network: app.settings.network, store: app.store)
    }

    private func open(_ result: SearchResult, entry: DiscoveryEntry) {
        destination = DiscoveryCatalog.shelfBook(for: entry, in: app.books)
            .map { .shelf($0.id) } ?? .preview(result)
    }
}

private struct DiscoverySourceSelectionView: View {
    let sources: [BookSource]
    @Environment(\.dismiss) private var dismiss
    @State private var automatic: Bool
    @State private var selection: Set<UUID>
    @State private var query = ""
    let onSave: ([UUID]) -> Void

    init(sources: [BookSource], selected: [UUID], onSave: @escaping ([UUID]) -> Void) {
        self.sources = sources
        self.onSave = onSave
        _automatic = State(initialValue: selected.isEmpty)
        _selection = State(initialValue: Set(selected))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("自动选择", isOn: $automatic)
                } footer: {
                    Text("自动模式每次最多请求 3 个来源，优先最近可用、响应快的来源。也可指定最多 5 个。")
                }
                if !automatic {
                    Section("已选 \(selection.count)/5") {
                        ForEach(sources.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query) }) { source in
                            Toggle(isOn: Binding(
                                get: { selection.contains(source.id) },
                                set: { enabled in
                                    if enabled && selection.count < DiscoveryCatalog.sourceLimit { selection.insert(source.id) }
                                    else if !enabled { selection.remove(source.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                    Text(source.host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!selection.contains(source.id) && selection.count >= DiscoveryCatalog.sourceLimit)
                        }
                    }
                }
                if sources.isEmpty {
                    Text("没有带发现页的已启用书源，请先在「书源」添加。")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "搜索来源")
            .navigationTitle("发现来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(automatic ? [] : sources.filter { selection.contains($0.id) }.map(\.id))
                        dismiss()
                    }
                    .disabled(!automatic && selection.isEmpty)
                }
            }
        }
    }
}
#endif
