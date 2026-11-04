#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var errorMessage: String?

    /// Where a tapped row leads: the full preview for a book that is not on the
    /// shelf yet (it needs a deliberate "加入书架"), or the library detail page
    /// for one that already is.
    private enum Destination: Hashable {
        case preview(SearchResult)
        case shelf(UUID)

        /// `SearchResult` is not `Identifiable`-stable across re-renders, so a
        /// string key is what the navigation stack remembers.
        var id: String {
            switch self {
            case .preview(let result): return "preview|\(result.id)"
            case .shelf(let id): return "shelf|\(id.uuidString)"
            }
        }
    }

    @State private var destination: Destination?

    private var activeSources: [BookSource] {
        app.sources.filter { $0.enabled && $0.type == .text && $0.canSearch }
    }

    /// Nothing typed: the field is where a search starts, so this is the only
    /// moment the history belongs on screen.
    private var isQueryEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                // An empty field always shows the history. Keying this off
                // `searchState` meant the history only appeared if the app
                // happened to be idle, and clearing the field does not
                // reliably drive that state.
                if isQueryEmpty {
                    if app.settings.searchHistory.isEmpty {
                        EmptyStateView(
                            title: "找一本书",
                            message: searchHint,
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        searchHistoryList
                    }
                } else {
                    switch app.searchState {
                    case .idle:
                        EmptyStateView(
                            title: "找一本书",
                            message: searchHint,
                            systemImage: "magnifyingglass"
                        )
                    case .searching(let keyword, let done, let total):
                        // Results stream in one source at a time, so show them
                        // as they arrive instead of a full-screen spinner. A
                        // search over twenty sources used to show nothing at
                        // all until the slowest one came back.
                        if app.searchResults.isEmpty {
                            VStack(spacing: 14) {
                                ProgressView()
                                Text("正在搜索「\(keyword)」…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(total > 0 ? "已完成 \(done)/\(total) 个书源" : "\(activeSources.count) 个书源")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            resultsList(
                                failed: [],
                                skipped: [],
                                count: app.searchResults.count,
                                progress: total > 0 ? "搜索中 \(done)/\(total)" : "搜索中"
                            )
                        }
                    case .finished(let count, let failed, let skipped):
                        if app.searchResults.isEmpty {
                            VStack(spacing: 10) {
                                EmptyStateView(
                                    title: "没有找到结果",
                                    message: emptyResultMessage(failed: failed, skipped: skipped),
                                    systemImage: "questionmark.folder"
                                )
                            }
                        } else {
                            resultsList(failed: failed, skipped: skipped, count: count, progress: nil)
                        }
                    case .failed(let message):
                        EmptyStateView(title: "搜索失败", message: message, systemImage: "wifi.exclamationmark")
                    }
                }
            }
            .navigationTitle("找书")
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
            // A pinned field rather than `.searchable`: the system search bar
            // collapses into the navigation bar until the reader pulls down,
            // and this page exists for nothing else. Presented as a sheet it
            // also has no scroll view of its own to drive the collapse, so the
            // field simply never appeared.
            .safeAreaInset(edge: .top, spacing: 0) {
                searchField
            }
            .onChange(of: query) { _, newValue in
                // The search field's Cancel button clears the text. Drop the
                // results with it, otherwise the list keeps showing a search
                // whose keyword is no longer in the field — and the history,
                // which only shows when nothing is being searched, never
                // appears.
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    app.cancelSearch()
                }
            }
            .toolbar {
                // Search is a sheet, so it needs a way to close itself.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        app.isSearching = false
                    } label: {
                        Label("发现", systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                    }
                    .accessibilityLabel("返回发现")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.search(query) }
                    } label: {
                        if app.searchState.isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("搜索")
                        }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("出错了", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// The always-visible search bar.
    ///
    /// Hand-rolled instead of `.searchable` for two reasons: the system bar is
    /// collapsed until the reader pulls the list down, and this page is a sheet
    /// with no list of its own to pull. The clear button only appears once there
    /// is something to clear, the same way the system field behaves.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("书名或作者", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await app.search(query) } }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// Recent searches, tappable to run again.
    ///
    /// This fills the idle screen instead of an empty illustration: the
    /// searches worth repeating are the most useful thing to offer when the
    /// field is empty.
    private var searchHistoryList: some View {
        List {
            Section {
                ForEach(app.settings.searchHistory, id: \.self) { keyword in
                    Button {
                        query = keyword
                        Task { await app.search(keyword) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(keyword)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            app.removeSearchHistory(keyword)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("最近搜索")
                    Spacer()
                    Button("清空") { app.clearSearchHistory() }
                        .font(.caption)
                        .textCase(nil)
                }
            } footer: {
                Text(searchHint)
                    .font(.caption2)
            }
        }
        .listStyle(.plain)
    }

    private var searchHint: String {
        if activeSources.isEmpty {
            return "还没有可用的书源。先在「书源」里导入，或者直接搜索内置示例《长夜灯下》。"
        }
        return "将在 \(activeSources.count) 个书源中搜索。试试「长夜灯下」。"
    }

    /// What to say when nothing came back.
    ///
    /// `skipped` is called out separately from `failed`: a JavaScript-only
    /// search rule is permanent, so telling the user their network might be
    /// flaky would be actively misleading.
    private func emptyResultMessage(failed: [String], skipped: [String]) -> String {
        var parts: [String] = []
        if !skipped.isEmpty {
            parts.append("\(skipped.joined(separator: "、")) 的搜索规则是纯 JavaScript，本应用无法执行。")
        }
        if !failed.isEmpty {
            parts.append("这些书源搜索失败：\(failed.joined(separator: "、"))。")
        }
        if parts.isEmpty {
            return "换个关键词试试，或者先在「书源」里添加更多书源。"
        }
        return parts.joined(separator: "\n")
    }

    private func resultsList(failed: [String], skipped: [String], count: Int, progress: String?) -> some View {
        List {
            Section {
                ForEach(app.searchResults) { result in
                    resultRow(result)
                }
            } header: {
                HStack {
                    Text("\(count) 个结果")
                    Spacer()
                    if let progress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(progress)
                                .foregroundStyle(.secondary)
                        }
                    } else if !failed.isEmpty {
                        Text("\(failed.count) 个书源失败")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if !skipped.isEmpty {
                    // Shown with the results, not only when the search comes up
                    // empty: this is why one of the sources returned nothing, and
                    // it stays true for every future search.
                    Text("\(skipped.joined(separator: "、")) 的搜索规则是纯 JavaScript，本应用无法执行，已在「书源」里标出。")
                        .font(.caption2)
                }
            }
        }
        .listStyle(.plain)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        SearchResultRow(result: result, onShelf: app.bookOnShelf(for: result) != nil)
            // Tapping a result never adds it: it opens the preview, which is
            // where the blurb and the chapter count live and where "加入书架"
            // is the only way in. A one-tap `+` here was too easy to hit by
            // accident.
            .onTapGesture {
                destination = app.bookOnShelf(for: result)
                    .map { .shelf($0.id) } ?? .preview(result)
            }
    }
}
#endif
