import Testing
import Foundation
@testable import NovelKit

private func makeBook(
    id: UUID = UUID(),
    name: String = "书",
    chapter: Int = 0,
    offset: Int = 0,
    updatedAt: Date? = nil,
    lastReadAt: Date? = nil
) -> Book {
    Book(
        id: id,
        sourceID: UUID(),
        sourceName: "源",
        detailURL: "https://example.com/\(id)",
        name: name,
        progress: ReadingProgress(
            chapterIndex: chapter,
            characterOffset: offset,
            chapterTitle: "第\(chapter + 1)章",
            updatedAt: updatedAt
        ),
        lastReadAt: lastReadAt
    )
}

private func makeSource(id: UUID = UUID(), name: String = "源") -> BookSource {
    BookSource(id: id, name: name, baseURL: "https://example.com")
}

private func payload(_ books: [Book], _ sources: [BookSource] = [], device: String = "A") -> SyncPayload {
    SyncPayload(deviceID: device, books: books, sources: sources)
}

@Suite("Sync merge")
struct SyncMergeTests {

    @Test("books only on one side are all kept")
    func union() {
        let shared = UUID()
        let localBook = makeBook(id: shared)
        let localOnly = makeBook()
        let remoteOnly = makeBook()
        let outcome = SyncMerge.merge(
            local: payload([localBook, localOnly]),
            remote: payload([makeBook(id: shared), remoteOnly])
        )
        // Dropping either side's additions is how a sync silently deletes a
        // shelf, so the union is the whole point.
        #expect(outcome.books.count == 3)
        #expect(outcome.books.contains { $0.id == localOnly.id })
        #expect(outcome.books.contains { $0.id == remoteOnly.id })
    }

    @Test("the newer reading position wins")
    func newerProgressWins() {
        let id = UUID()
        let older = makeBook(id: id, chapter: 3, updatedAt: Date(timeIntervalSince1970: 100))
        let newer = makeBook(id: id, chapter: 9, updatedAt: Date(timeIntervalSince1970: 200))

        let forward = SyncMerge.merge(local: payload([older]), remote: payload([newer]))
        #expect(forward.books.first?.progress.chapterIndex == 9)

        // And the same rule backwards, so the result does not depend on which
        // device happens to sync first.
        let backward = SyncMerge.merge(local: payload([newer]), remote: payload([older]))
        #expect(backward.books.first?.progress.chapterIndex == 9)
    }

    @Test("a never-read book never beats a read one")
    func unreadLoses() {
        let id = UUID()
        let unread = makeBook(id: id, chapter: 0, updatedAt: nil)
        let read = makeBook(id: id, chapter: 12, updatedAt: Date(timeIntervalSince1970: 1))

        let outcome = SyncMerge.merge(local: payload([unread]), remote: payload([read]))
        // A device that has never opened the book must not reset the other one
        // to chapter one, even though its copy is "newer" by file time.
        #expect(outcome.books.first?.progress.chapterIndex == 12)

        let reversed = SyncMerge.merge(local: payload([read]), remote: payload([unread]))
        #expect(reversed.books.first?.progress.chapterIndex == 12)
    }

    @Test("identical books change nothing")
    func identicalIsStable() {
        let book = makeBook(chapter: 2, updatedAt: Date(timeIntervalSince1970: 50))
        let outcome = SyncMerge.merge(local: payload([book]), remote: payload([book]))
        #expect(!outcome.localChanged)
        #expect(outcome.books == [book])
    }

    @Test("an untouched tie keeps the local copy")
    func tiedKeepsLocal() {
        // Fully tied but not identical (different titles, same progress): keep
        // local so repeated syncs do not flip-flop between the two copies.
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 10)
        let local = makeBook(id: id, name: "本地名", updatedAt: stamp)
        var remote = makeBook(id: id, name: "远端名", updatedAt: stamp)
        remote.addedAt = local.addedAt
        let outcome = SyncMerge.merge(local: payload([local]), remote: payload([remote]))
        #expect(outcome.books.first?.name == "本地名")
    }

    @Test("addedAt is never pushed back by the other device")
    func addedAtStaysLocal() {
        // addedAt orders the shelf; copying the other device's value would
        // reshuffle the shelf on every sync.
        let id = UUID()
        var local = makeBook(id: id, chapter: 1, updatedAt: Date(timeIntervalSince1970: 100))
        local.addedAt = Date(timeIntervalSince1970: 900)
        var remote = makeBook(id: id, chapter: 5, updatedAt: Date(timeIntervalSince1970: 200))
        remote.addedAt = Date(timeIntervalSince1970: 100)
        let outcome = SyncMerge.merge(local: payload([local]), remote: payload([remote]))
        #expect(outcome.books.first?.progress.chapterIndex == 5)
        #expect(outcome.books.first?.addedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("sources are unioned, no field-level blending")
    func sourcesUnion() {
        let sharedID = UUID()
        // Distinct sites: two sources with the same name and URL are the same
        // source and get folded, which is not what this test is about.
        let localOnly = makeSource(name: "甲")
        let remoteOnly = makeSource(name: "乙")
        let localShared = makeSource(id: sharedID, name: "旧规则")
        let remoteShared = makeSource(id: sharedID, name: "新规则")
        let outcome = SyncMerge.merge(
            local: payload([], [localOnly, localShared]),
            remote: payload([], [remoteOnly, remoteShared])
        )
        #expect(outcome.sources.count == 3)
        // A source is a coherent rule set; the newer copy replaces it whole.
        let shared = outcome.sources.first { $0.id == sharedID }
        #expect(shared?.name == "新规则")
    }

    @Test("an empty remote is just the local payload")
    func emptyRemote() {
        let book = makeBook()
        let outcome = SyncMerge.merge(local: payload([book]), remote: payload([]))
        #expect(outcome.books == [book])
        #expect(!outcome.localChanged)
    }
}

/// A transport that keeps the file in memory.
private final class MemoryTransport: SyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private(set) var writes = 0

    init(data: Data? = nil) { self.data = data }

    func read() async throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    func write(_ data: Data) async throws {
        lock.lock(); defer { lock.unlock() }
        self.data = data
        writes += 1
    }
}

@Suite("Sync service")
struct SyncServiceTests {

    private func tempStore() -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-test-\(UUID().uuidString)")
        return LibraryStore(directory: url)
    }

    @Test("the first sync uploads local state")
    func firstSync() async throws {
        let store = tempStore()
        let book = makeBook()
        await store.saveBooks([book])
        await store.saveSources([makeSource()])
        let transport = MemoryTransport()
        let service = SyncService(transport: transport, store: store, deviceID: "A")

        let result = try await service.run()
        #expect(result.uploaded)
        #expect(result.downloaded == false)
        #expect(result.booksAfter == 1)
        #expect(await transport.writes == 1)
    }

    @Test("a second device merges rather than overwrites")
    func secondDeviceMerges() async throws {
        // Device A uploads one book.
        let storeA = tempStore()
        await storeA.saveBooks([makeBook(name: "A 的书")])
        let transport = MemoryTransport()
        let serviceA = SyncService(transport: transport, store: storeA, deviceID: "A")
        _ = try await serviceA.run()

        // Device B has a different book; nothing may be lost on either side.
        let storeB = tempStore()
        await storeB.saveBooks([makeBook(name: "B 的书")])
        let serviceB = SyncService(transport: transport, store: storeB, deviceID: "B")
        let resultB = try await serviceB.run()

        #expect(resultB.booksAfter == 2)
        #expect(await storeB.loadBooks().count == 2)
        // B merged A's book, so it must push the union back; otherwise A never
        // learns about B's book and the next push would drop it.
        #expect(resultB.downloaded)
        #expect(resultB.uploaded)

        // A now sees both.
        let resultA = try await serviceA.run()
        #expect(resultA.booksAfter == 2)
    }

    @Test("progress advances propagate in the other direction")
    func progressPropagates() async throws {
        let shared = UUID()
        let storeA = tempStore()
        await storeA.saveBooks([makeBook(id: shared, chapter: 1, updatedAt: Date(timeIntervalSince1970: 100))])
        let transport = MemoryTransport()
        let serviceA = SyncService(transport: transport, store: storeA, deviceID: "A")
        _ = try await serviceA.run()

        let storeB = tempStore()
        await storeB.saveBooks([makeBook(id: shared, chapter: 7, updatedAt: Date(timeIntervalSince1970: 300))])
        let serviceB = SyncService(transport: transport, store: storeB, deviceID: "B")
        _ = try await serviceB.run()

        let resultA = try await serviceA.run()
        #expect(resultA.booksAfter == 1)
        #expect(await storeA.loadBooks().first?.progress.chapterIndex == 7)
    }

    @Test("reading further locally is uploaded without a remote change")
    func localProgressUploads() async throws {
        let shared = UUID()
        let store = tempStore()
        await store.saveBooks([makeBook(id: shared, chapter: 1, updatedAt: Date(timeIntervalSince1970: 100))])
        let transport = MemoryTransport()
        let service = SyncService(transport: transport, store: store, deviceID: "A")
        _ = try await service.run()
        let firstWrite = await transport.writes

        // The user reads on. Nothing changed remotely, but the local file is
        // now stale and has to be pushed.
        await store.saveBooks([makeBook(id: shared, chapter: 4, updatedAt: Date(timeIntervalSince1970: 400))])
        let result = try await service.run()
        #expect(result.uploaded)
        #expect(result.downloaded == false)
        #expect(await transport.writes == firstWrite + 1)
    }

    @Test("an unchanged sync does not rewrite the file")
    func noopSyncDoesNotUpload() async throws {
        let store = tempStore()
        await store.saveBooks([makeBook(chapter: 1, updatedAt: Date(timeIntervalSince1970: 10))])
        let transport = MemoryTransport()
        let service = SyncService(transport: transport, store: store, deviceID: "A")
        _ = try await service.run()
        let writesAfterFirst = await transport.writes

        let result = try await service.run()
        #expect(!result.uploaded)
        // Uploading on every launch would be a write per app start against
        // metered storage.
        #expect(await transport.writes == writesAfterFirst)
    }

    @Test("a corrupt remote file is refused, not overwritten")
    func corruptRemote() async throws {
        let store = tempStore()
        await store.saveBooks([makeBook()])
        let transport = MemoryTransport(data: Data("not json".utf8))
        let service = SyncService(transport: transport, store: store, deviceID: "A")

        await #expect(throws: (any Error).self) {
            _ = try await service.run()
        }
        // Overwriting would destroy whatever the file actually was.
        #expect(await transport.writes == 0)
    }

    @Test("a newer file format is refused with a clear message")
    func unsupportedVersion() async throws {
        let payload = SyncPayload(version: 99, deviceID: "X", books: [], sources: [])
        // Same date strategy as the service, otherwise the file is rejected as
        // unparseable before the version check ever runs.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let store = tempStore()
        let transport = MemoryTransport(data: data)
        let service = SyncService(transport: transport, store: store, deviceID: "A")

        do {
            _ = try await service.run()
            Issue.record("应当拒绝更新版本的文件")
        } catch let error as SyncError {
            guard case .unsupportedVersion(99) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(error.localizedDescription.contains("升级"))
        }
        #expect(await transport.writes == 0)
    }
}

@Suite("Sync settings")
struct SyncSettingsTests {

    @Test("sync secrets never reach settings.json")
    func syncSecretsStripped() throws {
        // `settings.json` is a plain file inside the app container, and the
        // container is what gets backed up and inspected. Passwords and S3
        // secret keys belong in the Keychain only.
        var settings = AppSettings()
        settings.sync.webdav.password = "dav-secret"
        settings.sync.s3.secretKey = "s3-secret"
        settings.sync.s3.sessionToken = "token-secret"

        let stripped = settings.strippingSecrets
        #expect(stripped.sync.webdav.password.isEmpty)
        #expect(stripped.sync.s3.secretKey.isEmpty)
        #expect(stripped.sync.s3.sessionToken.isEmpty)

        let json = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        #expect(!json.contains("dav-secret"))
        #expect(!json.contains("s3-secret"))
        #expect(!json.contains("token-secret"))
    }

    @Test("an old settings file without sync gets a usable default")
    func syncDefaults() throws {
        // Existing installs must not suddenly start syncing: off by default,
        // and a device id is generated so the first sync has one.
        let json = """
        { "searchAllSources": true, "aiAutoClean": false }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.sync.enabled == false)
        #expect(!settings.sync.isUsable)
        #expect(!settings.sync.deviceID.isEmpty)
    }

    @Test("sync settings survive a round-trip")
    func syncRoundTrip() throws {
        var settings = AppSettings()
        settings.sync.enabled = true
        settings.sync.backend = .s3
        settings.sync.webdav.directoryURL = "https://dav.example.com/夜读"
        settings.sync.s3.bucket = "novels"
        settings.sync.deviceID = "device-1"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.sync.enabled)
        #expect(decoded.sync.backend == .s3)
        #expect(decoded.sync.webdav.directoryURL == "https://dav.example.com/夜读")
        #expect(decoded.sync.s3.bucket == "novels")
        #expect(decoded.sync.deviceID == "device-1")
    }

    @Test("an incomplete backend is not usable")
    func incompleteBackend() {
        var sync = SyncSettings(enabled: true, backend: .webdav)
        #expect(!sync.isUsable)
        sync.webdav.directoryURL = "https://dav.example.com/x"
        #expect(sync.isUsable)

        var s3 = SyncSettings(enabled: true, backend: .s3)
        s3.s3.endpoint = "https://s3.example.com"
        s3.s3.bucket = "b"
        s3.s3.accessKeyID = "ak"
        // Missing secret key: signing would fail with a confusing 403.
        #expect(!s3.isUsable)
        s3.s3.secretKey = "sk"
        #expect(s3.isUsable)
    }

    @Test("a blank S3 region falls back instead of being signed empty")
    func blankRegion() {
        // AWS rejects an empty region in the credential scope with a 400 that
        // reads like a permissions problem.
        var config = S3Configuration()
        config.region = "   "
        #expect(config.effectiveRegion == "us-east-1")
        config.region = "auto"
        #expect(config.effectiveRegion == "auto")
    }
}
