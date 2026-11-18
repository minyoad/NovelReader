#if canImport(UIKit)
import SwiftUI
import UIKit

/// Keeps the display awake while a book is open.
///
/// iOS sleeps the screen after two idle minutes. A page reader can easily sit
/// on one page longer than that, and the result reads as the app quitting: the
/// book vanishes, the phone asks for a passcode, and the chapter has to be
/// found again. Raising `isIdleTimerDisabled` is the one supported way to stop
/// that, and it has to be released the moment the reader goes away — leaving
/// it on would keep the whole phone's screen lit from anywhere in the app.
enum ScreenAwake {    /// Applies the user's preference. Idempotent: the reader calls it on
    /// appearance and again whenever the toggle changes.
    static func apply(_ enabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = enabled
    }

    /// Hands the idle timer back to the system.
    ///
    /// Called unconditionally on disappear rather than only when the setting
    /// was on: whichever path went wrong, the phone must not be left with an
    /// idle timer that never fires.
    static func release() {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

#endif
