import Foundation

public struct DiscoveryRequest: Sendable {
    public let source: BookSource
    public let category: ExploreCategory
    public init(source: BookSource, category: ExploreCategory) { self.source = source; self.category = category }
}

public struct DiscoveryOutcome: Sendable {
    public let sourceID: UUID
    public let results: [SearchResult]
    public let error: String?
    public let latency: Double
    public var succeeded: Bool { error == nil && !results.isEmpty }
}

public enum DiscoveryFeedLoader {
    /// Small, bounded fan-out. Results are delivered immediately on completion;
    /// cancellation never becomes a failure/cooldown verdict for a source.
    public static func load(
        _ requests: [DiscoveryRequest],
        fetch: @escaping @Sendable (DiscoveryRequest) async throws -> [SearchResult],
        onResult: @escaping @Sendable (DiscoveryOutcome) async -> Void
    ) async {
        await withTaskGroup(of: DiscoveryOutcome?.self) { group in
            for request in requests.prefix(DiscoveryCatalog.sourceLimit) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let start = ProcessInfo.processInfo.systemUptime
                    do {
                        let fetched = try await fetch(request)
                        try Task.checkCancellation()
                        let results = DiscoveryCatalog.boundedResults(fetched, limit: DiscoveryCatalog.resultLimit)
                        return DiscoveryOutcome(sourceID: request.source.id, results: results,
                                                error: results.isEmpty ? "没有返回书籍" : nil,
                                                latency: ProcessInfo.processInfo.systemUptime - start)
                    } catch {
                        guard !Task.isCancelled, !(error is CancellationError) else { return nil }
                        return DiscoveryOutcome(sourceID: request.source.id, results: [], error: error.localizedDescription,
                                                latency: ProcessInfo.processInfo.systemUptime - start)
                    }
                }
            }
            for await outcome in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let outcome { await onResult(outcome) }
            }
        }
    }
}
