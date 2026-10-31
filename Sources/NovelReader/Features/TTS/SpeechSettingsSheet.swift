#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Speech settings reached from the reader's bottom bar.
///
/// The same rows as the settings tab (`TTSSettingSections`), shown here because
/// changing voice or speed is something you do *while listening*: leaving the
/// book to open the settings tab would stop the reading. Only the parts that
/// affect playback are here — the proxy and the diagnostics screen stay in the
/// settings tab, since neither is something you change mid-chapter and a wrong
/// proxy there would silently kill the current session.
struct SpeechSettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var speech: SpeechController
    /// Delays the engine rebuild while a slider is being dragged.
    ///
    /// `SpeechController.configure` restarts the current sentence so the new
    /// voice applies immediately. Firing that on every 0.05 step of the speed
    /// slider would restart the sentence a dozen times during one drag, so the
    /// restart waits for the value to settle.
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
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
                } header: {
                    Text("声音与音色")
                }

                Section {
                    TTSSettingSections.cache($app.settings.tts)
                } header: {
                    Text("缓存")
                }
            }
            .navigationTitle("朗读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // Rebuild the engine mid-chapter instead of waiting for the next
            // chapter: that is the whole point of changing the voice here.
            .onChange(of: app.settings.tts) { _, newValue in
                app.saveSettings()
                applyTask?.cancel()
                applyTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    speech.configure(newValue)
                }
            }
            .onDisappear {
                // Picking a voice and closing the sheet should apply at once
                // rather than waiting out the debounce.
                applyTask?.cancel()
                applyTask = nil
                speech.configure(app.settings.tts)
            }
        }
    }
}
#endif
