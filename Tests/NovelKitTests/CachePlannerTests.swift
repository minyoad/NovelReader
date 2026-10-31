import Testing
import Foundation
@testable import NovelKit

@Suite("Offline cache planning")
struct CachePlannerTests {

    @Test("prefetch walks forward and skips cached chapters")
    func prefetchForward() {
        let plan = CachePlanner.prefetchIndices(
            currentIndex: 10,
            chapterCount: 20,
            prefetchCount: 3,
            alreadyCached: [11]
        )
        #expect(plan == [12, 13, 14])
    }

    @Test("prefetch stops at the end of the book")
    func prefetchAtEnd() {
        let plan = CachePlanner.prefetchIndices(
            currentIndex: 18,
            chapterCount: 20,
            prefetchCount: 5,
            alreadyCached: []
        )
        #expect(plan == [19])
    }

    @Test("prefetch is empty when disabled")
    func prefetchDisabled() {
        #expect(CachePlanner.prefetchIndices(
            currentIndex: 3, chapterCount: 10, prefetchCount: 0, alreadyCached: []
        ).isEmpty)
        #expect(CachePlanner.prefetchIndices(
            currentIndex: 3, chapterCount: 0, prefetchCount: 5, alreadyCached: []
        ).isEmpty)
    }

    @Test("whole book download skips the chapter being read")
    func missingForWholeBook() {
        let missing = CachePlanner.missingForWholeBook(
            chapterCount: 5,
            alreadyCached: [0, 2],
            excluding: 1
        )
        #expect(missing == [3, 4], "已缓存的 0/2 和正在读的 1 都不该再下载")
    }

    @Test("eviction drops the chapters furthest from the reading position")
    func eviction() {
        // Cached 0...9, reading at 8, limit 4 → keep the four closest to 8.
        let drop = CachePlanner.evictionCandidates(
            cachedChapterIndices: Array(0...9),
            currentIndex: 8,
            limit: 4
        )
        #expect(drop == [0, 1, 2, 3, 4, 5])

        let kept = Set(Array(0...9)).subtracting(drop)
        #expect(kept == [6, 7, 8, 9], "阅读位置附近必须保留")
    }

    @Test("eviction does nothing under the limit")
    func evictionNoop() {
        #expect(CachePlanner.evictionCandidates(
            cachedChapterIndices: [0, 1], currentIndex: 0, limit: 5
        ).isEmpty)
        #expect(CachePlanner.evictionCandidates(
            cachedChapterIndices: [0, 1], currentIndex: 0, limit: 0
        ).isEmpty, "0 表示不限制")
    }
}

@Suite("Chapter cache storage")
struct ChapterCacheStoreTests {

    private func makeStore() -> (LibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelCacheTests-\(UUID().uuidString)", isDirectory: true)
        return (LibraryStore(directory: dir), dir)
    }

    @Test("cachedChapterURLs reports only chapters with a body on disk")
    func cachedURLs() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let book = BuiltinContent.sampleBook
        let chapters = BuiltinContent.sampleChapters
        await store.saveChapters(chapters, bookID: book.id)
        await store.saveContent(
            ChapterContent(chapterURL: chapters[1].url, text: "正文"),
            bookID: book.id
        )

        let cached = await store.cachedChapterURLs(bookID: book.id)
        #expect(cached == [chapters[1].url])
    }

    @Test("size counts bodies and ignores the table of contents")
    func cachedSize() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let book = BuiltinContent.sampleBook
        let chapters = BuiltinContent.sampleChapters
        await store.saveChapters(chapters, bookID: book.id)

        let empty = await store.cachedSize(bookID: book.id)
        #expect(empty == 0)

        await store.saveContent(
            ChapterContent(chapterURL: chapters[0].url, text: String(repeating: "字", count: 500)),
            bookID: book.id
        )
        let size = await store.cachedSize(bookID: book.id)
        #expect(size > 500, "缓存大小应包含正文文件")

        let total = await store.totalCachedSize()
        #expect(total == size, "只有一本书时两者应一致")
    }
}
