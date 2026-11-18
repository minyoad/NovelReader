import Testing
import Foundation

@testable import NovelKit

@Suite("并发窗口：搜索不能把几百个书源同时甩到网上")
struct ConcurrencyWindowTests {

    /// Tracks how many are running at once, and the peak.
    private actor Counter {
        private(set) var running = 0
        private(set) var peak = 0
        private(set) var finished = 0

        func begin() {
            running += 1
            peak = max(peak, running)
        }

        func end() {
            running -= 1
            finished += 1
        }
    }

    @Test("同时在跑的不超过上限")
    func respectsLimit() async {
        let counter = Counter()
        let items = Array(1...50)

        await ConcurrencyWindow.forEach(items, limit: 5) { item in
            await counter.begin()
            // 让几个同时真的重叠，否则上限根本没机会被触发。
            try? await Task.sleep(for: .milliseconds(20))
            await counter.end()
            return item
        } onEach: { _ in }

        #expect(await counter.peak == 5)
        #expect(await counter.finished == 50)
    }

    @Test("上限比条目多时，全部都能跑完，不会漏")
    func limitLargerThanInput() async {
        let counter = Counter()
        await ConcurrencyWindow.forEach([1, 2, 3], limit: 12) { item in
            await counter.begin()
            await counter.end()
            return item
        } onEach: { _ in }

        #expect(await counter.finished == 3)
        #expect(await counter.peak <= 3)
    }

    @Test("空输入什么都不做")
    func emptyInput() async {
        let counter = Counter()
        await ConcurrencyWindow.forEach([Int](), limit: 5) { item in
            await counter.begin()
            return item
        } onEach: { _ in }

        #expect(await counter.finished == 0)
    }

    @Test("每个结果都交回一次，不多不少")
    func deliversEveryResult() async {
        let collector = Collector()
        await ConcurrencyWindow.forEach(Array(1...30), limit: 4) { $0 } onEach: { value in
            await collector.add(value)
        }

        let got = await collector.values
        #expect(got.count == 30)
        #expect(Set(got) == Set(1...30))
    }

    @Test("limit 为 0 或负数时按 1 处理，而不是永远卡住")
    func degenerateLimitDoesNotHang() async {
        let counter = Counter()
        await ConcurrencyWindow.forEach([1, 2, 3], limit: 0) { item in
            await counter.begin()
            await counter.end()
            return item
        } onEach: { _ in }

        #expect(await counter.finished == 3)
        #expect(await counter.peak == 1)
    }

    @Test("搜索用的上限是个有意义的数，不是把全部书源一次放出去")
    func searchLimitIsBounded() {
        // 书架上有几百个书源；这个数必须远小于任何一个现实中的数量，
        // 否则列表卡住的问题会原样回来。
        #expect(ConcurrencyWindow.searchSources >= 1)
        #expect(ConcurrencyWindow.searchSources <= 32)
    }

    private actor Collector {
        private(set) var values: [Int] = []
        func add(_ value: Int) { values.append(value) }
    }
}
