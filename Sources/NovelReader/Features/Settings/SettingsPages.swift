#if canImport(SwiftUI)
import SwiftUI
import NovelKit
/// Reading preferences: typography, page turning, background, launch.
///
/// The same rows the reader's own settings sheet shows (`ReaderSettingSections`)
/// — this page is the place to find them, that sheet is the place to tweak them
/// mid-chapter without leaving the book.
struct ReadingSettingsPage: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        Form {
            Section {
                ReaderSettingSections.typography($app.settings.reading)
            } header: {
                Text("排版")
            } footer: {
                Text("小说正文用衬线或宋体更耐读；楷体适合短篇。选中的字体缺字时会自动回退到系统字体。")
            }
            Section {
                ReaderSettingSections.pageTurn($app.settings.reading)
            } header: {
                Text("翻页")
            } footer: {
                Text("「仿真」需要左右翻页模式才有意义；滚动模式下这一项不起作用。")
            }
            Section {
                ReaderSettingSections.background($app.settings.reading)
            } header: {
                Text("背景")
            } footer: {
                Text("开启「跟随系统深色模式」时，白天用所选主题，系统切到深色后自动换成相对应的深色主题（纸白/米黄 → 深灰）。关闭后固定使用所选主题。")
            }
            Section {
                ReaderSettingSections.startup($app.settings.reading)
            } header: {
                Text("启动")
            } footer: {
                Text("打开 App 时直接回到上次读到的位置；关闭后从书架开始。")
            }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Network behavior for fetching sources and chapter bodies.
///
/// Separate from AI and TTS on purpose: those have their own endpoints, and a
/// proxy here only affects grabbing pages from source sites.
struct NetworkSettingsPage: View {
    @EnvironmentObject private var app: AppModel
    @FocusState private var focusedField: Bool
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("User-Agent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("User-Agent", text: $app.settings.network.userAgent, axis: .vertical)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField)
                }
                Stepper(
                    "超时 \(Int(app.settings.network.timeout)) 秒",
                    value: $app.settings.network.timeout,
                    in: 5...60,
                    step: 5
                )
                Toggle("使用 Cookie", isOn: $app.settings.network.useCookies)
                Toggle("搜索时使用全部书源", isOn: $app.settings.searchAllSources)
            } footer: {
                Text("部分站点会按 User-Agent 返回不同页面；超时只影响抓取，不影响已经缓存的章节。打开「搜索时使用全部书源」会慢一些，但更容易找到冷门书。")
            }
        }
        .navigationTitle("网络")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = false }
            }
        }
    }
}

/// What is on disk and how to get rid of it.
///
/// Chapter cache, speech cache and the automatic cleanup limits were three
/// sections in different places; they are one concern — disk — and the numbers
/// only make sense next to the buttons that clear them.
struct StorageSettingsPage: View {
    @EnvironmentObject private var app: AppModel
    @State private var cachedChapters = 0
    @State private var cacheSize: Int64 = 0
    @State private var speechCount = 0
    @State private var speechSize: Int64 = 0
    var body: some View {
        Form {
            Section {
                ReaderSettingSections.cache($app.settings.cache)
            } header: {
                Text("预缓存")
            } footer: {
                Text("预缓存会在后台下载接下来的几章，断网时仍可继续读。设为 0 章即关闭。每本上限为 0 表示不自动清理。")
            }
            Section {
                LabeledContent("已缓存章节", value: "\(cachedChapters) 章")
                LabeledContent("缓存占用", value: CacheSheet.formatted(cacheSize))
                Button(role: .destructive) {
                    clearChapterCache()
                } label: {
                    Label("清理章节缓存", systemImage: "trash.slash")
                }
            } header: {
                Text("章节缓存")
            } footer: {
                Text("正文可以随时从书源重新下载，清理不会丢阅读进度。")
            }
            Section {
                TTSSettingSections.cache($app.settings.tts)
            } header: {
                Text("朗读缓存")
            } footer: {
                Text("音频按句缓存，重复听同一段不会再联网。切换音色或语速会重新合成。")
            }
            Section("朗读缓存占用") {
                LabeledContent("已缓存朗读", value: "\(speechCount) 句 · \(CacheSheet.formatted(speechSize))")
                Button(role: .destructive) {
                    clearSpeechCache()
                } label: {
                    Label("清理朗读缓存", systemImage: "waveform.slash")
                }
                .disabled(speechSize == 0)
            }
            if let banner = app.banner {
                Section {
                    Text(banner.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("缓存与数据")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await refreshStats() } }
    }
    private func refreshStats() async {
        var chapters = 0
        for book in app.books {
            chapters += await app.store.cachedChapterCount(bookID: book.id)
        }
        cachedChapters = chapters
        cacheSize = await app.store.totalCachedSize()
        speechCount = await app.store.speechCacheCount()
        speechSize = await app.store.speechCacheSize()
    }
    private func clearChapterCache() {
        Task {
            for book in app.books {
                await app.store.clearChapterCache(bookID: book.id)
            }
            await refreshStats()
            app.showBanner("章节缓存已清理，下次阅读会重新下载", isError: false)
        }
    }
    private func clearSpeechCache() {
        Task {
            let result = await app.store.clearSpeechCache()
            await refreshStats()
            app.showBanner("已删除 \(result.removed) 段朗读缓存，释放 \(CacheSheet.formatted(result.freed))", isError: false)
        }
    }
}

/// The sync page is a single section, but it owns focus for its password
/// field, so it needs the same keyboard dismissal the old all-in-one form had.
struct SyncSettingsPage: View {
    @FocusState private var focusedField: Bool
    var body: some View {
        Form {
            Section {
                SyncSettingsSection(focus: $focusedField)
            } footer: {
                Text("""
                同步书架、书源和阅读进度，在启动和退到后台时自动进行。两台设备的书会合并而不是互相覆盖；同一本书按阅读位置较新的那份为准，同一个书源、同一个详情页的同一本书只保留一份。
                章节正文不同步：它能从书源重新下载，同步它会让每次同步都很慢。
                """)
            }
        }
        .navigationTitle("同步")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = false }
            }
        }
    }
}
#endif
