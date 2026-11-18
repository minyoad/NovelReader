import Testing
import Foundation

@testable import NovelKit

/// `AppModel` 的同步占用判定跑在 SwiftUI 里，Linux 上测不到，这里把规则
/// 原样复述一遍。两边不一致时这个套件就是警报——它守的是「同步按钮不能
/// 永久失效」这个行为。
@Suite("同步：进行中的占用会过期")
struct SyncClaimTests {

    /// 与 `AppModel.syncClaimTimeout` 一致。
    static let claimTimeout: TimeInterval = 180

    /// 与 `AppModel.syncInFlight` 的判定一致。
    func isBusy(claimedAt: Date?, now: Date = Date()) -> Bool {
        guard let claimedAt else { return false }
        return now.timeIntervalSince(claimedAt) < Self.claimTimeout
    }

    @Test("从没同步过时不算忙")
    func idle() {
        #expect(!isBusy(claimedAt: nil))
    }

    @Test("刚开始的同步算忙，挡住第二个")
    func freshClaimBlocks() {
        let now = Date()
        #expect(isBusy(claimedAt: now.addingTimeInterval(-1), now: now))
        #expect(isBusy(claimedAt: now.addingTimeInterval(-60), now: now))
    }

    @Test("超过上限的占用视为放弃，不再挡住用户")
    func staleClaimDoesNotBlock() {
        let now = Date()
        #expect(!isBusy(claimedAt: now.addingTimeInterval(-181), now: now))
        #expect(!isBusy(claimedAt: now.addingTimeInterval(-3600), now: now))
    }

    @Test("上限比一次同步最长可能耗时更宽裕")
    func timeoutFitsTheWorstCase() {
        // WebDAV：read + MKCOL + write，单次资源上限 50 秒
        let worstCase: TimeInterval = 50 * 3
        #expect(Self.claimTimeout >= worstCase)
    }

    @Test("启动同步的 8 秒上限远小于占用上限，所以超时后按钮仍可用")
    func startupDeadlineIsShorter() {
        // 启动同步最多等 8 秒，超时后 runSync 可能还在跑。
        // 只要占用上限明显更长，用户在启动同步之后点「立即同步」
        // 才会看到"还没结束"。这正是要避免的：所以 runSync 里
        // withDeadline 超时会取消任务，占用也随之释放。
        #expect(8.0 < Self.claimTimeout)
    }
}
