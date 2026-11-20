#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct RankingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var provider: RankingProvider = .zongheng
    @State private var snapshots: [RankingProvider: RankingSnapshot] = [:]
    @State private var selectedBoard = ""
    @State private var loading = false
    @State private var message: String?
    @State private var revision = 0
    @State private var consumedRevision = 0
    @State private var ticket = UUID()
    @State private var searchBook: RankedBook?

    private var snapshot: RankingSnapshot? { snapshots[provider] }
    private var board: BookRanking? {
        snapshot?.boards.first(where: { $0.id == selectedBoard }) ?? snapshot?.boards.first
    }

    var body: some View {
        List {
            Section {
                Picker("榜单来源", selection: $provider) {
                    ForEach(RankingProvider.allCases) { source in
                        Text(source.name).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                if let snapshot {
                    Picker("榜单", selection: $selectedBoard) {
                        ForEach(snapshot.boards) { board in Text(board.title).tag(board.id) }
                    }
                    .pickerStyle(.menu)
                    Text("更新于 \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("正在更新榜单…").font(.footnote) }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button("重试") { revision += 1 }.disabled(loading)
                }
            } footer: {
                Text("榜单来自官方网页摘要，每 6 小时检查更新。点击书籍将在已启用书源中搜索可读版本。")
            }
            if let board {
                Section {
                    ForEach(board.books) { book in
                        Button { searchBook = book } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(book.position)").monospacedDigit()
                                    .font(.headline).foregroundStyle(.secondary)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(book.name).foregroundStyle(.primary)
                                    if !book.author.isEmpty {
                                        Text(book.author).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("搜索可读版本").font(.caption).foregroundStyle(.tint)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(provider.name) · \(board.title)")
                } footer: {
                    Link("查看官方完整榜单", destination: board.url)
                }
            } else if !loading {
                Section {
                    ContentUnavailableView("暂未取得榜单", systemImage: "chart.bar.xaxis", description: Text("可以刷新重试，或打开官方网页查看。"))
                }
            }
            Section {
                Link("打开\(provider.name)榜单网页", destination: provider.url)
                Button("重新获取") { revision += 1 }.disabled(loading)
            }
        }
        .task(id: "\(provider.rawValue)-\(revision)") {
            let force = revision != consumedRevision
            consumedRevision = revision
            await load(force: force)
        }
        .sheet(item: $searchBook) { book in
            SearchView(initialQuery: book.name, authorHint: book.author)
        }
    }

    @MainActor
    private func load(force: Bool) async {
        let source = provider
        let run = UUID()
        ticket = run
        loading = true
        message = nil
        defer { if ticket == run { loading = false } }
        if snapshots[source] == nil {
            let cache = await app.store.loadRankings(source)
            guard !Task.isCancelled, ticket == run else { return }
            snapshots[source] = cache
        }
        selectedBoard = snapshots[source]?.boards.first?.id ?? ""
        if !force, snapshots[source]?.isFresh() == true { return }
        do {
            let fetched = try await RankingCatalog.fetch(source, network: app.settings.network)
            guard !Task.isCancelled, ticket == run else { return }
            snapshots[source] = fetched
            if !fetched.boards.contains(where: { $0.id == selectedBoard }) {
                selectedBoard = fetched.boards.first?.id ?? ""
            }
            await app.store.saveRankings(fetched)
        } catch {
            guard !Task.isCancelled, ticket == run else { return }
            message = snapshots[source] == nil ? error.localizedDescription : "更新失败，仍显示上次缓存。\(error.localizedDescription)"
        }
    }
}
#endif
