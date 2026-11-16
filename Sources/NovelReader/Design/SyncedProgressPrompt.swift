#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Installed on the root and the reader separately: the root's alert cannot
/// reliably present over a reader hosted in a full-screen cover.
struct SyncedProgressPrompt: ViewModifier {
    let advance: SyncProgressAdvance?
    let enabled: Bool
    let onStay: (SyncProgressAdvance) -> Void
    let onJump: (SyncProgressAdvance) -> Void

    func body(content: Content) -> some View {
        content.alert("发现更靠后的阅读进度", isPresented: Binding(
            get: { enabled && advance != nil },
            // Each explicit action resolves the proposal. SwiftUI also writes
            // false before dispatching actions, so the setter must not discard it.
            set: { _ in }
        ), presenting: advance) { advance in
            Button("保持本地位置", role: .cancel) { onStay(advance) }
            Button("跳转到远端进度") { onJump(advance) }
        } message: { advance in
            Text("《\(advance.remoteBook.name)》\n本地：\(advance.localProgress.positionDescription)\n远端：\(advance.remoteBook.progress.positionDescription)\n是否跳转到远端位置继续阅读？")
        }
    }
}
#endif
