import Testing
import Foundation
@testable import NovelKit

@Suite("书源订阅：刷新合并")
struct SourceSubscriptionSyncTests {

    let sub = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let otherSub = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func source(
        _ name: String,
        _ url: String,
        id: UUID = UUID(),
        subscription: UUID? = nil,
        search: String = "https://x.com/search?q={{key}}"
    ) -> BookSource {
        BookSource(id: id, name: name, baseURL: url, searchURL: search, subscriptionID: subscription)
    }

    @Test("第一次刷新：全部新增，并打上订阅标记")
    func firstRefreshAddsEverything() {
        let delivered = [source("甲", "https://a.com"), source("乙", "https://b.com")]
        let outcome = SourceSubscriptionSync.apply(
            current: [],
            delivered: delivered,
            subscriptionID: sub
        )

        #expect(outcome.sources.count == 2)
        #expect(outcome.report.added == 2)
        #expect(outcome.report.removed == 0)
        #expect(outcome.changed)
        #expect(outcome.sources.allSatisfy { $0.subscriptionID == sub })
        #expect(outcome.report.summary == "新增 2")
    }

    @Test("规则没变时不算更新，也不触发写盘")
    func unchangedListIsNoop() {
        let existing = source("甲", "https://a.com", id: UUID(), subscription: sub)
        let delivered = [source("甲", "https://a.com")]

        let outcome = SourceSubscriptionSync.apply(
            current: [existing],
            delivered: delivered,
            subscriptionID: sub
        )

        #expect(outcome.report.added == 0)
        #expect(outcome.report.updated == 0)
        #expect(!outcome.changed)
        #expect(outcome.report.summary == "已是最新")
        #expect(outcome.sources.first?.id == existing.id)
    }

    @Test("规则变了：就地更新，id 不变（书架指向它）")
    func ruleChangeKeepsID() {
        let id = UUID()
        let existing = source("甲", "https://a.com", id: id, subscription: sub)
        var updated = source("甲", "https://a.com")
        updated.searchURL = "https://a.com/new?q={{key}}"

        let outcome = SourceSubscriptionSync.apply(
            current: [existing],
            delivered: [updated],
            subscriptionID: sub
        )

        #expect(outcome.report.updated == 1)
        #expect(outcome.sources.count == 1)
        #expect(outcome.sources[0].id == id)
        #expect(outcome.sources[0].searchURL == "https://a.com/new?q={{key}}")
    }

    @Test("用户在设备上关掉的源，更新后仍然是关的")
    func disabledStaysDisabled() {
        var existing = source("甲", "https://a.com", subscription: sub)
        existing.enabled = false
        var delivered = source("甲", "https://a.com")
        delivered.enabled = true
        delivered.searchURL = "https://a.com/v2?q={{key}}"

        let outcome = SourceSubscriptionSync.apply(
            current: [existing],
            delivered: [delivered],
            subscriptionID: sub
        )

        #expect(outcome.sources[0].enabled == false)
        #expect(outcome.report.updated == 1)
    }

    @Test("订阅里删掉的源会被删除")
    func droppedSourceIsRemoved() {
        let keep = source("甲", "https://a.com", subscription: sub)
        let drop = source("乙", "https://b.com", subscription: sub)

        let outcome = SourceSubscriptionSync.apply(
            current: [keep, drop],
            delivered: [source("甲", "https://a.com")],
            subscriptionID: sub
        )

        #expect(outcome.sources.map(\.name) == ["甲"])
        #expect(outcome.report.removed == 1)
    }

    @Test("书架还在用的源，订阅删了也保留")
    func shelfSourceIsKept() {
        let inUse = source("乙", "https://b.com", subscription: sub)
        let outcome = SourceSubscriptionSync.apply(
            current: [source("甲", "https://a.com", subscription: sub), inUse],
            delivered: [source("甲", "https://a.com")],
            subscriptionID: sub,
            shelfSourceIDs: [inUse.id]
        )

        #expect(outcome.sources.contains { $0.id == inUse.id })
        #expect(outcome.report.removed == 0)
        #expect(outcome.report.keptInUse == 1)
        #expect(outcome.report.keptSourceNames == ["乙"])
        #expect(outcome.report.summary.contains("保留 1"))
    }

    @Test("手动导入的源不受任何订阅影响")
    func manualSourcesAreUntouchable() {
        let manual = source("手抄", "https://manual.com")
        // An identical site under another subscription must not be taken over.
        let foreign = source("别人的", "https://c.com", subscription: otherSub)

        let outcome = SourceSubscriptionSync.apply(
            current: [manual, foreign],
            delivered: [],
            subscriptionID: sub
        )

        #expect(outcome.sources.map(\.name) == ["手抄", "别人的"])
        #expect(outcome.report.removed == 0)
        #expect(!outcome.changed)
    }

    @Test("同名不同站、同站不同名都算两条不同的源")
    func identityIsNameAndSite() {
        let a = source("笔趣阁", "https://one.com", subscription: sub)
        let b = source("笔趣阁", "https://two.com", subscription: sub)
        let c = source("别的名字", "https://one.com", subscription: sub)

        let outcome = SourceSubscriptionSync.apply(
            current: [a, b, c],
            delivered: [source("笔趣阁", "https://one.com")],
            subscriptionID: sub
        )

        // Only the exact pair (name + site) survives; the other two are a
        // different site and a different name, so they are not the same source.
        #expect(outcome.sources.count == 1)
        #expect(outcome.sources[0].id == a.id)
        #expect(outcome.report.removed == 2)
    }

    @Test("手抄的源被订阅也收录时，归属留在手抄上")
    func manualOwnershipWins() {
        let manual = source("甲", "https://a.com")
        let delivered = source("甲", "https://a.com")

        let outcome = SourceSubscriptionSync.apply(
            current: [manual],
            delivered: [delivered],
            subscriptionID: sub
        )

        #expect(outcome.sources.count == 1)
        #expect(outcome.sources[0].subscriptionID == nil)
        #expect(outcome.sources[0].id == manual.id)
    }

    @Test("被删源的书上了书架的提示名单")
    func deletedSourceReportsItsBooks() {
        let doomed = source("乙", "https://b.com", subscription: sub)

        let outcome = SourceSubscriptionSync.apply(
            current: [source("甲", "https://a.com", subscription: sub), doomed],
            delivered: [source("甲", "https://a.com")],
            subscriptionID: sub,
            // Deliberately not in `shelfSourceIDs`: this models a book whose
            // source was already gone before the refresh.
            shelfBookNames: [doomed.id: ["某本书"]]
        )

        #expect(outcome.report.orphanedBookNames == ["某本书"])
    }

    @Test("已有源的顺序不变，新增的追加在后面")
    func orderIsStable() {
        let a = source("甲", "https://a.com", subscription: sub)
        let b = source("乙", "https://b.com", subscription: sub)

        let outcome = SourceSubscriptionSync.apply(
            current: [a, b],
            delivered: [source("丙", "https://c.com"), source("甲", "https://a.com"), source("乙", "https://b.com")],
            subscriptionID: sub
        )

        // 甲、乙 keep their places; 丙, being new, goes last.
        #expect(outcome.sources.map(\.name) == ["甲", "乙", "丙"])
        #expect(outcome.report.added == 1)
        #expect(outcome.report.removed == 0)
    }

    @Test("订阅里消失且书架没用的源会被删掉")
    func droppedAndUnusedIsRemoved() {
        let a = source("甲", "https://a.com", subscription: sub)
        let b = source("乙", "https://b.com", subscription: sub)

        let outcome = SourceSubscriptionSync.apply(
            current: [a, b],
            delivered: [source("丙", "https://c.com"), source("甲", "https://a.com")],
            subscriptionID: sub
        )

        #expect(outcome.sources.map(\.name) == ["甲", "丙"])
        #expect(outcome.report.removed == 1)
        #expect(outcome.report.added == 1)
    }

    @Test("用户在设备上关掉、且修改过的源，更新时仍保留这些改动")
    func userEditsSurviveSubscriptionUpdate() {
        var edited = source("甲", "https://a.com", subscription: sub)
        edited.comment = "我调过的备注"
        edited.enabled = false

        // A rules update from upstream. The remark above is the user's, so the
        // incoming record does not carry it.
        var delivered = source("甲", "https://a.com")
        delivered.searchURL = "https://a.com/v2?q={{key}}"

        let outcome = SourceSubscriptionSync.apply(
            current: [edited],
            delivered: [delivered],
            subscriptionID: sub
        )

        // Enabled and ownership survive; the rules are the subscription's.
        // The comment is documentation the user wrote on the old record and
        // does not travel with the rules — a known limitation, recorded here
        // so a future change makes it a deliberate decision either way.
        #expect(outcome.sources[0].enabled == false)
        #expect(outcome.sources[0].subscriptionID == sub)
        #expect(outcome.sources[0].searchURL == "https://a.com/v2?q={{key}}")
    }
}
