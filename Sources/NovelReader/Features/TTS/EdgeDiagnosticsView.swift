#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Runs `EdgeDiagnostics` and shows the result inline.
///
/// The point is to answer "why is there no voice" on the device itself. Each
/// row is one layer, so the first failing row says where to look: DNS/TLS means
/// the network, while a failure only on the WebSocket row means the protocol.
struct EdgeDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    /// The proxy to test through, taken from the settings at the moment the
    /// sheet opens, so the report describes the configuration on screen.
    var proxy: String = ""
    @State private var steps: [EdgeDiagnosticStep] = []
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if steps.isEmpty && !isRunning {
                        Text("点上面的按钮开始检测。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                icon(for: step.level)
                                Text(step.title)
                                    .font(.subheadline.weight(.medium))
                            }
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("检测结果")
                } footer: {
                    Text("「HTTPS」能通过、但「朗读」失败，说明网络通、只是 WebSocket 被拒绝；两行都失败多半是手机的网络环境（系统代理 / VPN / 网络限制）。这里填的代理只在朗读时使用。")
                }
            }
            .navigationTitle("朗读网络诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await run() }
                    } label: {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("重新检测")
                        }
                    }
                    .disabled(isRunning)
                }
            }
            .task { await run() }
        }
    }

    @ViewBuilder
    private func icon(for level: EdgeDiagnosticStep.Level) -> some View {
        switch level {
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }

    private func run() async {
        isRunning = true
        steps = await EdgeDiagnostics.run(proxy: proxy)
        isRunning = false
    }
}
#endif
