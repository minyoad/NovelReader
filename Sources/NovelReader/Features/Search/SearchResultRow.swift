#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// One book from a search or a discover page.
///
/// Both screens list the same thing and need the same tap behaviour, so the row
/// lives here rather than being duplicated. The caller supplies the action
/// because only it knows where a tap should lead.
struct SearchResultRow: View {
    let result: SearchResult
    /// Whether this book is already on the shelf, which changes the trailing
    /// icon from "opens a preview" to "already yours".
    let onShelf: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: result.coverURL, width: 52, height: 72, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(result.author.isEmpty ? "佚名" : result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !result.intro.isEmpty {
                    // A line of blurb is what lets the user skip obvious
                    // wrong editions without opening every row.
                    Text(result.intro)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
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

            Image(systemName: onShelf ? "books.vertical.fill" : "chevron.right")
                .font(.caption)
                .foregroundStyle(
                    onShelf
                        ? AnyShapeStyle(Palette.accent)
                        : AnyShapeStyle(.tertiary)
                )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
#endif
