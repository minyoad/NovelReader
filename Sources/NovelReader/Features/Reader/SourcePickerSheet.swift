#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Lists the other sources that have this book and switches to one, verifying
/// first that it can really serve the chapter being read.
struct SourcePickerSheet: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var probeResults: [String: Bool] = [:]
    @State private var switchingID: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("当前书源", value: model.book.sourceName)
                    LabeledContent("当前章节", value: model.currentChapter?.title ?? "-")
                } footer: {
                    Text("切换到其他书源会保留阅读进度，并按章节标题定位到相同位置。切换前会先尝试读取当前章节正文，读不到的源不会切过去。")
                }

                if model.isSearchingSources && model.sourceCandidates.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    }
                } else if model.sourceCandidates.isEmpty {
                    Section {
                        Text("没有找到其他收录这本书的书源")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("可切换的书源（\(model.sourceCandidates.count)）") {
                        ForEach(model.sourceCandidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.loadSourceCandidates() }
                    } label: {
                        if model.isSearchingSources {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isSearchingSources)
                }
            }
            .task {
                if model.sourceCandidates.isEmpty {
                    await model.loadSourceCandidates()
                }
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: SearchResult) -> some View {
        let probing = model.probingSourceID == candidate.id
        let verified = probeResults[candidate.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name)
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 6) {
                        Text(candidate.sourceName)
                        if !candidate.author.isEmpty {
                            Text("·")
                            Text(candidate.author)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                statusBadge(probing: probing, verified: verified)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        let ok = await model.canRead(candidate)
                        probeResults[candidate.id] = ok
                        if !ok { app.showBanner("这个源读不到当前章节", isError: true) }
                    }
                } label: {
                    Label("试读这一章", systemImage: "eye")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(probing || model.probingSourceID != nil)

                Button {
                    switchingID = candidate.id
                    Task {
                        await model.switchSource(to: candidate)
                        switchingID = nil
                        dismiss()
                    }
                } label: {
                    if switchingID == candidate.id {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("切换中…")
                        }
                        .font(.caption)
                    } else {
                        Label("切换到此源", systemImage: "arrow.left.arrow.right")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(probing || switchingID != nil)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(probing: Bool, verified: Bool?) -> some View {
        if probing {
            ProgressView().controlSize(.small)
        } else if let verified {
            if verified {
                Label("可读", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Label("读不到", systemImage: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// Cache controls: per-book size, prefetch status, whole-book download.
struct CacheSheet: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var size: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("已缓存章节", value: "\(model.cachedChapterCount) / \(model.chapters.count) 章")
                    LabeledContent("占用空间", value: Self.formatted(size))
                } header: {
                    Text("本书缓存")
                } footer: {
                    Text("缓存过的章节离线也能读。阅读时会自动往后缓存 \(app.settings.cache.prefetchCount) 章，可在「阅读设置 → 缓存」里调整。")
                }

                if let progress = model.bookCacheProgress {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("正在缓存全本…\(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Button {
                            Task {
                                await model.cacheWholeBook()
                                await refreshSize()
                            }
                        } label: {
                            Label("缓存全本（\(max(model.chapters.count - model.cachedChapterCount, 0)) 章待下载）",
                                  systemImage: "arrow.down.circle")
                        }
                        .disabled(model.isCachingBook || model.chapters.isEmpty)

                        Button {
                            Task {
                                await model.redownloadChapter()
                                await refreshSize()
                            }
                        } label: {
                            Label("重新下载当前章节", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.currentChapter == nil)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await model.clearCache()
                            await refreshSize()
                        }
                    } label: {
                        Label("清理本书缓存", systemImage: "trash")
                    }
                }

                Section {
                    NavigationLink {
                        ReaderSettingsSheet(initialSection: .cache)
                    } label: {
                        Label("缓存设置", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("离线缓存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refreshSize() }
            .onChange(of: model.cachedChapterCount) { _, _ in
                Task { await refreshSize() }
            }
        }
    }

    private func refreshSize() async {
        size = await app.store.cachedSize(bookID: model.book.id)
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
#endif
