#if canImport(SwiftUI)
import SwiftUI
import NovelKit
#if canImport(UIKit)
import UIKit
#endif

/// Shows the discover page's diagnostic log for the current session.
///
/// Temporary: the log exists to work out why third-party sources fail, and this
/// screen is the fastest way to get that text off the device without a cable.
struct ExploreLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = "(空)"
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("发现页日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = text
                    copied = true
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = ExploreLog.currentFileURL else {
            text = "(没有日志文件)"
            return
        }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = content.isEmpty ? "(本次会话还没有日志)" : content
    }
}
#endif
