#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Reading preferences shown as a sheet from inside the reader.
///
/// The settings *tab* renders the same controls inline (via
/// `ReaderSettingSections`), so reading preferences no longer feel like a
/// separate feature reached through a sheet.
///
/// This sheet still exists for the reader itself, where jumping to the settings
/// tab would mean leaving the book. It carries only what belongs to reading —
/// speech, AI and cache live in the settings tab, and having them in both places
/// meant two copies of the same controls that could drift apart.
struct ReaderSettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Which section to scroll to when opened from a deep link (the cache sheet
    /// linking to its own settings).
    ///
    /// Named `Anchor` rather than `Section` because a nested type named
    /// `Section` shadows `SwiftUI.Section` inside this struct, and every
    /// `Section { ... }` would resolve to the enum.
    var initialAnchor: Anchor?

    enum Anchor: String, CaseIterable, Identifiable {
        case typography
        case cache

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        ReaderSettingSections.typography($app.settings.reading)
                    } header: {
                        Text("排版")
                    }

                    Section {
                        ReaderSettingSections.pageTurn($app.settings.reading)
                    } header: {
                        Text("翻页")
                    }

                    Section {
                        ReaderSettingSections.background($app.settings.reading)
                    } header: {
                        Text("背景")
                    }
                    .id(Anchor.typography.id)

                    Section {
                        ReaderSettingSections.cache($app.settings.cache)
                    } header: {
                        Text("缓存")
                    } footer: {
                        Text("预缓存会在后台下载接下来的几章，断网时仍可继续读。设为 0 章即关闭。每本上限为 0 表示不自动清理。")
                    }
                    .id(Anchor.cache.id)
                }
                .onAppear {
                    guard let initialAnchor else { return }
                    // The form has not measured its rows on the first run loop,
                    // so `scrollTo` would be a silent no-op.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo(initialAnchor.id, anchor: .top) }
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
}

#endif
