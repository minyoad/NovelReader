#if canImport(Network)
import Foundation
import Network

/// Whether the device currently has a usable network path.
///
/// Retrying on a timer is fine while an outage lasts a minute; it is not fine
/// while driving, where a cell handover can last two seconds and a flat
/// several-second wait makes the book stutter for no reason. The retry loop
/// polls this so that the moment the path comes back it retries, instead of
/// sitting out the rest of the delay.
///
/// It is a hint, not the source of truth: the loop still retries on its own
/// schedule if the path never flips, and a route that stays "satisfied"
/// through an outage (a Wi-Fi router that answers but has no uplink) is simply
/// not helped by it. `NWPathMonitor` is the only thing that knows the carrier
/// dropped out, which is why it is used at all.
final class NetworkRecoveryMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.yang.NovelReader.network-recovery")
    private let lock = NSLock()
    private var satisfied = true

    /// Starts watching. Safe to call repeatedly.
    func start() {
        lock.lock()
        let alreadyStarted = didStart
        didStart = true
        lock.unlock()
        guard !alreadyStarted else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    private var didStart = false

    /// Whether a network path is up right now.
    ///
    /// Optimistic before the monitor has said anything: treating "no news yet"
    /// as an outage would make the first retry of a healthy session skip its
    /// backoff.
    var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }
}
#endif
