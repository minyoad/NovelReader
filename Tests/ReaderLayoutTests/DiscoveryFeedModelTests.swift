#if canImport(UIKit)
import Foundation
import Testing
import NovelKit
@testable import NovelReader

private actor DiscoveryFetchCounter {
    var calls = 0
    func called() { calls += 1 }
}

@Suite("Cached discovery homepage")
@MainActor
struct DiscoveryFeedModelTests {
    private func source() -> BookSource {
        BookSource(name: "测试", baseURL: "https://example.invalid", enabledExplore: true,
                   exploreURL: "推荐::/top", explore: SearchRule(bookList: ".book", name: "a@text", bookURL: "a@href"))
    }

    @Test("A fresh cached homepage is shown without making a request, and next batch uses the pool")
    func freshCache() async {
        let source = source()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let books = (0..<30).map {
            SearchResult(sourceID: source.id, sourceName: source.name, name: "书\($0)", author: "作者", detailURL: "/\($0)")
        }
        await store.saveDiscoveryFeed(DiscoveryFeedCache(updatedAt: Date(), results: books,
            fingerprints: [source.id.uuidString: DiscoveryCatalog.fingerprint(source)]))
        let counter = DiscoveryFetchCounter()
        let model = DiscoveryFeedModel(fetchPage: { _, _ in await counter.called(); return [] })
        model.open(sources: [source], network: NetworkSettings(), store: store)
        await model.waitForCurrentLoad()
        #expect(model.visibleEntries.count == 20)
        #expect(await counter.calls == 0)
        let previous = Set(model.visibleIDs)
        model.nextBatch()
        #expect(model.visibleEntries.count == 10)
        #expect(previous.isDisjoint(with: Set(model.visibleIDs)))
        #expect(await counter.calls == 0)
        model.cancel()
    }

    @Test("A failed refresh retains cached cards and puts only that source in cooldown")
    func failedRefreshKeepsCache() async {
        let source = source()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let book = SearchResult(sourceID: source.id, sourceName: source.name, name: "缓存书", detailURL: "/book")
        await store.saveDiscoveryFeed(DiscoveryFeedCache(updatedAt: Date(timeIntervalSince1970: 100), results: [book],
            fingerprints: [source.id.uuidString: DiscoveryCatalog.fingerprint(source)]))
        let model = DiscoveryFeedModel(fetchPage: { _, _ in throw HTTPError.transport("offline") })
        model.open(sources: [source], network: NetworkSettings(), store: store)
        await model.waitForCurrentLoad()
        #expect(model.visibleEntries.first?.primary.name == "缓存书")
        #expect(model.health[source.id.uuidString]?.retryAfter != nil)
        #expect(!model.isLoading)
        #expect(model.updatedAt == Date(timeIntervalSince1970: 100))
        model.cancel()
    }

    @Test("Stopping a refresh rejects late results and a manual retry remains possible")
    func cancelledRefresh() async {
        let source = source()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let model = DiscoveryFeedModel(fetchPage: { request, _ in
            try await Task.sleep(for: .seconds(30))
            return [SearchResult(sourceID: request.source.id, sourceName: request.source.name, name: "迟到的书", detailURL: "/late")]
        })
        model.open(sources: [source], network: NetworkSettings(), store: store)
        try? await Task.sleep(for: .milliseconds(20))
        model.stopLoading()
        await Task.yield()
        #expect(!model.isLoading)
        #expect(model.entries.isEmpty)
        #expect(model.health.isEmpty)
        model.cancel()
    }
}
#endif
