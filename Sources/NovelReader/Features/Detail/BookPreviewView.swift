#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// A search result, shown in full before it is allowed anywhere near the shelf.
///
/// The shelf used to be a one-tap button on the search row: a mis-tap added a
/// book you had not read the blurb of, and the only way back was removing it.
/// Deciding whether to keep a book needs the things a search row cannot show —
/// the intro, the chapter count, the latest chapter — so the detail page is
/// fetched first and the "加入书架" button is the single deliberate action.
struct BookPreviewView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let result: SearchResult

    @State private var preview: AppModel.BookPreview?
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var showAllIntro = false
    @State private var errorMessage: String?

    private var onShelf: Book? { app.bookOnShelf(for: result) }

    /// Shown while the network works, so the header is readable immediately
    /// instead of a spinner on an empty page.
    private var displayed: Book {
        preview?.book ?? placeholder
    }

    private var placeholder: Book {
        Book(
            sourceID: result.sourceID,
            sourceName: result.sourceName,
            detailURL: result.detailURL,
            name: result.name,
            author: result.author,
            intro: result.intro,
            kind: result.kind,
            coverURL: result.coverURL,
            lastChapterTitle: result.lastChapterTitle,
            updateTime: result.updateTime
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let preview, !preview.chapters.isEmpty {
                    stats(preview)
                }

                if showsIntro {
                    introSection
                } else if !isLoading {
                    // A site with no blurb is common; the page should still say
                    // something rather than leaving a gap where the section was.
                    Text("这个书源没有提供简介，可以先看目录规模再决定。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取详情与目录…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let preview, !preview.chapters.isEmpty {
                    chapterPreview(preview.chapters)
                }

                if let preview, preview.isPartial, let error = preview.error {
                    // A partial preview is still useful: the user can decide
                    // from the blurb. Say what is missing rather than pretending
                    // the book has no chapters.
                    Label("部分信息读取失败：\(error)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .navigationTitle(displayed.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomAction }
        .task {
            await load()
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var showsIntro: Bool {
        !TextProcessing.normalizeParagraphs(displayed.intro).isEmpty
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(url: displayed.coverURL, width: 104, height: 142, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayed.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(displayed.author.isEmpty ? "佚名" : displayed.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !displayed.kind.isEmpty {
                    Text(displayed.kind)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                if !displayed.lastChapterTitle.isEmpty {
                    Text("最新：\(displayed.lastChapterTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("来源：\(displayed.sourceName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    /// The facts that decide "is this worth a shelf slot": length, freshness,
    /// and whether the site updates.
    private func stats(_ preview: AppModel.BookPreview) -> some View {
        HStack(spacing: 0) {
            statCell(value: "\(preview.chapters.count)", label: "章")
            Divider().frame(height: 28)
            if !displayed.wordCount.isEmpty {
                statCell(value: displayed.wordCount, label: "字")
                Divider().frame(height: 28)
            }
            statCell(
                value: displayed.updateTime.isEmpty ? "未知" : displayed.updateTime,
                label: "更新"
            )
        }
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介").font(.headline)
            Text(TextProcessing.normalizeParagraphs(displayed.intro))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(showAllIntro ? nil : 6)
            Button(showAllIntro ? "收起" : "展开") {
                withAnimation(.easeInOut(duration: 0.15)) { showAllIntro.toggle() }
            }
            .font(.footnote)
        }
    }

    private func chapterPreview(_ chapters: [Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目录").font(.headline)
                Text("\(chapters.count) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(chapters.prefix(3)) { chapter in
                HStack {
                    Text(chapter.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    if chapter.isVIP {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            if chapters.count > 3 {
                Text("……共 \(chapters.count) 章")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var bottomAction: some View {
        if onShelf != nil {
            HStack(spacing: 10) {
                Label("已在书架", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Palette.accent)
                Spacer()
                // The row for a shelved book opens `BookDetailView` instead, so
                // the only sane way out of this state is back to the results.
                Button("返回") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        } else {
            Button {
                Task { await add() }
            } label: {
                if isAdding {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("加入书架", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(isAdding)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard preview == nil else { return }
        isLoading = true
        defer { isLoading = false }
        preview = await app.preview(for: result)
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        do {
            let book = try await app.addToShelf(result, preview: preview)
            app.showBanner("已加入书架：\(book.name)", isError: false)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
