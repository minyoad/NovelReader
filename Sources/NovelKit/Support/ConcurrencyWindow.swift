import Foundation

/// Runs async work with a cap on how many run at once.
///
/// The search page is where the cap matters: a shelf with several hundred
/// sources would otherwise put every one of them on the network at the same
/// moment, each with its own retry budget and HTML parse. The phone's link
/// saturates, the CPU is busy on results nobody has scrolled to yet, and the
/// list stops responding to a drag — which reads as the app having hung rather
/// than as a search still running.
///
/// A window rather than a semaphore: the work is started from here, so a slot
/// frees up the moment a result arrives and the next item starts immediately
/// instead of waiting for a batch to drain.
///
/// Results are delivered as they complete, not in input order — the caller is
/// accumulating them anyway, and waiting to reorder would bring back exactly
/// the "slowest source holds everything" behaviour the streaming was for.
public enum ConcurrencyWindow {
    /// How many search requests to have in flight at once.
    ///
    /// Twelve is roughly where a phone's connection stops being the
    /// bottleneck. Higher and the queue behind the network grows without the
    /// user seeing more; lower and a big search takes noticeably longer than
    /// it needs to.
    public static let searchSources = 12

    /// Runs `work` over `items`, never more than `limit` at a time, and calls
    /// `onEach` from the caller's actor as each result arrives.
    ///
    /// `onEach` runs on the main actor: for a search that is where the results
    /// end up anyway, and typing it that way makes the requirement the
    /// compiler's to check rather than a comment's. It is awaited, so a slow
    /// consumer slows the whole thing down instead of piling up results the
    /// consumer cannot show yet.
    @MainActor
    public static func forEach<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        limit: Int,
        work: @escaping @Sendable (Item) async -> Result,
        onEach: @escaping @MainActor (Result) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        let window = max(1, min(limit, items.count))

        await withTaskGroup(of: Result.self) { group in
            var pending = items[...]

            func startNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask {
                    await work(item)
                }
            }

            for _ in 0..<window { startNext() }
            while let result = await group.next() {
                // A slot just freed: start the next one immediately.
                startNext()
                await onEach(result)
            }
        }
    }
}
