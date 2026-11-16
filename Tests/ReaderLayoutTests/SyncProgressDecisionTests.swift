#if canImport(UIKit)
import Foundation
import Testing
import NovelKit
@testable import NovelReader

@Suite("Synced reading position decisions")
@MainActor
struct SyncProgressDecisionTests {
    private func preparedApp() async -> (AppModel, Book, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(directory: directory)
        let old = ReadingProgress(chapterIndex: 2, characterOffset: 100, updatedAt: Date(timeIntervalSince1970: 100))
        let remote = Book(sourceID: UUID(), sourceName: "测试", detailURL: "https://example.invalid/book", name: "测试书",
                          progress: ReadingProgress(chapterIndex: 4, characterOffset: 200, updatedAt: Date(timeIntervalSince1970: 200)))
        await store.saveBooks([remote])
        await store.saveSyncProgressAdvances([SyncProgressAdvance(id: remote.id, localProgress: old, remoteBook: remote)])
        let app = AppModel(store: store)
        await app.bootstrap()
        return (app, remote, directory)
    }

    @Test("Auto-resume stays local until a choice, and declining keeps the current local position")
    func keepLocal() async {
        let (app, remote, directory) = await preparedApp()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(app.bookForReading(remote).progress.chapterIndex == 2)
        app.updateProgress(bookID: remote.id, chapterIndex: 3, chapterTitle: "第四章", characterOffset: 50)
        #expect(app.pendingProgressAdvances[remote.id]?.localProgress.chapterIndex == 3)
        #expect(app.books.first { $0.id == remote.id }?.progress == remote.progress)
        let stayed = app.resolveSyncedProgress(bookID: remote.id, useRemote: false)
        #expect(stayed?.progress.chapterIndex == 3)
        #expect(stayed?.progress.characterOffset == 50)
        #expect(app.pendingProgressAdvances[remote.id] == nil)
    }

    @Test("Accepting uses the remote offset and resolves the question once")
    func acceptRemote() async {
        let (app, remote, directory) = await preparedApp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = app.resolveSyncedProgress(bookID: remote.id, useRemote: true)
        #expect(target?.progress.chapterIndex == 4)
        #expect(target?.progress.characterOffset == 200)
        #expect(app.pendingProgressAdvances[remote.id] == nil)
        #expect(app.resolveSyncedProgress(bookID: remote.id, useRemote: true) == nil)
    }
}
#endif
