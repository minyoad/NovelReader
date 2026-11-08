import Foundation

/// Runs one sync: read remote, merge, save local, write remote back.
///
/// All of it is in NovelKit so it can be tested on Linux with a fake
/// transport; the app layer only supplies settings and triggers.
public actor SyncService {
    private let transport: SyncTransport
    private let store: LibraryStore
    private let deviceID: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(transport: SyncTransport, store: LibraryStore, deviceID: String) {
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// What one run did, for the settings screen.
    public struct Result: Sendable, Equatable {
        public var uploaded: Bool
        public var downloaded: Bool
        public var booksAfter: Int
        public var sourcesAfter: Int
        public var remoteUpdatedAt: Date?

        public init(
            uploaded: Bool,
            downloaded: Bool,
            booksAfter: Int,
            sourcesAfter: Int,
            remoteUpdatedAt: Date?
        ) {
            self.uploaded = uploaded
            self.downloaded = downloaded
            self.booksAfter = booksAfter
            self.sourcesAfter = sourcesAfter
            self.remoteUpdatedAt = remoteUpdatedAt
        }
    }

    /// Performs a full two-way sync.
    ///
    /// Order matters: read first, merge, save locally, then upload the merged
    /// result. Uploading before merging would push this device's view over the
    /// other's and lose whatever the other had.
    public func run() async throws -> Result {
        let localBooks = await store.loadBooks()
        let localSources = await store.loadSources()
        let local = SyncPayload(
            updatedAt: Date(),
            deviceID: deviceID,
            books: localBooks,
            sources: localSources
        )

        let remoteData = try await transport.read()
        var remote: SyncPayload?
        if let remoteData {
            do {
                remote = try decodePayload(remoteData)
            } catch let error as SyncError {
                throw error
            } catch {
                // A corrupt or foreign file must not be silently overwritten
                // with this device's data: that would destroy whatever it was.
                // Include the head of the body: "this is an HTML page" and
                // "this is our JSON but a field changed shape" need completely
                // different fixes.
                let head = String(decoding: remoteData.prefix(120), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                throw SyncError.decoding("\(error.localizedDescription)｜内容开头：\(head)")
            }
        }

        guard let remote else {
            // First sync ever: create the file.
            try await upload(local)
            return Result(
                uploaded: true,
                downloaded: false,
                booksAfter: localBooks.count,
                sourcesAfter: localSources.count,
                remoteUpdatedAt: local.updatedAt
            )
        }

        let outcome = SyncMerge.merge(local: local, remote: remote)
        if outcome.localChanged {
            await store.saveBooks(outcome.books)
            await store.saveSources(outcome.sources)
        }

        // Upload whenever anything differs from the remote file, so the other
        // device sees the union on its next run. A plain progress advance on
        // this device counts too: `localChanged` is false then, but the remote
        // copy is now stale.
        let needsUpload = outcome.localChanged || !sameContent(outcome, remote)
        if needsUpload {
            let merged = SyncPayload(
                updatedAt: Date(),
                deviceID: deviceID,
                books: outcome.books,
                sources: outcome.sources
            )
            try await upload(merged)
        }

        return Result(
            uploaded: needsUpload,
            downloaded: outcome.localChanged,
            booksAfter: outcome.books.count,
            sourcesAfter: outcome.sources.count,
            remoteUpdatedAt: needsUpload ? Date() : remote.updatedAt
        )
    }

    /// Decodes the remote file, tolerating a trailing extra closing brace.
    ///
    /// Real files in the wild pick up a stray `}` — a hand edit on the
    /// provider's web UI, a sync tool that appends, a truncated-then-resumed
    /// upload. The payload inside is intact and losing every book over one
    /// character is far worse than accepting it. Anything less specific than a
    /// trailing brace still fails, because guessing deeper would risk merging
    /// the wrong data.
    private func decodePayload(_ data: Data) throws -> SyncPayload {
        try Self.decodeForPreview(data)
    }

    /// Shared by the real sync and the settings screen's connection test, so
    /// the two can never disagree about whether a file is readable.
    public static func decodeForPreview(_ data: Data) throws -> SyncPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(SyncPayload.self, from: data) {
            guard payload.isSupported else {
                throw SyncError.unsupportedVersion(payload.version)
            }
            return payload
        }

        // Find the end of the first complete value and try again on that.
        if let trimmed = trimToFirstValue(data), trimmed.count < data.count {
            let payload = try decoder.decode(SyncPayload.self, from: trimmed)
            guard payload.isSupported else {
                throw SyncError.unsupportedVersion(payload.version)
            }
            return payload
        }

        // Re-decode for the error so the caller sees the real reason.
        let payload = try decoder.decode(SyncPayload.self, from: data)
        guard payload.isSupported else {
            throw SyncError.unsupportedVersion(payload.version)
        }
        return payload
    }

    /// Returns the bytes up to the end of the first balanced top-level value,
    /// or nil when the text does not start with `{`.
    ///
    /// A brace counter that respects strings is enough here: the payload is
    /// always one object, so the first time depth returns to zero is its end.
    static func trimToFirstValue(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.first == UInt8(ascii: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    return Data(bytes[0...index])
                }
            default:
                break
            }
        }
        return nil
    }

    private func upload(_ payload: SyncPayload) async throws {
        let data = try encoder.encode(payload)
        try await transport.write(data)
    }

    /// Compares the merged result with what the remote already has, ignoring
    /// the wrapper's own timestamp and device.
    private func sameContent(_ outcome: SyncMerge.Outcome, _ remote: SyncPayload) -> Bool {
        let remoteBooks = remote.books.sorted { $0.id.uuidString < $1.id.uuidString }
        let remoteSources = remote.sources.sorted { $0.id.uuidString < $1.id.uuidString }
        return remoteBooks == outcome.books && remoteSources == outcome.sources
    }
}
