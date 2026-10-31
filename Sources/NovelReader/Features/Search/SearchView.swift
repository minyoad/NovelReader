#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var pendingResultID: String?
    @State private var addingResultID: String?
    @State private var errorMessage: String?

    private var activeSources: [BookSource] {
        app.sources.filter { $0.enabled && $0.type == .text && $0.canSearch }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch app.searchState {
                case .idle:
                    EmptyStateView(
                        title: "找一本书",
                        message: searchHint,
                        systemImage: "magnifyingglass"
                    )
                case .searching(let keyword):
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在搜索「\(keyword)」…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(activeSources.count) 个书源")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished(let count, let failed):
                    if app.searchResults.isEmpty {
                        VStack(spacing: 10) {
                            EmptyStateView(
                                title: "没有找到结果",
                                message: failed.isEmpty
                                    ? "换个关键词试试，或者先在「书源」里添加更多书源。"
                                    : "这些书源搜索失败：\(failed.joined(separator: "、"))",
                                systemImage: "questionmark.folder"
                            )
                        }
                    } else {
                        resultsList(failed: failed, count: count)
                    }
                case .failed(let message):
                    EmptyStateView(title: "搜索失败", message: message, systemImage: "wifi.exclamationmark")
                }
            }
            .navigationTitle("找书")
            .navigationDestination(item: $pendingResultID) { id in
                if let book = app.books.first(where: { $0.id.uuidString == id }) {
                    BookDetailView(book: book)
                } else {
                    EmptyStateView(title: "书不见了", message: "它可能已经被移出书架。", systemImage: "book.closed")
                }
            }
            .searchable(text: $query, prompt: "书名或作者")
            .onSubmit(of: .search) {
                Task { await app.search(query) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.search(query) }
                    } label: {
                        if case .searching = app.searchState {
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

    private var searchHint: String {
        if activeSources.isEmpty {
            return "还没有可用的书源。先在「书源」里导入，或者直接搜索内置示例《长夜灯下》。"
        }
        return "将在 \(activeSources.count) 个书源中搜索。试试「长夜灯下」。"
    }

    private func resultsList(failed: [String], count: Int) -> some View {
        List {
            Section {
                ForEach(app.searchResults) { result in
                    resultRow(result)
                }
            } header: {
                HStack {
                    Text("\(count) 个结果")
                    if !failed.isEmpty {
                        Spacer()
                        Text("\(failed.count) 个书源失败")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: result.coverURL, width: 52, height: 72, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(result.author.isEmpty ? "佚名" : result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !result.lastChapterTitle.isEmpty {
                    Text("最新：\(result.lastChapterTitle)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(result.sourceName)
                    .font(.caption2)
                    .foregroundStyle(Palette.accent)
            }

            Spacer(minLength: 0)

            if let book = app.bookOnShelf(for: result) {
                Button {
                    pendingResultID = book.id.uuidString
                } label: {
                    Text("已收藏")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
            } else {
                Button {
                    Task { await add(result) }
                } label: {
                    if addingResultID == result.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(addingResultID != nil)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let book = app.bookOnShelf(for: result) {
                pendingResultID = book.id.uuidString
            }
        }
    }

    private func add(_ result: SearchResult) async {
        addingResultID = result.id
        defer { addingResultID = nil }
        do {
            let book = try await app.addToShelf(result)
            app.showBanner("已加入书架：\(book.name)", isError: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
