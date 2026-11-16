import Foundation
import Testing
@testable import NovelKit

@Suite("Synced progress jump proposals")
struct SyncProgressAdvanceTests {
    private func book() -> Book {
        Book(sourceID: UUID(), sourceName: "书源", detailURL: "https://example.com/book/1", name: "测试书",
             progress: ReadingProgress(chapterIndex: 4, characterOffset: 120, updatedAt: Date(timeIntervalSince1970: 100)))
    }

    @Test("Later chapter and farther offset qualify, a timestamp alone does not")
    func positionComparison() {
        let local = book()
        var remote = local
        remote.progress.updatedAt = Date(timeIntervalSince1970: 200)
        #expect(SyncProgressAdvance.detect(local: [local], merged: [remote]).isEmpty)
        remote.progress.characterOffset = 121
        #expect(SyncProgressAdvance.detect(local: [local], merged: [remote]).count == 1)
        remote.progress.chapterIndex = 5
        remote.progress.characterOffset = 0
        #expect(SyncProgressAdvance.detect(local: [local], merged: [remote]).count == 1)
        remote.progress.chapterIndex = 3
        remote.progress.characterOffset = 9999
        #expect(SyncProgressAdvance.detect(local: [local], merged: [remote]).isEmpty)
    }

    @Test("Stale remote progress, other editions and remote-only books do not prompt")
    func noFalsePrompts() {
        let local = book()
        var remote = local
        remote.progress.chapterIndex = 8
        remote.progress.updatedAt = Date(timeIntervalSince1970: 50)
        #expect(SyncProgressAdvance.detect(local: [local], merged: [remote]).isEmpty)
        remote.progress.updatedAt = Date(timeIntervalSince1970: 200)
        remote.sourceID = UUID()
        #expect(SyncProgressAdvance.detect(local: [local], merged: [remote]).isEmpty)
        #expect(SyncProgressAdvance.detect(local: [], merged: [remote]).isEmpty)
    }

    @Test("Duplicate device book IDs retain the local ID for jumping and cached chapters")
    func crossDeviceIdentity() {
        let local = book()
        var remote = local
        remote.id = UUID()
        remote.progress.chapterIndex = 8
        remote.progress.updatedAt = Date(timeIntervalSince1970: 200)
        let outcome = SyncMerge.merge(
            local: SyncPayload(deviceID: "A", books: [local], sources: []),
            remote: SyncPayload(deviceID: "B", books: [remote], sources: [])
        )
        #expect(outcome.books.count == 1)
        #expect(outcome.books.first?.id == local.id)
        let advances = SyncProgressAdvance.detect(local: [local], merged: outcome.books)
        #expect(advances.first?.id == local.id)
        #expect(advances.first?.localProgress == local.progress)
        #expect(advances.first?.remoteBook.progress == remote.progress)
    }
}

private actor ProgressTestTransport: SyncTransport {
    var data: Data
    let failWrite: Bool
    init(remote: SyncPayload, failWrite: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        data = try encoder.encode(remote)
        self.failWrite = failWrite
    }
    func read() async throws -> Data? { data }
    func write(_ data: Data) async throws {
        if failWrite { throw SyncError.decoding("模拟上传失败") }
        self.data = data
    }
}

@Suite("Sync completion and progress proposals")
struct SyncProgressCompletionTests {
    @Test("A successful download reports the advance once; a failed upload keeps local progress")
    func proposalsOnSuccessOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let local = Book(sourceID: UUID(), sourceName: "源", detailURL: "https://example.com/book", name: "书",
                         progress: ReadingProgress(chapterIndex: 2, updatedAt: Date(timeIntervalSince1970: 100)))
        var remote = local
        remote.progress.chapterIndex = 5
        remote.progress.updatedAt = Date(timeIntervalSince1970: 200)
        await store.saveBooks([local])
        let payload = SyncPayload(deviceID: "B", books: [remote], sources: [])
        let failing = SyncService(transport: try ProgressTestTransport(remote: payload, failWrite: true), store: store, deviceID: "A")
        await #expect(throws: (any Error).self) { _ = try await failing.run() }
        #expect(await store.loadBooks().first?.progress == local.progress)
        #expect(await store.loadSyncProgressAdvances().isEmpty)

        let service = SyncService(transport: try ProgressTestTransport(remote: payload), store: store, deviceID: "A")
        let result = try await service.run()
        #expect(result.progressAdvances.count == 1)
        #expect(result.progressAdvances.first?.remoteBook.progress == remote.progress)
        // Relaunching after a background sync must still retain the question.
        let reopened = LibraryStore(directory: directory)
        #expect(await reopened.loadSyncProgressAdvances().first?.localProgress == local.progress)
        #expect(await reopened.loadSyncProgressAdvances().first?.remoteBook.progress == remote.progress)
        let again = try await service.run()
        #expect(again.progressAdvances.isEmpty)
    }
}
