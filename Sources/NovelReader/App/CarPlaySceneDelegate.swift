#if canImport(CarPlay) && canImport(UIKit)
import CarPlay
import UIKit

/// Puts the app on CarPlay's "Now Playing" surface.
///
/// The reader has no CarPlay UI of its own: listening is driven entirely through
/// `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, which
/// `NowPlayingCenter` already owns. All this scene has to do is exist — without
/// a `CPTemplateApplicationScene` the system never offers the app to the car
/// head unit at all, no matter what the app publishes.
///
/// The connection is left without a template on purpose. A full template
/// hierarchy would mean re-implementing the shelf and reader on a 800×480
/// screen, and Apple requires a separate entitlement review for that. An audio
/// app only needs the system player, which CarPlay draws itself from the Now
/// Playing information.
///
/// This scene shares the app's process, so `MPRemoteCommandCenter` targets
/// installed by `SpeechController` answer the car's buttons directly; nothing
/// has to be forwarded across processes.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// Kept so the connection is not deallocated while the car is attached.
    ///
    /// CarPlay holds the delegate weakly through the scene, and the interface
    /// controller must stay alive for the session to remain valid.
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        // No template is set: an audio app is shown through the system's player
        // instead of an app-drawn screen.
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    /// Required by the protocol, but this app shows no navigation alerts.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didSelect navigationAlert: CPNavigationAlert
    ) {
        // Nothing to do: no navigation content is presented on the car screen.
    }
}
#endif
