#if canImport(SwiftUI)
import SwiftUI

// The first sheet closes before its destination opens, so an import form never
// competes with the chooser for the same presentation slot.
enum SourceAddDestination: String, CaseIterable, Identifiable {
    case collections, subscription, json, url, example
    var id: String { rawValue }

    var title: String {
        switch self {
        case .collections: return "浏览在线合集"
        case .subscription: return "订阅链接"
        case .json: return "粘贴导入"
        case .url: return "从链接导入一次"
        case .example: return "导入示例书源"
        }
    }

    var detail: String {
        switch self {
        case .collections: return "先查看合集内容，再选择导入"
        case .subscription: return "添加书源链接，之后自动跟随更新"
        case .json: return "粘贴 legado 书源 JSON，查看后导入"
        case .url: return "下载链接中的书源，不自动更新"
        case .example: return "用于了解书源格式，导入后默认停用"
        }
    }

    var symbol: String {
        switch self {
        case .collections: return "square.grid.2x2"
        case .subscription: return "dot.radiowaves.left.and.right"
        case .json: return "doc.on.clipboard"
        case .url: return "link"
        case .example: return "book.pages"
        }
    }
}

struct SourceAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSelect: (SourceAddDestination) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SourceAddDestination.allCases.filter { $0 != .example }) { destination in
                        option(destination)
                    }
                } footer: {
                    Text("支持「阅读 / legado」书源。订阅会持续更新，单次导入只保存当前版本。")
                }
                Section("了解书源") {
                    option(.example)
                }
            }
            .navigationTitle("添加书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func option(_ destination: SourceAddDestination) -> some View {
        Button { onSelect(destination) } label: {
            Label {
                VStack(alignment: .leading, spacing: 5) {
                    Text(destination.title).foregroundStyle(.primary)
                    Text(destination.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } icon: {
                Image(systemName: destination.symbol)
            }
        }
    }
}
#endif
