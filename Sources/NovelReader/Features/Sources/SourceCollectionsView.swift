#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Browses the online 书源合集 section of 源仓库 (yckceo.com).
///
/// The point of a collection is scale: one download can carry a thousand
/// sources, which is far more than anyone wants to import blind. So the flow is
/// list → preview (blurb + every site in the bundle) → import, and the import
/// result says exactly how many were new, refreshed, or skipped.
struct SourceCollectionsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var order: SourceCollectionClient.Order = .updated
    @State private var items: [SourceCollection] = []
    @State private var total = 0
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var opened: SourceCollection?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("排序", selection: $order) {
                        Text("最近更新").tag(SourceCollectionClient.Order.updated)
                        Text("下载最多").tag(SourceCollectionClient.Order.downloads)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if let errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("加载失败", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("重试") { Task { await load(reset: true) } }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if items.isEmpty && isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                } else if items.isEmpty && errorMessage == nil {
                    Section {
                        Text("没有找到合集")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            Button {
                                opened = item
                            } label: {
                                CollectionRow(collection: item)
                            }
                            .buttonStyle(.plain)
                        }

                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoadingMore {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("加载更多（共 \(total) 个）")
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(isLoadingMore)
                        }
                    } header: {
                        if total > 0 {
                            Text("共 \(total) 个合集")
                        }
                    } footer: {
                        Text("数据来自源仓库 yckceo.com。合集里的书源规则由上传者维护，导入后可以逐个启用或删掉。")
                    }
                }
            }
            .navigationTitle("书源合集")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索合集标题")
            .onSubmit(of: .search) { Task { await load(reset: true) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load(reset: true) }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .navigationDestination(item: $opened) { collection in
                SourceCollectionDetailView(collection: collection)
            }
            .task {
                if items.isEmpty { await load(reset: true) }
            }
            .onChange(of: order) { _, _ in
                Task { await load(reset: true) }
            }
        }
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            page = 1
        } else {
            isLoadingMore = true
        }
        errorMessage = nil
        defer {
            isLoading = false
            isLoadingMore = false
        }

        do {
            let client = app.collectionClient()
            let result = try await client.list(
                page: reset ? 1 : page + 1,
                keyword: query,
                order: order
            )
            if reset {
                items = result.items
            } else {
                // A bundle shows up on several pages when uploads shift while
                // paging; de-duplicating by id keeps ForEach happy.
                let known = Set(items.map(\.id))
                items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            }
            total = result.total
            page = result.page
            hasMore = result.hasMore
        } catch {
            errorMessage = error.localizedDescription
            if reset { items = [] }
        }
    }
}

private struct CollectionRow: View {
    let collection: SourceCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(collection.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                if collection.sourceCount > 0 {
                    Label("\(collection.sourceCount) 个源", systemImage: "antenna.radiowaves.left.and.right")
                }
                if collection.downloadCount > 0 {
                    Label("\(collection.downloadCount)", systemImage: "arrow.down.circle")
                }
                Spacer(minLength: 0)
                if !collection.updatedText.isEmpty {
                    Text(collection.updatedText)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !collection.author.isEmpty {
                Text(collection.author)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Preview before import: what the bundle claims, which sites it actually
/// contains, and then one explicit import button.
private struct SourceCollectionDetailView: View {
    @EnvironmentObject private var app: AppModel
    let collection: SourceCollection

    @State private var detail: SourceCollectionDetail?
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showAllEntries = false

    private var shownEntries: [SourceCollectionDetail.Entry] {
        guard let detail else { return [] }
        return showAllEntries ? detail.entries : Array(detail.entries.prefix(12))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(collection.title)
                        .font(.headline)
                    HStack(spacing: 10) {
                        if collection.sourceCount > 0 {
                            Text("\(collection.sourceCount) 个书源")
                        }
                        if collection.downloadCount > 0 {
                            Text("下载 \(collection.downloadCount)")
                        }
                        if !collection.updatedText.isEmpty {
                            Text(collection.updatedText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !collection.author.isEmpty {
                        Text(collection.author)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }

            if let summary = detail?.summary, !summary.isEmpty {
                Section("简介") {
                    Text(summary)
                        .font(.footnote)
                }
            }

            if !shownEntries.isEmpty {
                Section {
                    ForEach(Array(shownEntries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.footnote)
                            Text(entry.baseURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 1)
                    }
                    if let detail, detail.entries.count > shownEntries.count {
                        Button("还有 \(detail.entries.count - shownEntries.count) 个…") {
                            showAllEntries = true
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("包含的书源")
                } footer: {
                    if let detail, !detail.entries.isEmpty, collection.sourceCount > detail.entries.count {
                        Text("下载的 JSON 里可能还有更多，这个列表只是站点展示的摘要。")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { await importBundle() }
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        }
                        Text(isImporting ? "正在导入…" : "导入这个合集")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isImporting || isLoading)
            } footer: {
                Text("同一个站点已经存在时只更新规则，不会重复添加，也会保留你原来的启用状态。")
            }
        }
        .navigationTitle("合集详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if detail == nil { await loadDetail() }
        }
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await app.collectionClient().detail(for: collection)
        } catch {
            // The list row is enough to import from, so a failed detail page
            // is a warning next to the button, not a dead end.
            errorMessage = error.localizedDescription
        }
    }

    private func importBundle() async {
        isImporting = true
        defer { isImporting = false }
        do {
            let client = app.collectionClient()
            let target = detail?.collection ?? collection
            let data = try await client.jsonData(for: target)
            let result = app.importSources(from: data)

            if result.added > 0 {
                app.showBanner("已导入 \(result.added) 个书源", isError: false)
            } else if result.warnings.isEmpty {
                app.showBanner("这些书源都已经在列表里了", isError: false)
            } else {
                app.showBanner(result.warnings.first ?? "没有导入书源", isError: true)
            }
        } catch {
            app.showBanner(error.localizedDescription, isError: true)
        }
    }
}
#endif
