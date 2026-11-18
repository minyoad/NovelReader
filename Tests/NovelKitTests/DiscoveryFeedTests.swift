import Foundation
import Testing
@testable import NovelKit

@Suite("Discovery catalog and cache")
struct DiscoveryCatalogTests {
    private func source(_ name: String) -> BookSource {
        BookSource(name: name, baseURL: "https://\(name).example", enabledExplore: true,
                   exploreURL: "玄幻::/genre\n热门推荐::/top\n新书::/new",
                   explore: SearchRule(bookList: ".book", name: "a@text", bookURL: "a@href"))
    }
    private func book(_ source: BookSource, _ title: String, author: String = "作者") -> SearchResult {
        SearchResult(sourceID: source.id, sourceName: source.name, name: title, author: author, detailURL: "https://\(source.name).example/\(title)")
    }

    @Test("Known-author duplicates merge while unknown authors and different authors stay separate")
    func deduplication() {
        let a = source("a"), b = source("b")
        let first = book(a, "长 夜", author: "作 者")
        var repeated = first
        repeated.intro = "新简介"
        let entries = DiscoveryCatalog.entries([first, book(b, "长夜"), repeated, book(a, "长夜", author: "另一作者"),
                                               book(a, "无名书", author: ""), book(b, "无名书", author: "佚名")])
        #expect(entries.count == 4)
        #expect(entries[0].variants.count == 2)
        #expect(entries[0].sourceCount == 2)
        #expect(entries[0].primary.intro == "新简介")
        let shelf = Book(sourceID: b.id, sourceName: b.name, detailURL: "/other", name: "长夜", author: "作者")
        #expect(DiscoveryCatalog.shelfBook(for: entries[0], in: [shelf])?.id == shelf.id)
        var failed = DiscoverySourceHealth(), working = DiscoverySourceHealth()
        failed.record(success: false, latency: 6, now: Date())
        working.record(success: true, latency: 0.2, now: Date())
        let ranked = DiscoveryCatalog.preferredEntries([first, book(b, "长夜")],
            health: [a.id.uuidString: failed, b.id.uuidString: working])
        #expect(ranked.first?.primary.sourceID == b.id)
        #expect(ranked.first?.variants.count == 2)
    }

    @Test("Batches balance sources and skip already displayed identities")
    func batches() {
        let a = source("a"), b = source("b")
        let entries = DiscoveryCatalog.entries((0..<25).map { book(a, "A\($0)") } + (0..<25).map { book(b, "B\($0)") })
        let first = DiscoveryCatalog.batch(entries, excluding: [])
        #expect(first.count == 20)
        #expect(first.filter { $0.primary.sourceID == a.id }.count == 10)
        let second = DiscoveryCatalog.batch(entries, excluding: Set(first.map(\.id)))
        #expect(second.count == 20)
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect(DiscoveryCatalog.batch(entries, excluding: [], limit: 0).isEmpty)
        var oversized = book(a, "简介过长")
        oversized.intro = String(repeating: "字", count: 10000)
        #expect(DiscoveryCatalog.merge([oversized], into: []).first?.intro.count == 1200)
    }

    @Test("Planning caps fan-out, respects preferences, and temporarily cools failed sources")
    func planning() {
        let sources = (0..<8).map { source("s\($0)") }
        let now = Date(timeIntervalSince1970: 1000)
        var health = DiscoverySourceHealth()
        health.record(success: false, latency: 6, now: now)
        let measurements = [sources[0].id.uuidString: health]
        let plan = DiscoveryCatalog.plan(sources: sources, selected: [], health: measurements, round: 0, rotate: false, force: false, now: now)
        #expect(plan.count == 3)
        #expect(!plan.contains { $0.id == sources[0].id })
        let explicit = DiscoveryCatalog.plan(sources: sources, selected: [sources[0].id], health: measurements, round: 0, rotate: false, force: true, now: now)
        #expect(explicit.map(\.id) == [sources[0].id])
        let recovered = DiscoveryCatalog.plan(sources: sources, selected: [sources[0].id], health: measurements, round: 0, rotate: false, force: false, now: now.addingTimeInterval(301))
        #expect(recovered.count == 1)
        #expect(DiscoveryCatalog.plan(sources: sources, selected: sources.map(\.id), health: [:], round: 0, rotate: false, force: false).count == 5)
        #expect(DiscoveryCatalog.category(for: sources[0], round: 0)?.name == "热门推荐")
        #expect(DiscoveryCatalog.category(for: sources[0], round: 1)?.name != "热门推荐")
        health.record(success: true, latency: 0.1, now: now)
        #expect(health.failures == 0 && health.retryAfter == nil)
    }

    @Test("Cache excludes disabled, removed, edited and unselected sources, while unrelated metadata stays valid")
    func cacheValidation() {
        let a = source("a"), b = source("b")
        let cache = DiscoveryFeedCache(results: [book(a, "甲"), book(b, "乙")],
                                       fingerprints: [a.id.uuidString: DiscoveryCatalog.fingerprint(a), b.id.uuidString: DiscoveryCatalog.fingerprint(b)])
        var edited = a
        edited.explore.name = ".new-name"
        #expect(DiscoveryCatalog.validResults(cache, sources: [edited, b]).count == 1)
        edited = a; edited.enabled = false
        #expect(DiscoveryCatalog.validResults(cache, sources: [edited, b]).count == 1)
        #expect(DiscoveryCatalog.validResults(cache, sources: [b]).count == 1)
        edited = a; edited.lastUsedAt = Date()
        #expect(DiscoveryCatalog.validResults(cache, sources: [edited, b]).count == 2)
        var selected = cache; selected.selectedSourceIDs = [b.id]
        #expect(DiscoveryCatalog.validResults(selected, sources: [a, b]).first?.sourceID == b.id)
    }

    @Test("Cache survives a new store instance and older saves cannot replace a newer batch")
    func persistence() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let a = source("a")
        let cache = DiscoveryFeedCache(savedAt: Date(timeIntervalSince1970: 200.9), updatedAt: Date(timeIntervalSince1970: 150),
                                       results: [book(a, "缓存书")], fingerprints: [a.id.uuidString: DiscoveryCatalog.fingerprint(a)],
                                       selectedSourceIDs: [a.id], visibleIDs: ["visible"], round: 3)
        await store.saveDiscoveryFeed(cache)
        await store.saveDiscoveryFeed(DiscoveryFeedCache(savedAt: Date(timeIntervalSince1970: 200.8)))
        let restored = await LibraryStore(directory: directory).loadDiscoveryFeed()
        #expect(restored?.results.first?.name == "缓存书")
        #expect(restored?.selectedSourceIDs == [a.id])
        #expect(restored?.round == 3)
    }
}

private actor DiscoveryLoaderProbe {
    var delivered: [UUID] = []
    var deliveredBeforeSlowFinished = false
    var cancelled = false
    private var started = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private let fastGate = AsyncStream<Void>.makeStream()
    func began() {
        started += 1
        if started >= 2 { startWaiter?.resume(); startWaiter = nil }
    }
    func waitUntilStarted() async {
        if started >= 2 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func waitForFastResult() async {
        var iterator = fastGate.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func result(_ outcome: DiscoveryOutcome, slow: UUID) {
        delivered.append(outcome.sourceID)
        if outcome.sourceID != slow {
            deliveredBeforeSlowFinished = deliveredBeforeSlowFinished || !delivered.contains(slow)
            fastGate.continuation.yield(())
            fastGate.continuation.finish()
        }
    }
    func markCancelled() { cancelled = true }
}

@Suite("Discovery streaming and cancellation")
struct DiscoveryLoaderTests {
    private func requests(_ count: Int) -> [DiscoveryRequest] {
        (0..<count).map { index in
            DiscoveryRequest(source: BookSource(name: "\(index)", baseURL: "https://example.invalid"), category: ExploreCategory(name: "推荐", url: "/top"))
        }
    }

    @Test("Fast sources deliver before a slow source and fan-out never exceeds five")
    func streaming() async {
        let requests = requests(8)
        let slow = requests[0].source.id
        let probe = DiscoveryLoaderProbe()
        await DiscoveryFeedLoader.load(requests, fetch: { request in
            if request.source.id == slow { await probe.waitForFastResult() }
            return [SearchResult(sourceID: request.source.id, sourceName: request.source.name, name: "新书", detailURL: "/book")]
        }, onResult: { await probe.result($0, slow: slow) })
        #expect(await probe.delivered.count == 5)
        #expect(await probe.deliveredBeforeSlowFinished)
        #expect(await probe.delivered.last == slow)
    }

    @Test("Cancellation stops pending fetches without producing failed-source verdicts")
    func cancellation() async {
        let requests = requests(2)
        let probe = DiscoveryLoaderProbe()
        let task = Task {
            await DiscoveryFeedLoader.load(requests, fetch: { _ in
                await probe.began()
                do { try await Task.sleep(for: .seconds(30)); return [] }
                catch { await probe.markCancelled(); throw error }
            }, onResult: { await probe.result($0, slow: requests[0].source.id) })
        }
        await probe.waitUntilStarted()
        task.cancel()
        await task.value
        #expect(await probe.delivered.isEmpty)
        #expect(await probe.cancelled)
    }
}
