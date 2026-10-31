#if canImport(UIKit)
import UIKit

/// Holds iOS awake while a chapter is being fetched for background playback.
///
/// Audio keeps an app alive in the background, but only while something is
/// actually playing. A chapter boundary has a gap — the last chunk finished,
/// the next chapter still has to be downloaded, split into sentences and its
/// first chunk synthesized — and that gap can outlast the few seconds iOS
/// grants before suspending. Without an assertion the app would stop mid-book
/// every time a chapter ended with the screen locked.
///
/// The assertion is a safety net, not the mechanism: audio still does the real
/// work. It only has to cover the silent moments.
@MainActor
final class BackgroundGrace {
    private var token: UIBackgroundTaskIdentifier = .invalid

    /// Starts (or extends) the grace period. Safe to call repeatedly.
    func begin(reason: String) {
        guard token == .invalid else { return }
        token = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            // Expiry: iOS is out of patience. Ending here is required, and
            // saying so explicitly is better than being killed.
            Task { @MainActor in self?.end() }
        }
    }

    /// Ends the grace period, e.g. once audio is flowing again.
    func end() {
        guard token != .invalid else { return }
        let token = self.token
        self.token = .invalid
        UIApplication.shared.endBackgroundTask(token)
    }
}
#endif
