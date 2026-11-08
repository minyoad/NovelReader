#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Speech settings: engine, voice, preview, and the Edge proxy.
///
/// The proxy lives here rather than on 网络 because it only affects Edge TTS —
/// a proxy that fixes speech would otherwise look like it should fix page
/// fetching too.
struct SpeechSettingsPage: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var voiceTester = TTSVoiceTester()
    @State private var showDiagnostics = false

    var body: some View {
        Form {
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

                // Only meaningful for the Edge engine, which is the one with a
                // host to reach. A failing custom endpoint says everything in
                // its own error already.
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

            if app.settings.tts.engine == .edge {
                Section {
                    TTSSettingSections.proxy($app.settings.tts)
                } header: {
                    Text("网络")
                } footer: {
                    Text("默认直连，通常不需要填。注意：如果手机系统里开着代理 / VPN，Edge 朗读反而可能握手失败（报 TLS 错误）——那种情况和这里无关，关掉系统的代理即可。这一步只影响朗读，不影响抓书源。")
                }
            }
        }
        .navigationTitle("朗读")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDiagnostics) {
            EdgeDiagnosticsView(proxy: app.settings.tts.proxy)
        }
        .onChange(of: app.settings) { _, _ in
            // Persisting is the app's job (it does it for every change); this
            // hook is only needed to restart the voice tester's preview when
            // the settings it was started with go stale.
            voiceTester.stop()
        }
        .onDisappear {
            voiceTester.stop()
        }
    }
}

/// AI cleanup: what is enabled, which service, which key, and the tuning knobs.
///
/// Everything that was one giant section, with the rarely-touched parameters
/// still folded away in 高级参数.
struct AISettingsPage: View {
    @EnvironmentObject private var app: AppModel
    @State private var testing = false
    @State private var testResult: (text: String, isError: Bool)?
    @FocusState private var focusedField: Bool

    /// Shown under the chunk-size stepper: the user's number is capped by what
    /// the output budget can actually return.
    private var effectiveChunkSize: Int {
        AutoCleanup.effectiveChunkLength(
            chunkSize: app.settings.ai.chunkSize,
            maxTokens: app.settings.ai.maxTokens
        )
    }

    var body: some View {
        Form {
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

                Text("打开后，读到一章时会顺带把后面几章下载好、去掉广告，翻页就不用等。整章都会交给 AI 检查（广告可能夹在段落中间），分块并发发送，所以不会明显变慢。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if app.settings.aiAutoClean && app.settings.aiCleanAhead == 0 {
                    Text("设为 0 就不会提前处理：翻到新章节时要等 AI 处理完才显示。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("整理")
            } footer: {
                Text("整理结果会覆盖当前章节的缓存。")
            }

            Section {
                Picker("整理后格式", selection: $app.settings.aiOutputFormat) {
                    ForEach(AIPrompt.OutputFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Text(app.settings.aiOutputFormat.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("格式")
            }

            Section {
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
                        .focused($focusedField)
                }

                LabeledContent("模型") {
                    TextField("gpt-4o-mini", text: $app.settings.ai.model)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField)
                }

                if app.settings.ai.preset.needsAPIKey || !app.settings.ai.apiKey.isEmpty {
                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("sk-…", text: $app.settings.ai.apiKey)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField)
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

                    // The output budget caps how much can come back, so a chunk
                    // larger than that is guaranteed to be cut off. Showing the
                    // effective number stops the two settings from silently
                    // disagreeing.
                    Text("受「最大输出」限制，实际每块不超过 \(effectiveChunkSize) 字。")
                        .font(.caption2)
                        .foregroundStyle(app.settings.ai.chunkSize > effectiveChunkSize ? .orange : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("额外整理要求")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $app.settings.ai.customInstruction)
                            .font(.footnote)
                            .frame(minHeight: 70)
                            .focused($focusedField)
                    }
                }
            } header: {
                Text("服务与凭据")
            } footer: {
                Text("使用 OpenAI 兼容接口（/chat/completions）。AI Key 保存在系统钥匙串，不写入普通配置文件。")
            }
        }
        .navigationTitle("AI 整理")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = false }
            }
        }
        .onDisappear { app.saveSettings() }
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
}
#endif
