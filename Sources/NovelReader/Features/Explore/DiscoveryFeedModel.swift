#if canImport(SwiftUI)
import SwiftUI
import NovelKit

@MainActor
final class DiscoveryFeedModel: ObservableObject {
    @Published private(set) var entries: [DiscoveryEntry] = []
    @Published private(set) var visibleIDs: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var message: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var selectedSourceIDs: [UUID] = []
    @Published private(set) var health: [String: DiscoverySourceHealth] = [:]
    @Published private(set) var hasLoadedCache = false

    private var results: [SearchResult] = []
    private var fingerprints: [String: String] = [:]
    private var sources: [BookSource] = []
    private var network = NetworkSettings()
    private var store: LibraryStore?
    private var round = 0
    private var seen = Set<String>()
    private var task: Task<Void, Never>?
    private var ticket = UUID()
    private var isActive = false
    private var replacingBatch = false
    private var successes = 0
    private let fetchPage: @Sendable (DiscoveryRequest, HTTPClient) async throws -> [SearchResult]

    init(fetchPage: @escaping @Sendable (DiscoveryRequest, HTTPClient) async throws -> [SearchResult] = { request, client in
        try await SourceEngine(client: client).explore(category: request.category, page: 1, source: request.source,
                                                     resultLimit: DiscoveryCatalog.resultLimit)
    }) {
        self.fetchPage = fetchPage
    }

    func waitForCurrentLoad() async { await task?.value }

    var visibleEntries: [DiscoveryEntry] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return visibleIDs.compactMap { byID[$0] }
    }

    var canChangeBatch: Bool {
        !isLoading || entries.contains { !seen.contains($0.id) }
    }

    func open(sources: [BookSource], network: NetworkSettings, store: LibraryStore) {
        cancel()
        isActive = true
        message = nil
        let restoreCache = !hasLoadedCache || (self.sources.isEmpty && !sources.isEmpty)
        self.sources = sources
        self.network = network
        self.store = store
        let run = ticket
        task = Task { [weak self] in
            guard let self, self.ticket == run, !Task.isCancelled else { return }
            if restoreCache {
                let cache = await store.loadDiscoveryFeed()
                guard self.ticket == run, !Task.isCancelled else { return }
                if let cache, cache.version == 1 {
                    self.results = cache.results
                    self.fingerprints = cache.fingerprints
                    self.health = cache.health
                    self.selectedSourceIDs = Array(cache.selectedSourceIDs.prefix(DiscoveryCatalog.sourceLimit))
                    self.updatedAt = cache.updatedAt
                    self.visibleIDs = cache.visibleIDs
                    self.round = max(0, cache.round) % 1_000_000
                }
                self.hasLoadedCache = true
            }
            self.prune()
            self.fillVisibleSlots()
            // The cached homepage remains immediately usable, even while stale
            // data refreshes; visiting a fresh homepage does not hit the network.
            let stale = self.updatedAt.map { Date().timeIntervalSince($0) >= 600 } ?? true
            if self.entries.isEmpty || stale { await self.load(run: run, rotate: false, force: false) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        ticket = UUID()
        isActive = false
        isLoading = false
    }

    func stopLoading() {
        task?.cancel()
        task = nil
        ticket = UUID()
        isLoading = false
        replacingBatch = false
        message = "已停止更新，可继续浏览缓存书籍或手动刷新。"
        fillVisibleSlots()
        persist()
    }

    func refresh(force: Bool = true) {
        launch(rotate: false, force: force)
    }

    func refreshAndWait() async {
        refresh()
        await task?.value
    }

    func configure(_ selected: [UUID]) {
        selectedSourceIDs = Array(selected.prefix(DiscoveryCatalog.sourceLimit))
        visibleIDs = []
        seen = []
        prune()
        fillVisibleSlots()
        persist()
        launch(rotate: false, force: true)
    }

    func nextBatch() {
        let next = DiscoveryCatalog.batch(entries, excluding: seen)
        if !next.isEmpty {
            replacingBatch = false
            show(next)
            message = nil
            persist()
        } else if !isLoading {
            launch(rotate: true, force: false)
        }
    }

    private func launch(rotate: Bool, force: Bool) {
        guard isActive, hasLoadedCache else { return }
        task?.cancel()
        isLoading = false
        ticket = UUID()
        let run = ticket
        task = Task { [weak self] in
            guard let self, self.ticket == run, !Task.isCancelled else { return }
            await self.load(run: run, rotate: rotate, force: force)
        }
    }

    private func load(run: UUID, rotate: Bool, force: Bool) async {
        guard isActive, ticket == run, !Task.isCancelled else { return }
        let planned = DiscoveryCatalog.plan(sources: sources, selected: selectedSourceIDs, health: health,
                                            round: round, rotate: rotate, force: force)
        let requests = planned.compactMap { source in
            DiscoveryCatalog.category(for: source, round: round).map { DiscoveryRequest(source: source, category: $0) }
        }
        guard !requests.isEmpty else {
            message = sources.contains { $0.enabled && $0.type == .text && $0.canExplore }
                ? "来源暂时未响应或正在冷却，可点击刷新重试，或调整发现来源。"
                : "还没有可用于发现的书源，请先在「书源」导入并启用带发现页的来源。"
            return
        }
        isLoading = true
        replacingBatch = rotate
        completed = 0
        successes = 0
        total = requests.count
        message = nil
        round = (round + 1) % 1_000_000
        var quick = network
        quick.timeout = min(max(quick.timeout, 1), 6)
        let client = HTTPClient(settings: quick, maximumRetries: 0, resourceTimeout: 6, maximumResponseBytes: 2 * 1024 * 1024)
        let fetch = fetchPage
        await DiscoveryFeedLoader.load(requests, fetch: { request in
            try await fetch(request, client)
        }, onResult: { [weak self] outcome in
            await self?.apply(outcome, run: run)
        })
        guard ticket == run, isActive, !Task.isCancelled else { return }
        isLoading = false
        if replacingBatch {
            let next = DiscoveryCatalog.batch(entries, excluding: Set(visibleIDs))
            if !next.isEmpty { seen = Set(visibleIDs); show(next) }
            message = "暂未发现更多新书，已保留可浏览的内容；可换其他来源再试。"
            replacingBatch = false
        } else if completed > 0 && successes == 0 {
            message = entries.isEmpty ? "这批来源暂时没有返回书籍，可刷新重试或调整发现来源。" : "这次更新未取得新内容，仍可浏览缓存书籍。"
        }
        fillVisibleSlots()
        persist()
    }

    private func apply(_ outcome: DiscoveryOutcome, run: UUID) {
        guard ticket == run, isActive, !Task.isCancelled else { return }
        completed += 1
        var measured = health[outcome.sourceID.uuidString] ?? DiscoverySourceHealth()
        measured.record(success: outcome.succeeded, latency: outcome.latency, now: Date())
        health[outcome.sourceID.uuidString] = measured
        if outcome.succeeded {
            successes += 1
            results = DiscoveryCatalog.merge(outcome.results, into: results)
            if let source = sources.first(where: { $0.id == outcome.sourceID }) {
                fingerprints[source.id.uuidString] = DiscoveryCatalog.fingerprint(source)
            }
            updatedAt = Date()
        }
        entries = DiscoveryCatalog.preferredEntries(results, health: health)
        if outcome.succeeded {
            if replacingBatch {
                let next = DiscoveryCatalog.batch(entries, excluding: seen)
                if !next.isEmpty { show(next); replacingBatch = false }
            }
            fillVisibleSlots()
        }
        persist()
    }

    private func prune() {
        let eligible = sources.filter { $0.enabled && $0.type == .text && $0.canExplore }
        let ids = Set(eligible.map(\.id))
        let previouslySelected = !selectedSourceIDs.isEmpty
        selectedSourceIDs = selectedSourceIDs.filter { ids.contains($0) }
        // Explicit preferences disappearing falls back to automatic selection.
        if previouslySelected && selectedSourceIDs.isEmpty { message = "原发现来源已停用或移除，已改为自动选择。" }
        let snapshot = DiscoveryFeedCache(results: results, fingerprints: fingerprints, selectedSourceIDs: selectedSourceIDs)
        results = DiscoveryCatalog.validResults(snapshot, sources: eligible)
        for source in eligible where fingerprints[source.id.uuidString] != DiscoveryCatalog.fingerprint(source) {
            health[source.id.uuidString] = nil
        }
        fingerprints = Dictionary(eligible.map { ($0.id.uuidString, DiscoveryCatalog.fingerprint($0)) }, uniquingKeysWith: { first, _ in first })
        health = health.filter { key, _ in fingerprints[key] != nil }
        entries = DiscoveryCatalog.preferredEntries(results, health: health)
        let valid = Set(entries.map(\.id))
        visibleIDs = visibleIDs.filter { valid.contains($0) }
        seen.formIntersection(valid)
        seen.formUnion(visibleIDs)
    }

    private func fillVisibleSlots() {
        let valid = Set(entries.map(\.id))
        seen.formIntersection(valid)
        visibleIDs = visibleIDs.filter { valid.contains($0) }
        let candidates = DiscoveryCatalog.batch(entries, excluding: seen.union(visibleIDs), limit: entries.count)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [UUID: Int] = [:]
        for id in visibleIDs {
            if let entry = byID[id] { counts[entry.primary.sourceID, default: 0] += 1 }
        }
        // Reserve room for other in-flight sources without delaying the first
        // books. Once requests finish, remaining slots can use any cached books.
        let cap = isLoading && total > 1 ? (DiscoveryCatalog.batchSize + total - 1) / total : DiscoveryCatalog.batchSize
        for entry in candidates where visibleIDs.count < DiscoveryCatalog.batchSize {
            let source = entry.primary.sourceID
            guard counts[source, default: 0] < cap else { continue }
            visibleIDs.append(entry.id)
            counts[source, default: 0] += 1
        }
        seen.formUnion(visibleIDs)
    }

    private func show(_ batch: [DiscoveryEntry]) {
        visibleIDs = batch.map(\.id)
        seen.formUnion(visibleIDs)
    }

    private func persist() {
        guard let store, hasLoadedCache else { return }
        let cache = DiscoveryFeedCache(updatedAt: updatedAt, results: results, fingerprints: fingerprints, health: health,
                                       selectedSourceIDs: selectedSourceIDs, visibleIDs: visibleIDs, round: round)
        Task { await store.saveDiscoveryFeed(cache) }
    }
}
#endif
