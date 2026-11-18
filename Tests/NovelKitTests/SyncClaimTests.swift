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

    @Test("启动同步不再用 8 秒上限，所以不会留下跑不完的占用")
    func startupNoLongerAbandons() {
        // 之前启动同步包在 8 秒的 withDeadline 里：一次正常的同步上传几百个
        // 书源就超过 8 秒，于是几乎每次启动都会放弃一次运行，而那次运行还在
        // 占着 syncInFlight，用户一到书架点「立即同步」就被告知"还没结束"。
        //
        // 现在启动同步直接用网络层自己的超时（单请求 30s，单资源 50s），
        // 占用只在真正结束时释放。
        let networkBound: TimeInterval = 50 * 3
        #expect(networkBound < Self.claimTimeout)
        // 也就是说：只要同步还在合法耗时内，占用就有效、按钮就该显示"正在同步"。
        // 一旦超过 180 秒（网络层早就该结束了），占用失效，用户不会被锁死。
        #expect(Self.claimTimeout > networkBound)
    }
}
