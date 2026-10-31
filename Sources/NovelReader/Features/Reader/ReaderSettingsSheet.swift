#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Reading + speech + cache preferences, edited in place. Every change is
/// written through `AppModel.saveSettings()` so the reader and TTS pick it up
/// at once.
struct ReaderSettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Which section to scroll to when opened from a deep link (e.g. the cache
    /// sheet). `nil` shows the default order.
    var initialSection: Section?

    enum Section: String, CaseIterable, Identifiable {
        case typography
        case pageTurn
        case theme
        case ai
        case cache
        case tts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .typography: return "排版"
            case .pageTurn: return "翻页"
            case .theme: return "背景"
            case .ai: return "AI 整理"
            case .cache: return "缓存"
            case .tts: return "朗读"
            }
        }
    }

    private var voices: [AVSpeechVoiceOption] {
        SpeechController.availableChineseVoices().map {
            AVSpeechVoiceOption(id: $0.identifier, name: $0.name)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    typographySection.id(Section.typography.id)
                    pageTurnSection.id(Section.pageTurn.id)
                    themeSection.id(Section.theme.id)
                    aiSection.id(Section.ai.id)
                    cacheSection.id(Section.cache.id)
                    ttsSection.id(Section.tts.id)
                }
                .onAppear {
                    guard let initialSection else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo(initialSection.id, anchor: .top) }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        app.saveSettings()
                        dismiss()
                    }
                }
            }
            .onChange(of: app.settings) { _, _ in
                app.saveSettings()
            }
        }
    }

    // MARK: - Typography

    private var typographySection: some View {
        SwiftUI.Section("排版") {
            sliderRow(
                title: "字号",
                value: $app.settings.reading.fontSize,
                range: 14...30,
                step: 1,
                format: { "\(Int($0)) pt" }
            )

            sliderRow(
                title: "行距",
                value: $app.settings.reading.lineSpacing,
                range: 0...24,
                step: 1,
                format: { String(format: "%.0f", $0) }
            )

            sliderRow(
                title: "段距",
                value: $app.settings.reading.paragraphSpacing,
                range: 0...32,
                step: 2,
                format: { String(format: "%.0f", $0) }
            )

            sliderRow(
                title: "左右边距",
                value: $app.settings.reading.horizontalPadding,
                range: 8...48,
                step: 2,
                format: { String(format: "%.0f", $0) }
            )

            Picker("对齐", selection: $app.settings.reading.alignment) {
                ForEach(BodyAlignment.allCases) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            .pickerStyle(.segmented)

            Toggle("首行缩进两字", isOn: $app.settings.reading.firstLineIndent)

            Toggle("正文显示章节标题", isOn: $app.settings.reading.showChapterTitle)

            Picker("字体", selection: fontFamilyBinding) {
                Text("系统衬线（推荐中文）").tag("")
                Text("系统无衬线").tag("-apple-system")
                Text("苹方 PingFang SC").tag("PingFangSC-Regular")
                Text("宋体 Songti SC").tag("SongtiSC-Regular")
                Text("楷体 Kaiti SC").tag("KaitiSC-Regular")
                Text("圆体 Yuanti SC").tag("YuantiSC-Regular")
            }

            Text("小说正文用衬线或宋体更耐读；楷体适合短篇。选中的字体缺字时会自动回退到系统字体。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { app.settings.reading.fontFamily ?? "" },
            set: { value in
                app.settings.reading.fontFamily = value.isEmpty ? nil : value
            }
        )
    }

    // MARK: - Page turn

    private var pageTurnSection: some View {
        SwiftUI.Section("翻页") {
            Picker("方式", selection: $app.settings.reading.pageTurnMode) {
                ForEach(PageTurnMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if app.settings.reading.pageTurnMode == .page {
                Picker("效果", selection: $app.settings.reading.pageTurnEffect) {
                    ForEach(PageTurnEffect.allCases) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        SwiftUI.Section("背景") {
            Picker("主题", selection: $app.settings.reading.theme) {
                ForEach(ReaderTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        SwiftUI.Section {
            Picker("整理后格式", selection: $app.settings.aiOutputFormat) {
                ForEach(AIPrompt.OutputFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            Text(app.settings.aiOutputFormat.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if app.settings.aiOutputFormat == .continuous {
                Label("连排后段落不再分行，长章节会显得很密", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if !app.settings.ai.isUsable {
                Label("还没有配置 AI 服务", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 整理")
        } footer: {
            Text("格式只影响 AI 整理后的排版，原文缓存仍然保留，可以随时还原。")
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        SwiftUI.Section {
            Stepper(
                "阅读时预缓存 \(app.settings.cache.prefetchCount) 章",
                value: $app.settings.cache.prefetchCount,
                in: 0...20
            )

            Stepper(
                app.settings.cache.maxCachedChaptersPerBook == 0
                    ? "每本最多缓存：不限"
                    : "每本最多缓存 \(app.settings.cache.maxCachedChaptersPerBook) 章",
                value: $app.settings.cache.maxCachedChaptersPerBook,
                in: 0...3000,
                step: 50
            )

            Toggle("加入书架时缓存全本", isOn: $app.settings.cache.autoCacheOnAdd)
        } header: {
            Text("缓存")
        } footer: {
            Text("预缓存会在后台下载接下来的几章，断网时仍可继续读。设为 0 章即关闭。每本上限为 0 表示不自动清理。")
        }
    }

    // MARK: - TTS

    private var ttsSection: some View {
        SwiftUI.Section("朗读") {
            sliderRow(
                title: "语速",
                value: $app.settings.tts.rate,
                range: 0.2...0.9,
                step: 0.05,
                format: { String(format: "%.2fx", $0) }
            )

            sliderRow(
                title: "音调",
                value: $app.settings.tts.pitch,
                range: 0.6...1.6,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )

            Picker("声音", selection: Binding(
                get: { app.settings.tts.voiceIdentifier ?? "" },
                set: { identifier in
                    app.settings.tts.voiceIdentifier = identifier.isEmpty ? nil : identifier
                    app.settings.tts.voiceName = voices.first { $0.id == identifier }?.name
                    app.saveSettings()
                }
            )) {
                Text("系统默认（中文）").tag("")
                ForEach(voices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }

            Toggle("读完自动下一章", isOn: $app.settings.tts.autoNextChapter)
        }
    }

    // MARK: - Helpers

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

struct AVSpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}
#endif
