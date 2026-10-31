#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    @State private var showReaderSettings = false
    @State private var testing = false
    @State private var testResult: (text: String, isError: Bool)?
    @State private var showAIDocs = false
    @State private var cachedChapters = 0
    @State private var cacheSize: Int64 = 0

    private var voices: [AVSpeechVoiceOption] {
        SpeechController.availableChineseVoices().map {
            AVSpeechVoiceOption(id: $0.identifier, name: $0.name)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 阅读

                Section {
                    Button {
                        showReaderSettings = true
                    } label: {
                        HStack {
                            Label("排版与主题", systemImage: "textformat.size")
                            Spacer()
                            Text("\(app.settings.reading.theme.displayName) · \(app.settings.reading.pageTurnMode.displayName)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Toggle("搜索时使用全部书源", isOn: $app.settings.searchAllSources)
                } header: {
                    Text("阅读")
                } footer: {
                    Text("关闭后搜索会优先使用书源列表中最上面的可用书源。")
                }

                // MARK: 朗读

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("语速")
                            Spacer()
                            Text(String(format: "%.2fx", app.settings.tts.rate))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.tts.rate, in: 0.2...0.9, step: 0.05)
                    }

                    Picker("声音", selection: Binding(
                        get: { app.settings.tts.voiceIdentifier ?? "" },
                        set: { identifier in
                            app.settings.tts.voiceIdentifier = identifier.isEmpty ? nil : identifier
                            app.settings.tts.voiceName = voices.first { $0.id == identifier }?.name
                        }
                    )) {
                        Text("系统默认（中文）").tag("")
                        ForEach(voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }

                    Toggle("读完自动下一章", isOn: $app.settings.tts.autoNextChapter)
                } header: {
                    Text("语音朗读")
                } footer: {
                    Text("可以在「设置 → 辅助功能 → 朗读内容」里下载更多中文语音，下载后会出现在上面的列表里。")
                }

                // MARK: AI

                Section {
                    Toggle("启用 AI 整理", isOn: $app.settings.ai.enabled)

                    Picker("整理后格式", selection: $app.settings.aiOutputFormat) {
                        ForEach(AIPrompt.OutputFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    Text(app.settings.aiOutputFormat.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Picker("服务", selection: Binding(
                        get: { app.settings.ai.preset },
                        set: { preset in
                            app.settings.ai.preset = preset
                            if preset != .custom {
                                app.settings.ai.baseURL = preset.defaultBaseURL
                                app.settings.ai.model = preset.defaultModel
                            }
                        }
                    )) {
                        ForEach(AIProviderPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }

                    LabeledContent("接口地址") {
                        TextField("https://api.example.com/v1", text: $app.settings.ai.baseURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    LabeledContent("模型") {
                        TextField("gpt-4o-mini", text: $app.settings.ai.model)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if app.settings.ai.preset.needsAPIKey || !app.settings.ai.apiKey.isEmpty {
                        HStack {
                            Text("API Key")
                            Spacer()
                            SecureField("sk-…", text: $app.settings.ai.apiKey)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    HStack {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            if testing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("测试中…")
                                }
                            } else {
                                Label("测试连接", systemImage: "bolt.horizontal")
                            }
                        }
                        .disabled(testing || app.settings.ai.baseURL.isEmpty || app.settings.ai.model.isEmpty)

                        Spacer()

                        if let testResult {
                            Text(testResult.text)
                                .font(.caption)
                                .foregroundStyle(testResult.isError ? .red : .green)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    DisclosureGroup("高级参数") {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", app.settings.ai.temperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.ai.temperature, in: 0...1.5, step: 0.05)

                        Stepper(
                            "最大输出 \(app.settings.ai.maxTokens) tokens",
                            value: $app.settings.ai.maxTokens,
                            in: 256...8192,
                            step: 256
                        )

                        Stepper(
                            "分块大小 \(app.settings.ai.chunkSize) 字",
                            value: $app.settings.ai.chunkSize,
                            in: 600...4000,
                            step: 200
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("额外整理要求")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $app.settings.ai.customInstruction)
                                .font(.footnote)
                                .frame(minHeight: 70)
                        }
                    }
                } header: {
                    Text("AI 整理")
                } footer: {
                    Text("使用 OpenAI 兼容接口（/chat/completions）。AI Key 保存在系统钥匙串，不写入普通配置文件。整理结果会覆盖当前章节的缓存。")
                }

                // MARK: 网络

                Section("网络") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("User-Agent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("User-Agent", text: $app.settings.network.userAgent, axis: .vertical)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Stepper(
                        "超时 \(Int(app.settings.network.timeout)) 秒",
                        value: $app.settings.network.timeout,
                        in: 5...60,
                        step: 5
                    )

                    Toggle("使用 Cookie", isOn: $app.settings.network.useCookies)
                }

                // MARK: 数据

                Section("数据与缓存") {
                    LabeledContent("已缓存章节", value: "\(cachedChapters) 章")
                    LabeledContent("缓存占用", value: CacheSheet.formatted(cacheSize))

                    NavigationLink {
                        ReaderSettingsSheet(initialSection: .cache)
                    } label: {
                        Label("缓存设置", systemImage: "arrow.down.circle")
                    }

                    Button {
                        clearChapterCache()
                    } label: {
                        Label("清理章节缓存", systemImage: "trash.slash")
                    }
                    if let banner = app.banner {
                        Text(banner.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: 关于

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("书源", value: "\(app.sources.filter(\.enabled).count) 个已启用 / \(app.sources.count) 个")
                    LabeledContent("书架", value: "\(app.books.count) 本")
                    Button {
                        showAIDocs = true
                    } label: {
                        Label("书源规则说明", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showReaderSettings) {
                ReaderSettingsSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAIDocs) {
                RuleDocsView()
            }
            .onChange(of: app.settings) { _, _ in
                app.saveSettings()
            }
            .onAppear { Task { await refreshCacheStats() } }
            .onDisappear { app.saveSettings() }
        }
    }

    private func refreshCacheStats() async {
        var chapters = 0
        for book in app.books {
            chapters += await app.store.cachedChapterCount(bookID: book.id)
        }
        cachedChapters = chapters
        cacheSize = await app.store.totalCachedSize()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        defer { testing = false }

        app.saveSettings()
        var configuration = app.settings.ai
        configuration.enabled = true
        let client = AIClient(configuration: configuration)
        do {
            let answer = try await client.chat(
                system: "你是一个测试助手。只回复两个字：正常。",
                user: "测试"
            )
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            testResult = (text: "连接正常：\(trimmed.prefix(20))", isError: false)
        } catch {
            testResult = (text: error.localizedDescription, isError: true)
        }
    }

    private func clearChapterCache() {
        Task {
            for book in app.books {
                await app.store.clearChapterCache(bookID: book.id)
            }
            await refreshCacheStats()
            app.showBanner("章节缓存已清理，下次阅读会重新下载", isError: false)
        }
    }
}

private struct RuleDocsView: View {
    @Environment(\.dismiss) private var dismiss

    private let lines: [(String, String)] = [
        ("CSS", "@css:.book-list li a@href"),
        ("legado 路径", "class.book-list@tag.li@tag.a@href"),
        ("XPath", "@XPath://div[@id='list']//dd/a/@href"),
        ("JSONPath", "$.data.list[*].name"),
        ("回退链", "规则A@@规则B，A 为空时用 B"),
        ("正则替换", "规则##\\\\s+##"),
        ("变量", "搜索地址里的 {{key}}、{{page}}"),
        ("正文", "规则配上 @html 可以保留段落结构"),
        ("不支持", "@js: 与 <js> 规则会被跳过"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("支持的规则语法") {
                    ForEach(lines, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.0).font(.caption).foregroundStyle(.secondary)
                            Text(item.1)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("示例书源") {
                    Text(BuiltinContent.exampleLegadoJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section {
                    Text("从「阅读 / legado」导出的书源 JSON 可以直接粘贴导入。解析失败的规则会保留原文，方便你手动调整。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("书源规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
#endif
