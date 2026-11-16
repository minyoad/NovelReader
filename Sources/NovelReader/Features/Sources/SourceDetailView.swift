#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Read-only overview first; editing parsing rules is an explicit second step.
struct SourceDetailView: View {
    let sourceID: UUID
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var healthCheck = SourceHealthCheck()
    @State private var showDeleteConfirmation = false

    private var source: BookSource? { app.sources.first { $0.id == sourceID } }
    private var books: [Book] { app.booksOnShelf(from: [sourceID]) }

    var body: some View {
        Group {
            if let source {
                details(source)
            } else {
                ContentUnavailableView("书源已移除", systemImage: "books.vertical")
            }
        }
        .navigationTitle("书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onDisappear { healthCheck.cancel() }
        .confirmationDialog("删除这个书源？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let source { app.deleteSource(source) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(books.isEmpty
                 ? "只删除书源配置。"
                 : "书架上的 \(books.count) 本书会保留，但无法通过这个书源更新目录或下载新章节。")
        }
    }

    private func details(_ source: BookSource) -> some View {
        List {
            Section {
                Text(source.name).font(.headline).textSelection(.enabled)
                Text(source.baseURL).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent("分组", value: source.group.isEmpty ? "未分组" : source.group)
                LabeledContent("来源", value: origin(of: source))
                Toggle("启用书源", isOn: Binding(
                    get: { self.source?.enabled ?? false },
                    set: { app.setSources([sourceID], enabled: $0) }
                ))
                Toggle("置顶", isOn: Binding(
                    get: { self.source.map { app.isPinned($0) } ?? false },
                    set: { value in
                        if let current = self.source, app.isPinned(current) != value { app.togglePin(current) }
                    }
                ))
            } footer: {
                Text("启用表示参与找书和发现，不代表已通过可用性检测。")
            }

            Section("规则与检测") {
                LabeledContent("搜索规则", value: source.canSearch ? "已配置" : "未配置")
                LabeledContent("发现页规则", value: source.openableExploreCategories.isEmpty ? "未配置可检测页面" : "已配置")
                LabeledContent("兼容情况", value: compatibilityTitle(source))
                if source.compatibility.hasJavaScript {
                    Text(source.compatibility.level == .unreadable
                         ? "阅读所需的部分规则依赖 JavaScript，当前应用无法执行，建议选择其他书源。"
                         : "部分规则依赖 JavaScript，相关字段可能缺失；规则兼容情况不能代替实际阅读检测。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    healthCheck.start(sources: [source], client: HTTPClient(settings: app.settings.network))
                } label: {
                    HStack {
                        Label(healthCheck.entries.isEmpty ? "检测发现页" : "重新检测发现页", systemImage: "waveform.path.ecg")
                        Spacer()
                        if healthCheck.isRunning { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(healthCheck.isRunning)
                if let entry = healthCheck.entries.first {
                    Text(entry.status.title).font(.subheadline)
                    if let note = entry.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("检测仅验证发现页；发现页异常时，搜索和正文阅读可能仍然可用。")
            }

            Section("关联书籍（\(books.count)）") {
                if books.isEmpty {
                    Text("书架上还没有使用这个书源的书。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(books) { book in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.name)
                            if !book.author.isEmpty {
                                Text(book.author).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !source.comment.isEmpty {
                Section("备注") {
                    Text(source.comment).font(.footnote).textSelection(.enabled)
                }
            }
            Section {
                NavigationLink {
                    SourceEditorView(source: source)
                } label: {
                    Label("高级编辑规则", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("仅在需要修改搜索、目录或正文解析规则时使用。")
            }
            Section {
                Button("删除书源", role: .destructive) { showDeleteConfirmation = true }
            }
        }
    }

    private func origin(of source: BookSource) -> String {
        if source.isBuiltIn { return "内置书源" }
        if let id = source.subscriptionID,
           let subscription = app.subscriptions.first(where: { $0.id == id }) {
            return "订阅：\(subscription.displayName)"
        }
        return source.subscriptionID == nil ? "已导入" : "来自订阅"
    }

    private func compatibilityTitle(_ source: BookSource) -> String {
        switch source.compatibility.level {
        case .supported: return "规则受支持"
        case .degraded: return "部分功能受限"
        case .unreadable: return "阅读规则不兼容"
        }
    }
}
#endif
