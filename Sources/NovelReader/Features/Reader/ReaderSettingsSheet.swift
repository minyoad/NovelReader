#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Reading + speech preferences, edited in place. Every change is written
/// through `AppModel.saveSettings()` so the reader and TTS pick it up at once.
struct ReaderSettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    private var voices: [AVSpeechVoiceOption] {
        SpeechController.availableChineseVoices().map {
            AVSpeechVoiceOption(id: $0.identifier, name: $0.name)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("排版") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(app.settings.reading.fontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.reading.fontSize, in: 14...30, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("行距")
                            Spacer()
                            Text(String(format: "%.0f", app.settings.reading.lineSpacing))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.reading.lineSpacing, in: 0...24, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("段距")
                            Spacer()
                            Text(String(format: "%.0f", app.settings.reading.paragraphSpacing))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.reading.paragraphSpacing, in: 0...32, step: 2)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("左右边距")
                            Spacer()
                            Text(String(format: "%.0f", app.settings.reading.horizontalPadding))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.reading.horizontalPadding, in: 8...48, step: 2)
                    }
                }

                Section("翻页") {
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

                Section("背景") {
                    Picker("主题", selection: $app.settings.reading.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("朗读") {
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

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("音调")
                            Spacer()
                            Text(String(format: "%.2f", app.settings.tts.pitch))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $app.settings.tts.pitch, in: 0.6...1.6, step: 0.05)
                    }

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
}

struct AVSpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}
#endif
