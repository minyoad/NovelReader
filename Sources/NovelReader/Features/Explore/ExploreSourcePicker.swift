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

    private func row(for source: BookSource) -> some View {
        Button {
            onPick(source)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .foregroundStyle(.primary)
                    Text("\(source.openableExploreCategories.count) 个分类")
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
