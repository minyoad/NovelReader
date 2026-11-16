#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Discovery checks describe discovery only. They never mutate source settings
/// or enter selection mode; the results screen offers that as a separate step.
@MainActor
final class SourceHealthCheck: ObservableObject {
    enum Status: Equatable, Sendable {
        case waiting, checking, working, failed, skipped, cancelled

        var title: String {
            switch self {
            case .waiting: return "等待检测"
            case .checking: return "检测中"
            case .working: return "发现页可打开"
            case .failed: return "发现页异常"
            case .skipped: return "未检测"
            case .cancelled: return "已停止"
            }
        }
    }

    struct Entry: Identifiable {
        let source: BookSource
        var status: Status
        var note: String?
        var id: UUID { source.id }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var runID = UUID()

    var completed: Int {
        entries.filter { $0.status != .waiting && $0.status != .checking && $0.status != .cancelled }.count
    }

    var failedIDs: Set<UUID> {
        Set(entries.filter { $0.status == .failed }.map(\.id))
    }

    func cancel() {
        task?.cancel()
        task = nil
        runID = UUID()
        isRunning = false
        for index in entries.indices where entries[index].status == .waiting || entries[index].status == .checking {
            entries[index].status = .cancelled
        }
    }

    func start(sources: [BookSource], client: HTTPClient) {
        cancel()
        entries = sources.map { source in
            let canCheck = !source.openableExploreCategories.isEmpty
            return Entry(source: source, status: canCheck ? .waiting : .skipped,
                         note: canCheck ? nil : "未配置可检测的发现页，不代表无法搜索或阅读。")
        }
        let queue = sources.filter { !$0.openableExploreCategories.isEmpty }
        guard !queue.isEmpty else { return }
        isRunning = true
        let currentRun = runID
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.runID == currentRun else { return }
            let coordinator = ExploreProbeCoordinator()
            await withTaskGroup(of: (UUID, Bool, String?).self) { group in
                var next = 0
                func enqueue(_ source: BookSource) {
                    if let index = self.entries.firstIndex(where: { $0.id == source.id }) {
                        self.entries[index].status = .checking
                    }
                    group.addTask {
                        let result = await AppModel.probeSource(
                            source, categories: source.openableExploreCategories,
                            client: client, coordinator: coordinator
                        )
                        return (source.id, result.working != nil, result.sourceError?.localizedDescription)
                    }
                }
                for _ in 0..<min(6, queue.count) {
                    enqueue(queue[next])
                    next += 1
                }
                for await (id, works, error) in group {
                    guard !Task.isCancelled, self.runID == currentRun else {
                        group.cancelAll()
                        break
                    }
                    if let index = self.entries.firstIndex(where: { $0.id == id }) {
                        self.entries[index].status = works ? .working : .failed
                        self.entries[index].note = works ? nil : (error ?? "当前未能打开发现页，搜索和正文阅读可能仍然可用。")
                    }
                    if next < queue.count {
                        enqueue(queue[next])
                        next += 1
                    }
                }
            }
            guard self.runID == currentRun else { return }
            self.isRunning = false
            self.task = nil
        }
    }
}

struct SourceHealthResultsView: View {
    @ObservedObject var check: SourceHealthCheck
    @Environment(\.dismiss) private var dismiss
    var onManageFailures: ((Set<UUID>) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if check.isRunning {
                        ProgressView(value: Double(check.completed), total: Double(max(check.entries.count, 1)))
                        Text("已处理 \(check.completed) / \(check.entries.count) 个书源")
                        Button("停止检测") { check.cancel() }
                    } else {
                        Text("发现页可打开 \(check.entries.filter { $0.status == .working }.count) 个，异常 \(check.failedIDs.count) 个")
                    }
                    Text("这里只检测发现页，不代表搜索、目录或正文是否可用。检测不会自动停用或删除书源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                resultSection("发现页异常", statuses: [.failed])
                resultSection("发现页可打开", statuses: [.working])
                resultSection("未检测 / 已停止", statuses: [.skipped, .cancelled])
                resultSection("等待 / 检测中", statuses: [.waiting, .checking])
            }
            .navigationTitle("发现页检测结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let onManageFailures, !check.isRunning, !check.failedIDs.isEmpty {
                    Button("选择异常书源进行批量管理（\(check.failedIDs.count)）") {
                        onManageFailures(check.failedIDs)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.bar)
                }
            }
            .onDisappear { check.cancel() }
        }
    }

    @ViewBuilder
    private func resultSection(_ title: String, statuses: [SourceHealthCheck.Status]) -> some View {
        let entries = check.entries.filter { statuses.contains($0.status) }
        if !entries.isEmpty {
            Section("\(title)（\(entries.count)）") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.source.name)
                            Spacer()
                            if entry.status == .checking { ProgressView().controlSize(.small) }
                        }
                        Text(entry.source.host).font(.caption).foregroundStyle(.secondary)
                        if let note = entry.note {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}
#endif
