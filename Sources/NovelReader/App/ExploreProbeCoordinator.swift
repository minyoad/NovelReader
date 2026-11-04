#if canImport(SwiftUI)
import Foundation
import NovelKit

/// Shared state for the discover-page check.
///
/// The requests run concurrently off the main actor, but two things have to be
/// decided at that point rather than after the reply comes back: whether the
/// host has already proved itself dead, and how many failures this source has
/// piled up. Doing it here keeps the request free of actor hops, and the
/// counters are locked because several tasks touch them at once.
final class ExploreProbeCoordinator: @unchecked Sendable {
    /// Hosts that did not answer. Every further tab on such a host is skipped
    /// instead of waiting out its own timeout.
    private var deadHosts: Set<String> = []
    /// How many tabs of each source have failed.
    private var failures: [UUID: Int] = [:]
    private let lock = NSLock()

    /// A tab fails this many times before the rest of its source is skipped.
    ///
    /// Checking every tab of a source that already failed twice only burns
    /// timeouts; one that is merely old has usually shown a working tab by
    /// then.
    static let failuresBeforeSkipping = 2

    func reset() {
        lock.lock()
        deadHosts.removeAll()
        failures.removeAll()
        lock.unlock()
    }

    func isDead(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadHosts.contains(host)
    }

    func markDead(host: String) {
        lock.lock()
        deadHosts.insert(host)
        lock.unlock()
    }

    func recordFailure(source: UUID) {
        lock.lock()
        failures[source, default: 0] += 1
        lock.unlock()
    }

    func failureCount(source: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return failures[source] ?? 0
    }

    func shouldSkip(source: UUID) -> Bool {
        failureCount(source: source) >= Self.failuresBeforeSkipping
    }
}
#endif
