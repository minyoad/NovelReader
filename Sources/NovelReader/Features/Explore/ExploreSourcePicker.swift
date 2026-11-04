#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Picks which source the discover page browses.
///
/// A plain menu stops working once a library holds dozens of sources, which is
/// the normal case for an imported legado collection: the list scrolls past the
/// screen and there is no way to jump to a name. Searching is the only reliable
/// way to reach one of a hundred entries.
struct ExploreSourcePicker: View {
    let sources: [BookSource]
    let current: BookSource?
    /// How many sources were hidden because opening them failed.
    var hiddenCount: Int = 0
    /// How many tabs a source still has, after failed ones were filtered out.
    var categoryCount: (BookSource) -> Int = { $0.openableExploreCategories.count }
    /// Progress of the "check every source" run.
    var probe: AppModel.ExploreProbeState = .idle
    var onRestore: () -> Void = {}
    var onProbe: () -> Void = {}
    var onCancelProbe: () -> Void = {}
    let onPick: (BookSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [BookSource] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sources }
        return sources.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.baseURL.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Sources grouped the way the source list groups them, so a familiar
    /// shape carries over from the manage screen.
    private var sections: [(title: String, sources: [BookSource])] {
        var order: [String] = []
        var buckets: [String: [BookSource]] = [:]
        for source in filtered {
            let key = source.group.isEmpty ? "未分组" : source.group
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(source)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.sources) { source in
                                row(for: source)
                            }
                        }
                    }
                }

                if hiddenCount > 0 {
                    Section {
                        // Says why the list is shorter than the source count on
                        // the 书源 tab, and provides the way back for when the
                        // failure was the network rather than the site.
                        Button {
                            onRestore()
                            dismiss()
                        } label: {
                            Label("恢复 \(hiddenCount) 个打不开的书源", systemImage: "arrow.clockwise")
                        }
                    } footer: {
                        Text("打开失败的书源会自动隐藏，恢复后会再试一次。")
                    }
                }

                Section {
                    probeRow
                } footer: {
                    Text("逐个打开发现页，打不开的自动隐藏，通常不到一分钟。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择来源")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索书源名或网址")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var probeRow: some View {
        switch probe {
        case .idle:
            Button {
                onProbe()
            } label: {
                Label("检测全部书源", systemImage: "waveform.path.ecg")
            }
        case .running(let done, let total, let working):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("正在检测 \(done)/\(total)，\(working) 个可用")
                        .font(.footnote)
                    Spacer()
                    Button("停止", action: onCancelProbe)
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(done), total: Double(max(total, 1)))
            }
            .padding(.vertical, 2)
        case .finished(let working, let total):
            HStack {
                Text("上次检测：\(total) 个书源里 \(working) 个可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新检测", action: onProbe)
                    .font(.footnote)
            }
        }
    }

    private func row(for source: BookSource) -> some View {
        Button {
            onPick(source)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .foregroundStyle(.primary)
                    Text("\(categoryCount(source)) 个分类")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if source.id == current?.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
