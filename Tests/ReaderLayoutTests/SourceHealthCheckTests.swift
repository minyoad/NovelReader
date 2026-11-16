#if canImport(UIKit)
import Testing
import NovelKit
@testable import NovelReader

@Suite("Source discovery check lifecycle")
@MainActor
struct SourceHealthCheckTests {
    @Test("Missing discovery configuration is not a failed source")
    func noDiscoveryPage() {
        let source = BookSource(name: "仅提供搜索", baseURL: "https://example.invalid")
        let check = SourceHealthCheck()
        check.start(sources: [source], client: HTTPClient())
        #expect(!check.isRunning)
        #expect(check.entries.first?.status == .skipped)
        #expect(check.failedIDs.isEmpty)
        check.cancel()
        #expect(check.entries.first?.status == .skipped)
    }

    @Test("Cancelling before the task starts cannot re-mark stopped rows as checking")
    func cancellationBeforeStart() async {
        let source = BookSource(
            name: "待检测", baseURL: "https://example.invalid",
            exploreURL: "排行::/list",
            explore: SearchRule(bookList: ".book", name: ".name", bookURL: "a@href")
        )
        #expect(!source.openableExploreCategories.isEmpty)
        let check = SourceHealthCheck()
        check.start(sources: [source], client: HTTPClient())
        check.cancel()
        await Task.yield()
        #expect(!check.isRunning)
        #expect(check.entries.first?.status == .cancelled)
        #expect(check.failedIDs.isEmpty)

        // Restarting while the cancelled task is queued must preserve the new
        // run's rows rather than accepting updates from the old task.
        let replacement = BookSource(name: "新列表", baseURL: "https://example.invalid")
        check.start(sources: [replacement], client: HTTPClient())
        await Task.yield()
        #expect(check.entries.map(\.id) == [replacement.id])
        #expect(check.entries.first?.status == .skipped)
    }
}
#endif
