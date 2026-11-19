import Foundation

/// When a failed speech request is worth retrying, and how long to wait.
///
/// Lives in `NovelKit` rather than beside the controller so the numbers can be
/// tested on a machine without AVFoundation: "how long before the reader gives
/// up" is a product decision, not a platform detail, and it is the decision
/// that was wrong when a two-second outage ended a listening session.
public enum SpeechRetryRules {

    /// How long to wait after the `attempt`-th consecutive failure.
    ///
    /// Fast at first — the common case is a single dropped packet, and
    /// resuming half a second late is better than a spinner — then a flat six
    /// seconds. Ramping to a minute would suit a server under load; this is a
    /// phone that lost its signal, and the waiting should stay short enough
    /// that a recovered network is noticed quickly.
    ///
    /// The sequence is `0.5s, 1s, 2s, 4s, 6s, 6s, …` and never ends: reading
    /// aloud in a car outlasts any outage worth giving up on.
    public static func retryDelay(afterFailure attempt: Int) -> Int {
        switch attempt {
        case 1: return 500
        case 2: return 1_000
        case 3: return 2_000
        case 4: return 4_000
        default: return 6_000
        }
    }

    /// Whether a failure will stay a failure however long it is retried.
    ///
    /// A rejected token or an empty body comes back the same every time, so
    /// waiting only delays the message the reader needs to see.
    public static func isPermanent(_ error: Error) -> Bool {
        if case EdgeTTSError.tokenRejected = error { return true }
        if case EdgeTTSError.noAudio = error { return true }
        if let provider = error as? ProviderSpeechError {
            switch provider {
            case .configuration, .invalidAudio: return true
            case .http(let status): return (400...499).contains(status) && status != 408 && status != 429
            case .service(let code): return code == 45000000 || code == 40402003
            case .incomplete: return false
            }
        }
        return false
    }
}
