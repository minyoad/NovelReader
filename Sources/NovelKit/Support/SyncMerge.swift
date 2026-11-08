import Foundation

/// The payload that travels between devices.
///
/// Deliberately narrow: books, sources and reading progress. Chapter bodies are
/// large, change constantly and can be re-downloaded from the source site, so
/// syncing them would make every sync slow and every conflict expensive. What
/// cannot be re-derived is what the user has accumulated — which sources they
/// imported, which books are on the shelf, and where they are in each one.
public struct SyncPayload: Codable, Sendable, Equatable {
    /// Bumped when the shape changes. An unknown version is refused rather
    /// than half-decoded, because a partial merge writes the wrong progress.
    public var version: Int
    /// When the file was written. Used for display and as the last tie-break.
    public var updatedAt: Date
    /// Which device wrote it, so a device can recognise its own upload.
    public var deviceID: String
    public var books: [Book]
    public var sources: [BookSource]

    public static let currentVersion = 1

    public init(
        version: Int = SyncPayload.currentVersion,
        updatedAt: Date = Date(),
        deviceID: String,
        books: [Book],
        sources: [BookSource]
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.books = books
        self.sources = sources
    }

    /// Whether this file is from a version this build understands.
    public var isSupported: Bool { version <= SyncPayload.currentVersion }
}

/// Merges two payloads. Pure, so the rules are testable without a network.
public enum SyncMerge {

    /// Result of a merge.
    public struct Outcome: Sendable, Equatable {
        public var books: [Book]
        public var sources: [BookSource]
        /// True when the merged result differs from `local`, so the caller
        /// knows it has to save and re-upload.
        public var localChanged: Bool

        public init(books: [Book], sources: [BookSource], localChanged: Bool) {
            self.books = books
            self.sources = sources
            self.localChanged = localChanged
        }
    }

    /// Merges `remote` into `local`, keyed by id.
    ///
    /// Rules:
    /// - anything present on only one side is kept. The union *is* the point of
    ///   syncing; dropping the other side's additions is how a sync silently
    ///   deletes a shelf;
    /// - a book on both sides keeps the newer reading progress. "Newer" is
    ///   `progress.updatedAt`, and never having read a book never beats having
    ///   read it — otherwise a device that has not opened the book resets the
    ///   other device to chapter one;
    /// - the winning side's book is taken whole, so a book is never stitched
    ///   together from two versions that disagree about its title or chapters;
    ///   only `addedAt` stays local, because it is when *this* shelf got the
    ///   book and copying it would reshuffle the shelf on every sync;
    /// - sources are keyed by id and never merged field by field. A source is
    ///   a coherent set of rules; half of one and half of another matches
    ///   neither site.
    public static func merge(local: SyncPayload, remote: SyncPayload) -> Outcome {
        var changed = false

        // Sources: remote fills gaps, and replaces an existing source only when
        // the two disagree — meaning one side re-imported or edited it.
        var sourceMap = Dictionary(uniqueKeysWithValues: local.sources.map { ($0.id, $0) })
        for source in remote.sources {
            if let existing = sourceMap[source.id] {
                if existing != source {
                    sourceMap[source.id] = source
                    changed = true
                }
            } else {
                sourceMap[source.id] = source
                changed = true
            }
        }

        // Books: union, with the winner chosen by reading progress.
        var bookMap = Dictionary(uniqueKeysWithValues: local.books.map { ($0.id, $0) })
        for remoteBook in remote.books {
            guard let localBook = bookMap[remoteBook.id] else {
                bookMap[remoteBook.id] = remoteBook
                changed = true
                continue
            }
            if let winner = winner(localBook, remoteBook), winner == remoteBook {
                bookMap[remoteBook.id] = mergeCopy(winning: remoteBook, local: localBook)
                changed = true
            }
        }

        return Outcome(
            books: bookMap.values.sorted { $0.id.uuidString < $1.id.uuidString },
            sources: sourceMap.values.sorted { $0.id.uuidString < $1.id.uuidString },
            localChanged: changed
        )
    }

    private static func mergeCopy(winning: Book, local: Book) -> Book {
        var copy = winning
        // `addedAt` is when this device put the book on its shelf.
        copy.addedAt = min(local.addedAt, winning.addedAt)
        return copy
    }

    /// Which of two copies of the same book should be kept.
    ///
    /// Returns nil when they are already identical, so the caller does not
    /// rewrite the file for nothing.
    public static func winner(_ lhs: Book, _ rhs: Book) -> Book? {
        if lhs == rhs { return nil }

        switch (lhs.progress.updatedAt, rhs.progress.updatedAt) {
        case let (left?, right?):
            if left != right { return left > right ? lhs : rhs }
        case (.some, .none):
            return lhs
        case (.none, .some):
            return rhs
        case (.none, .none):
            break
        }

        // Equal (or absent) progress: fall back to editorial metadata so an
        // updated chapter list still propagates.
        let left = lhs.lastReadAt ?? lhs.addedAt
        let right = rhs.lastReadAt ?? rhs.addedAt
        if left != right { return left > right ? lhs : rhs }
        // Fully tied but not equal in content: keep local to stay stable
        // across repeated syncs instead of flip-flopping between devices.
        return nil
    }
}
