#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Manages book-source subscriptions: one row per link, plus a refresh.
///
/// Subscriptions are a way to keep a source list current without re-importing
/// it by hand. The page is deliberately small — add, enable, remove, refresh —
/// because everything else about a subscription (which sources it delivered,
/// what their rules are) is already handled by the 书源 tab. A subscription
/// that needs editing is a URL to remove and add again.
struct SourceSubscriptionsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showAdd = false
    @State private var removing: SourceSubscription?

    var body: some View {
        List {
            Section {
                if app.subscriptions.isEmpty {
                    ContentUnavailableView {
                        Label("还没有订阅", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("订阅一个 legado 书源 JSON 链接，之后会跟着它自动更新书源。")
                    }
                } else {
                    ForEach(app.subscriptions) { subscription in
                        row(subscription)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    removing = subscription
                                } label: {
                                    Label("取消订阅", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("订阅")
            } footer: {
                Text("订阅只管理它自己带来的书源。手动导入的书源不受影响；订阅里删掉、但书架上的书还在用的书源会保留。")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }

                Button {
                    Task { await app.refreshSubscriptions() }
                } label: {
                    if app.isRefreshingSubscriptions {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                        }
                    } else {
                        Label("立即更新全部", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(app.isRefreshingSubscriptions || app.subscriptions.isEmpty)
            }
        }
        .navigationTitle("书源订阅")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddSubscriptionSheet()
        }
        .confirmationDialog(
            "取消订阅「\(removing?.displayName ?? "")」？",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("取消订阅", role: .destructive) {
                if let subscription = removing {
                    app.removeSubscription(subscription)
                }
                removing = nil
            }
            Button("保留", role: .cancel) { removing = nil }
        } message: {
            Text("它带来的书源会留在设备上，只是不再跟着更新。")
        }
    }

    private func row(_ subscription: SourceSubscription) -> some View {
        let report = app.subscriptionReports[subscription.id]
        let delivered = app.sources.filter { $0.subscriptionID == subscription.id }.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(subscription.displayName)
                    .lineLimit(1)
                if !subscription.isEnabled {
                    Text("已停用")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { subscription.isEnabled },
                    set: { app.setSubscriptionEnabled(subscription, $0) }
                ))
                .labelsHidden()
            }

            Text(subscription.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text("\(delivered) 个书源")
                if let last = subscription.lastUpdatedAt {
                    Text("·")
                    Text(relative(last))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let report, let error = report.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let result = report?.summary ?? subscription.lastResult {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(report?.changedSomething == true ? .primary : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct AddSubscriptionSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可留空）", text: $name)
                    TextField("https://example.com/sources.json", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await add() } }
                } footer: {
                    Text("填写 legado 书源 JSON 的直接链接。添加后立即下载一次，以后在启动和退到后台时自动更新。")
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await add() }
                    } label: {
                        if isAdding {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("添加")
                        }
                    }
                    .disabled(isAdding || trimmedURL.isEmpty)
                }
            }
        }
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() async {
        guard !isAdding else { return }
        isAdding = true
        error = nil
        defer { isAdding = false }

        let message = await app.addSubscription(name: name, url: url)
        // `addSubscription` returns an error string on failure, or a summary
        // such as "新增 12" on success. Telling them apart: a failed parse
        // leaves no subscription behind.
        if app.subscriptions.contains(where: { $0.url == trimmedURL }) {
            app.showBanner("订阅已添加：\(message)", isError: false)
            dismiss()
        } else {
            error = message
        }
    }
}
#endif
