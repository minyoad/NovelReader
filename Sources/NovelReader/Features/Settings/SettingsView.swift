#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    @State private var testing = false
    @State private var testResult: (text: String, isError: Bool)?
    @State private var showAIDocs = false
    @State private var cachedChapters = 0
    @State private var cacheSize: Int64 = 0
    @State private var speechCount = 0
    @State private var speechSize: Int64 = 0
    @StateObject private var voiceTester = TTSVoiceTester()
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 阅读

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

                // MARK: 朗读

                Section {
                    TTSSettingSections.engine($app.settings.tts)
                } header: {
                    Text("语音朗读")
                } footer: {
                    Text("系统朗读完全离线；Edge 音色更自然但需要联网；自定义接口可以指向本地部署的语音模型。")
                }

                Section {
                    TTSSettingSections.engineOptions($app.settings.tts)

                    Button {
                        voiceTester.preview(app.settings.tts)
                    } label: {
                        HStack {
                            Label("试听", systemImage: "play.circle")
                            Spacer()
                            switch voiceTester.state {
                            case .idle:
                                EmptyView()
                            case .loading:
                                ProgressView().controlSize(.small)
                            case .failed:
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .disabled(voiceTester.state == .loading)

                    if case .failed(let message) = voiceTester.state {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    // Only meaningful for the Edge engine, which is the one
                    // with a host to reach. A failing custom endpoint says
                    // everything in its own error already.
                    if app.settings.tts.engine == .edge {
                        Button {
                            showDiagnostics = true
                        } label: {
                            Label("朗读网络诊断", systemImage: "stethoscope")
                        }
                    }
                } header: {
                    Text(app.settings.tts.engine == .system ? "系统声音" : "音色与接口")
                }

                Section {
                    TTSSettingSections.cache($app.settings.tts)
                    LabeledContent("已缓存朗读", value: "\(speechCount) 句 · \(CacheSheet.formatted(speechSize))")
                    Button {
                        clearSpeechCache()
                    } label: {
                        Label("清理朗读缓存", systemImage: "waveform.slash")
                    }
                    .disabled(speechSize == 0)
                } header: {
                    Text("朗读缓存")
                } footer: {
                    Text("音频按句缓存，重复听同一段不会再联网。切换音色或语速会重新合成。")
                }

                if app.settings.tts.engine == .edge {
                    Section {
                        TTSSettingSections.proxy($app.settings.tts)
                    } header: {
                        Text("网络")
                    } footer: {
                        Text("默认直连，通常不需要填。注意：如果手机系统里开着代理 / VPN，Edge 朗读反而可能握手失败（报 TLS 错误）——那种情况和这里无关，关掉系统的代理即可。这一步只影响朗读，不影响抓书源。")
                    }
                }

                // MARK: AI

                Section {
                    Toggle("启用 AI 整理", isOn: $app.settings.ai.enabled)

                    Toggle("自动去广告", isOn: $app.settings.aiAutoClean)
                        .disabled(!app.settings.ai.enabled)

                    if app.settings.aiAutoClean {
                        Stepper(
                            "提前处理 \(app.settings.aiCleanAhead) 章",
                            value: $app.settings.aiCleanAhead,
                            in: 0...10
                        )
                        .disabled(!app.settings.ai.enabled)
                    }

                    Text("打开后，读到一章时会顺带把后面几章下载好、去掉广告，翻页就不用等。只有章节开头和结尾会交给 AI 检查，中间正文不动。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if app.settings.aiAutoClean && app.settings.aiCleanAhead == 0 {
                        Text("设为 0 就不会提前处理：翻到新章节时要等 AI 处理完才显示。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if app.settings.aiAutoClean && app.settings.aiCleanAhead == 0 {
                        Text("设为 0 就不会提前处理：翻到新章节时要等 AI 处理完才显示。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

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

                    Toggle("搜索时使用全部书源", isOn: $app.settings.searchAllSources)
                }

                // MARK: 数据

                Section("数据与缓存") {
                    LabeledContent("已缓存章节", value: "\(cachedChapters) 章")
                    LabeledContent("缓存占用", value: CacheSheet.formatted(cacheSize))

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

                Section {
                    ReaderSettingSections.cache($app.settings.cache)
                } header: {
                    Text("缓存")
                } footer: {
                    Text("预缓存会在后台下载接下来的几章，断网时仍可继续读。设为 0 章即关闭。每本上限为 0 表示不自动清理。")
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
            .sheet(isPresented: $showAIDocs) {
                RuleDocsView()
            }
            .sheet(isPresented: $showDiagnostics) {
                EdgeDiagnosticsView(proxy: app.settings.tts.proxy)
            }            .onChange(of: app.settings) { _, _ in
                app.saveSettings()
            }
            .onAppear { Task { await refreshCacheStats() } }
            .onDisappear {
                app.saveSettings()
                voiceTester.stop()
            }
        }
    }

    private func refreshCacheStats() async {
        var chapters = 0
        for book in app.books {
            chapters += await app.store.cachedChapterCount(bookID: book.id)
        }
        cachedChapters = chapters
        cacheSize = await app.store.totalCachedSize()
        speechCount = await app.store.speechCacheCount()
        speechSize = await app.store.speechCacheSize()
    }

    private func clearSpeechCache() {
        Task {
            let result = await app.store.clearSpeechCache()
            await refreshCacheStats()
            app.showBanner("已删除 \(result.removed) 段朗读缓存，释放 \(CacheSheet.formatted(result.freed))", isError: false)
        }
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
        ("不支持", "@js: 与 <js> 不执行；影响范围会标在书源列表里"),
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
