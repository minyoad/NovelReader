import Foundation

/// Runs one sync: read remote, merge, upload, then commit locally.
///
/// All of it is in NovelKit so it can be tested on Linux with a fake
/// transport; the app layer only supplies settings and triggers.
public actor SyncService {
    private let transport: SyncTransport
    private let store: LibraryStore
    private let deviceID: String
    /// This device's connection details, written into the upload so another
    /// device can set itself up from the file alone.
    ///
    /// A snapshot taken by the caller rather than read from the store: the
    /// service must not know about `AppSettings`, and the caller already holds
    /// the settings it is syncing with.
    private let endpoint: SyncEndpoint?
    /// This device's AI settings, written into the upload for the same reason.
    private let ai: SyncedAISettings?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        transport: SyncTransport,
        store: LibraryStore,
        deviceID: String,
        endpoint: SyncEndpoint? = nil,
        ai: SyncedAISettings? = nil
    ) {
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        self.endpoint = endpoint
        self.ai = ai
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
        public var progressAdvances: [SyncProgressAdvance]
        /// The connection details to apply locally, or nil when there is
        /// nothing new. The caller decides whether to adopt them; the service
        /// has no business writing settings.
        public var endpoint: SyncEndpoint?
        /// The AI settings to apply locally, or nil when there is nothing new.
        public var ai: SyncedAISettings?

        public init(
            uploaded: Bool,
            downloaded: Bool,
            booksAfter: Int,
            sourcesAfter: Int,
            remoteUpdatedAt: Date?,
            progressAdvances: [SyncProgressAdvance] = [],
            endpoint: SyncEndpoint? = nil,
            ai: SyncedAISettings? = nil
        ) {
            self.uploaded = uploaded
            self.downloaded = downloaded
            self.booksAfter = booksAfter
            self.sourcesAfter = sourcesAfter
            self.remoteUpdatedAt = remoteUpdatedAt
            self.progressAdvances = progressAdvances
            self.endpoint = endpoint
            self.ai = ai
        }
    }

    /// Performs a full two-way sync.
    ///
    /// Read and merge before uploading, then commit locally only after the
    /// upload succeeds. A failed run must not consume a remote progress change
    /// without giving the UI a successful result to present.
    public func run() async throws -> Result {
        // Read the potentially slow network first; progress saved while it is
        // pending must be part of the local merge snapshot.
        let remoteData = try await transport.read()
        let localBooks = await store.loadBooks()
        let localSources = await store.loadSources()
        let localSubscriptions = await store.loadSubscriptions()
        let local = SyncPayload(
            updatedAt: Date(),
            deviceID: deviceID,
            books: localBooks,
            sources: localSources,
            subscriptions: localSubscriptions,
            endpoint: endpoint,
            ai: ai
        )

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
                remoteUpdatedAt: local.updatedAt,
                endpoint: endpoint,
                ai: ai
            )
        }

        let outcome = SyncMerge.merge(local: local, remote: remote)
        let advances = SyncProgressAdvance.detect(local: localBooks, merged: outcome.books)

        // Upload whenever anything differs from the remote file, so the other
        // device sees the union on its next run. A plain progress advance on
        // this device counts too: `localChanged` is false then, but the remote
        // copy is now stale.
        let needsUpload = outcome.localChanged || !sameContent(outcome, remote)
        var uploadedAt: Date?
        if needsUpload {
            let now = Date()
            let merged = SyncPayload(
                updatedAt: now,
                deviceID: deviceID,
                books: outcome.books,
                sources: outcome.sources,
                subscriptions: outcome.subscriptions,
                endpoint: outcome.endpoint,
                ai: outcome.ai
            )
            try await upload(merged)
            uploadedAt = now
        }

        // A failed upload must not silently consume the remote progress: the
        // next successful run still needs to report the advance to the UI.
        let waiting = await store.loadSyncProgressAdvances()
        var pending = Dictionary(waiting.filter { advance in
            outcome.books.contains {
                $0.id == advance.id && $0.sourceID == advance.remoteBook.sourceID
                    && $0.progress == advance.remoteBook.progress
            }
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var advance in advances {
            advance.localProgress = waiting.first { $0.id == advance.id }?.localProgress ?? advance.localProgress
            pending[advance.id] = advance
        }
        // Save the question before the adopted position, so a background sync
        // followed by process termination still asks before resuming remotely.
        await store.saveSyncProgressAdvances(Array(pending.values))
        if outcome.localChanged {
            await store.saveBooks(outcome.books)
            await store.saveSources(outcome.sources)
            await store.saveSubscriptions(outcome.subscriptions)
        }

        return Result(
            uploaded: needsUpload,
            downloaded: outcome.localChanged,
            booksAfter: outcome.books.count,
            sourcesAfter: outcome.sources.count,
            // The time of the file that is now on the server: this device's own
            // upload, or the remote file it merged from. Reporting a fresh
            // `Date()` here would drift from the file by the upload's latency,
            // and a later sync compares against it to decide whether the file
            // has been written by someone else since.
            remoteUpdatedAt: uploadedAt ?? remote.updatedAt,
            progressAdvances: advances,
            endpoint: outcome.endpoint,
            ai: outcome.ai
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
    ///
    /// The endpoint is deliberately left out: it is settings, not content, and
    /// a device whose own address differs from the file's would otherwise
    /// re-upload on every single run just to restate the same values.
    private func sameContent(_ outcome: SyncMerge.Outcome, _ remote: SyncPayload) -> Bool {
        let remoteBooks = remote.books.sorted { $0.id.uuidString < $1.id.uuidString }
        let remoteSources = remote.sources.sorted { $0.id.uuidString < $1.id.uuidString }
        // A remote file written before subscriptions existed decodes with the
        // field absent; comparing nil against an empty list would re-upload on
        // every sync forever.
        let remoteSubscriptions = (remote.subscriptions ?? []).sorted { $0.addedAt < $1.addedAt }
        // Same for AI settings: a device that has none, or an older file, must
        // not force a re-upload just to restate what is already there.
        let remoteAI = remote.ai
        let aiMatches = (remoteAI == nil && outcome.ai == nil) || remoteAI == outcome.ai
        return remoteBooks == outcome.books
            && remoteSources == outcome.sources
            && remoteSubscriptions == outcome.subscriptions
            && aiMatches
    }
}
