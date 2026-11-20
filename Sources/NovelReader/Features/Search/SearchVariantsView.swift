#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// The grouped result remains live while other sources finish searching.
struct SearchVariantsView: View {
    @EnvironmentObject private var app: AppModel
    let entry: DiscoveryEntry
    private var current: DiscoveryEntry {
        DiscoveryCatalog.entries(app.searchResults).first(where: { $0.id == entry.id }) ?? entry
    }
    var body: some View {
        List {
            Section {
                Text(current.primary.author.isEmpty ? "作者未知" : current.primary.author).foregroundStyle(.secondary)
                Text("选择一个版本查看详情、试读或加入书架。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("可选版本 · \(current.variants.count)") {
                ForEach(current.variants) { result in
                    NavigationLink {
                        if let book = app.bookOnShelf(for: result) { BookDetailView(book: book) }
                        else { BookPreviewView(result: result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(result.sourceName).font(.headline)
                                if app.bookOnShelf(for: result) != nil {
                                    Text("已在书架").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !result.lastChapterTitle.isEmpty {
                                Text("最新：\(result.lastChapterTitle)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            if !result.intro.isEmpty {
                                Text(result.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(current.primary.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
