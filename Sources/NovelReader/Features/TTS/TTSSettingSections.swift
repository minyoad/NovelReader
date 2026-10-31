#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Rows for the speech engine, shared by the settings tab.
///
/// Kept out of `SettingsView` because the remote-engine block is long enough
/// that having it inline buried the AI section, and because the same rows are
/// likely to move into the reader sheet once engine switching is useful
/// mid-chapter.
///
/// Main-actor bound because it reads `SpeechController`'s voice list, which is
/// main-actor isolated like the rest of the audio layer.
@MainActor
enum TTSSettingSections {
    // MARK: - Engine

    @ViewBuilder
    static func engine(_ tts: Binding<TTSSettings>) -> some View {
        Picker("朗读引擎", selection: tts.engine) {
            ForEach(TTSEngine.allCases) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()

        Text(tts.wrappedValue.engine.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)

        slider(
            title: "语速",
            value: tts.rate,
            range: 0.25...1.0,
            step: 0.05
        ) { String(format: "%.2fx", $0) }

        if tts.wrappedValue.rate < 0.35 {
            Text("再慢一些会让部分音色听起来断续。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        Toggle("读完自动下一章", isOn: tts.autoNextChapter)
    }

    // MARK: - Voices

    @ViewBuilder
    static func engineOptions(_ tts: Binding<TTSSettings>) -> some View {
        switch tts.wrappedValue.engine {
        case .system:
            systemVoicePicker(tts)
        case .edge:
            edgeVoicePicker(tts)
        case .openAICompatible:
            customEndpoint(tts)
        }
    }

    @ViewBuilder
    private static func systemVoicePicker(_ tts: Binding<TTSSettings>) -> some View {
        let voices = SpeechController.availableChineseVoices()

        Picker("声音", selection: Binding(
            get: { tts.wrappedValue.voiceIdentifier ?? "" },
            set: { identifier in
                tts.wrappedValue.voiceIdentifier = identifier.isEmpty ? nil : identifier
                tts.wrappedValue.voiceName = voices.first { $0.identifier == identifier }?.name
            }
        )) {
            Text("系统默认（中文）").tag("")
            ForEach(voices, id: \.identifier) { voice in
                Text(voice.name).tag(voice.identifier)
            }
        }

        Text("系统语音完全离线，但长句偏机械。可以在「设置 → 辅助功能 → 朗读内容」里下载更多中文语音，下载后会出现在上面的列表里。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private static func edgeVoicePicker(_ tts: Binding<TTSSettings>) -> some View {
        Picker("音色", selection: tts.remote.edgeVoice) {
            ForEach(EdgeVoiceCatalog.chinese) { voice in
                VStack(alignment: .leading) {
                    Text(voice.name)
                    if let detail = voice.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tag(voice.id)
            }
        }

        if tts.wrappedValue.remote.edgeVoice.hasPrefix("zh-HK")
            || tts.wrappedValue.remote.edgeVoice.hasPrefix("zh-TW") {
            Text("这是粤语 / 台湾口音，普通话正文读起来会不自然。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        Text("Edge 朗读免费、无需注册，音色接近真人。它是微软的未公开接口，需要联网，也可能随时失效——那时换回系统朗读即可。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private static func customEndpoint(_ tts: Binding<TTSSettings>) -> some View {
        LabeledContent("接口地址") {
            TextField("http://127.0.0.1:8880/v1", text: tts.remote.baseURL)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }

        LabeledContent("模型") {
            TextField("tts-1", text: tts.remote.model)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }

        LabeledContent("音色") {
            TextField("alloy", text: tts.remote.voice)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }

        HStack {
            Text("API Key")
            Spacer()
            SecureField("可留空", text: tts.remote.apiKey)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }

        if !tts.wrappedValue.isRemoteUsable && !tts.wrappedValue.remote.baseURL.isEmpty {
            Text("接口地址或模型还不完整，朗读不会启动。")
                .font(.caption2)
                .foregroundStyle(.orange)
        }

        Text("任何兼容 OpenAI /audio/speech 的服务都可以：本地部署的 Kokoro、ChatTTS 网关，或云端服务。地址填到 /v1 即可，程序会自动补上 /audio/speech。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Proxy

    /// Optional HTTP proxy for the remote engines.
    ///
    /// Edge is blocked from some networks — mainland China resets the TLS
    /// handshake outright — and a proxy is the only workaround short of
    /// switching engines. Scoped to speech so book sources keep their own
    /// route.
    @ViewBuilder
    static func proxy(_ tts: Binding<TTSSettings>) -> some View {
        LabeledContent("代理（可选）") {
            TextField("host:port", text: tts.proxy)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }

        if tts.wrappedValue.proxy.isEmpty {
            Text("留空表示直连。只有朗读会走代理，抓书源仍然直连。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let parsed = SpeechProxy(tts.wrappedValue.proxy) {
            Text("将经由 \(parsed.displayName) 访问朗读接口。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("地址看不懂：请填 host:port，例如 192.168.1.5:7890（省略端口时按 7890 处理）。")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Cache

    @ViewBuilder
    static func cache(_ tts: Binding<TTSSettings>) -> some View {
        Toggle("缓存朗读音频", isOn: tts.cacheEnabled)

        if tts.wrappedValue.cacheEnabled {
            Stepper(
                "上限 \(tts.wrappedValue.cacheLimitMB) MB",
                value: tts.cacheLimitMB,
                in: 0...2000,
                step: 50
            )

            Text(tts.wrappedValue.cacheLimitMB == 0
                 ? "不限上限：听过的句子会一直留着，直到手动清理。"
                 : "超出上限时会先删掉最久没听过的句子。缓存按句保存，换音色或调速会重新合成。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("关闭后每次朗读都会重新请求，断网时无法朗读。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private static func slider(
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
#endif
