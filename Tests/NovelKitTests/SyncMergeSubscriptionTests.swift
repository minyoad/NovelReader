import Testing
import Foundation
@testable import NovelKit

@Suite("同步：书源订阅")
struct SyncMergeSubscriptionTests {

    func payload(
        device: String,
        subscriptions: [SourceSubscription]?
    ) -> SyncPayload {
        SyncPayload(deviceID: device, books: [], sources: [], subscriptions: subscriptions)
    }

    @Test("另一台设备的订阅会合并进来")
    func remoteSubscriptionMerges() {
        let remote = SourceSubscription(url: "https://a.com/sources.json")
        let outcome = SyncMerge.merge(
            local: payload(device: "A", subscriptions: []),
            remote: payload(device: "B", subscriptions: [remote])
        )

        #expect(outcome.subscriptions == [remote])
        #expect(outcome.localChanged)
    }

    @Test("同一个订阅按最后更新时间取新")
    func newerWins() {
        let id = UUID()
        let older = SourceSubscription(
            id: id,
            name: "旧名字",
            url: "https://a.com/sources.json",
            lastUpdatedAt: Date(timeIntervalSince1970: 1000)
        )
        var newer = older
        newer.name = "新名字"
        newer.lastUpdatedAt = Date(timeIntervalSince1970: 2000)

        let outcome = SyncMerge.merge(
            local: payload(device: "A", subscriptions: [older]),
            remote: payload(device: "B", subscriptions: [newer])
        )

        #expect(outcome.subscriptions.first?.name == "新名字")
        #expect(outcome.localChanged)
    }

    @Test("本地更新时本地赢")
    func localNewerWins() {
        let id = UUID()
        var local = SourceSubscription(id: id, url: "https://a.com/s.json")
        local.lastUpdatedAt = Date(timeIntervalSince1970: 3000)
        var remote = local
        remote.lastUpdatedAt = Date(timeIntervalSince1970: 1000)

        let outcome = SyncMerge.merge(
            local: payload(device: "A", subscriptions: [local]),
            remote: payload(device: "B", subscriptions: [remote])
        )

        #expect(outcome.subscriptions.first == local)
        #expect(!outcome.localChanged)
    }

    @Test("旧版本写出的同步文件没有订阅字段，也能解出来")
    func decodesWithoutSubscriptions() throws {
        let json = """
        {"version":1,"updatedAt":"2026-01-01T00:00:00Z","deviceID":"A",
         "books":[],"sources":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(SyncPayload.self, from: Data(json.utf8))
        #expect(payload.subscriptions == nil)
        #expect(payload.books.isEmpty)
    }

    @Test("取消订阅后书源留在设备上，只是不再归属订阅")
    func unsubscribingKeepsSources() {
        let sub = UUID()
        let source = BookSource(name: "甲", baseURL: "https://a.com", subscriptionID: sub)
        // `AppModel.removeSubscription` clears the tag and keeps the record.
        let orphaned = BookSource(
            id: source.id,
            name: source.name,
            baseURL: source.baseURL,
            searchURL: source.searchURL,
            subscriptionID: nil
        )
        #expect(orphaned.id == source.id)
        #expect(orphaned.name == "甲")
        #expect(orphaned.subscriptionID == nil)
    }
}
