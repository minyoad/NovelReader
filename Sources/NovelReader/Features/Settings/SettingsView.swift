#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// The settings tab's top level: one row per topic, each opening a page.
///
/// This used to be a single `Form` with roughly forty rows in ten sections.
/// That works until it does not: finding the User-Agent field meant scrolling
/// past every reading slider and every TTS voice, and the one field someone
/// changes twice a year was buried in the middle of the longest page in the
/// app. Splitting by topic means the first screen is a short list of names —
/// the thing a person actually knows they are looking for — and the rows live
/// one level down.
///
/// Deliberately `NavigationLink` and not a search field: with six topics, the
/// list is shorter than a keyboard is tall, and typing a search term to find
/// "同步" is more work than tapping it.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showAIDocs = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ReadingSettingsPage()
                    } label: {
                        SettingsRow(
                            icon: "textformat.size",
                            tint: .blue,
                            title: "阅读",
                            detail: readingSummary
                        )
                    }

                    NavigationLink {
                        SpeechSettingsPage()
                    } label: {
                        SettingsRow(
                            icon: "waveform",
                            tint: .indigo,
                            title: "朗读",
                            detail: speechSummary
                        )
                    }

                    NavigationLink {
                        AISettingsPage()
                    } label: {
                        SettingsRow(
                            icon: "sparkles",
                            tint: .purple,
                            title: "AI 整理",
                            detail: app.settings.ai.enabled ? "已启用" : "已关闭"
                        )
                    }
                }

                Section {
                    NavigationLink {
                        NetworkSettingsPage()
                    } label: {
                        SettingsRow(
                            icon: "network",
                            tint: .teal,
                            title: "网络",
                            detail: "\(Int(app.settings.network.timeout)) 秒超时"
                        )
                    }

                    NavigationLink {
                        SyncSettingsPage()
                    } label: {
                        SettingsRow(
                            icon: "arrow.triangle.2.circlepath",
                            tint: .green,
                            title: "同步",
                            detail: syncSummary
                        )
                    }

                    NavigationLink {
                        StorageSettingsPage()
                    } label: {
                        SettingsRow(
                            icon: "internaldrive",
                            tint: .orange,
                            title: "缓存与数据",
                            detail: nil
                        )
                    }
                }

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
            // Back-from-a-page should say where you came from, not "设置"
            // twice in a row.
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAIDocs) {
                RuleDocsView()
            }
            .onDisappear { app.saveSettings() }
        }
    }

    /// One line of context per topic, so the list answers "is it on?" without
    /// opening anything.
    private var readingSummary: String {
        let count = app.settings.reading.fontSize
        return "字号 \(Int(count)) pt"
    }

    private var speechSummary: String {
        switch app.settings.tts.engine {
        case .system: return "系统声音"
        case .edge: return "Edge 音色"
        case .openAICompatible: return "自定义接口"
        }
    }

    private var syncSummary: String {
        guard app.settings.sync.enabled, app.settings.sync.isUsable else { return "未开启" }
        switch app.settings.sync.backend {
        case .webdav: return "WebDAV"
        case .s3: return "S3"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// One row in the settings list: a tinted icon, a name, and a status.
///
/// The system's `Label` with a tint is the same idea but the icon colours in a
/// list of six blur together; a fixed 28 pt tile gives each topic a shape the
/// eye can land on without reading.
private struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
