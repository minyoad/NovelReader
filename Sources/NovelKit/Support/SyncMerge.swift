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
    /// Subscriptions travel with the sources they own.
    ///
    /// Without them a device would receive sources tagged with a subscription
    /// id it has never heard of: it could not refresh them, and the tag would
    /// never resolve. Optional so a file written by a build without
    /// subscriptions still decodes.
    public var subscriptions: [SourceSubscription]?

    public static let currentVersion = 1

    public init(
        version: Int = SyncPayload.currentVersion,
        updatedAt: Date = Date(),
        deviceID: String,
        books: [Book],
        sources: [BookSource],
        subscriptions: [SourceSubscription]? = nil
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.books = books
        self.sources = sources
        self.subscriptions = subscriptions
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
        public var subscriptions: [SourceSubscription]
        /// True when the merged result differs from `local`, so the caller
        /// knows it has to save and re-upload.
        public var localChanged: Bool

        public init(
            books: [Book],
            sources: [BookSource],
            subscriptions: [SourceSubscription] = [],
            localChanged: Bool
        ) {
            self.books = books
            self.sources = sources
            self.subscriptions = subscriptions
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
        //
        // Two keys, for the same reason as books below. A source's id is minted
        // when it is imported, so the same collection imported on two devices
        // gives every source two ids, and keying on id alone made the union keep
        // both: a shelf of 211 sources was really 100-odd sources and their
        // twins. The identifying pair is the name and the site — the two things
        // a person would use to say "this is the same source" — with the URL
        // normalized first, because the importer strips a trailing `#🎃` that
        // some collections leave on the URL.
        var sourceMap = Dictionary(uniqueKeysWithValues: local.sources.map { ($0.id, $0) })
        var sourcesByIdentity: [SourceIdentity: UUID] = [:]
        for source in local.sources {
            sourcesByIdentity[SourceIdentity(of: source)] = sourcesByIdentity[SourceIdentity(of: source)] ?? source.id
        }

        for source in remote.sources {
            if let existing = sourceMap[source.id] {
                if existing != source {
                    sourceMap[source.id] = source
                    changed = true
                }
                continue
            }

            // Same source under another id.
            let identity = SourceIdentity(of: source)
            if let existingID = sourcesByIdentity[identity], let existing = sourceMap[existingID] {
                // Keep this device's id — books point at it — but take the
                // newer rules. Rules do not carry a timestamp, so the remote
                // copy wins only when the local one has nothing: a collection
                // re-imported on the other device should refresh this one, and
                // this device's own edits should not be silently undone.
                var merged = existing
                if merged.searchURL.isEmpty && !source.searchURL.isEmpty {
                    merged = source
                    merged.id = existing.id
                    // This device had it switched on or off deliberately.
                    merged.enabled = existing.enabled
                    sourceMap[existingID] = merged
                    changed = true
                }
                continue
            }

            sourceMap[source.id] = source
            sourcesByIdentity[identity] = source.id
            changed = true
        }

        // Fold duplicates already on the local list, and record which id took
        // each one's place so book references can follow.
        var seenIdentities: [SourceIdentity: UUID] = [:]
        var replacedIDs: [UUID: UUID] = [:]
        for (id, source) in sourceMap.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let identity = SourceIdentity(of: source)
            guard let keptID = seenIdentities[identity] else {
                seenIdentities[identity] = id
                continue
            }
            sourceMap.removeValue(forKey: id)
            replacedIDs[id] = keptID
            changed = true
        }

        // Books: union, with the winner chosen by reading progress.
        //
        // Two keys, not one. `id` is a UUID minted when the book was added, so
        // the same book added separately on two devices gets two different ids
        // and the union shows it twice. That is not hypothetical: a shelf ended
        // up with the same novel twice, one copy at chapter 300 and one never
        // opened, purely because each device had added it. So a book is also
        // identified by where it comes from — same source rule and same detail
        // page URL is the same book — and the duplicate is folded away.
        var bookMap = Dictionary(uniqueKeysWithValues: local.books.map { ($0.id, $0) })
        var booksByOrigin: [OriginKey: UUID] = [:]
        for book in local.books {
            // First one wins when the local shelf is *already* duplicated; the
            // fold below cleans that up against the remote copy.
            guard let key = OriginKey(book: book) else { continue }
            booksByOrigin[key] = booksByOrigin[key] ?? book.id
        }

        for remoteBook in remote.books {
            // An id match is authoritative: it is the same record.
            if let localBook = bookMap[remoteBook.id] {
                if let winner = winner(localBook, remoteBook), winner == remoteBook {
                    let merged = mergeCopy(winning: remoteBook, local: localBook)
                    // Only a real difference counts: the id path also sees
                    // books the cross-device path already folded, and claiming
                    // a change there makes every sync re-upload forever.
                    if merged != localBook {
                        bookMap[remoteBook.id] = merged
                        changed = true
                    }
                }
                continue
            }

            guard let key = OriginKey(book: remoteBook) else {
                // No detail URL: nothing identifies it, so id is all there is.
                bookMap[remoteBook.id] = remoteBook
                changed = true
                continue
            }
            if let existingID = booksByOrigin[key], let localBook = bookMap[existingID] {
                // Same book under another id. Keep whichever copy the progress
                // rules prefer, filed under the id this device already uses so
                // the local shelf does not churn, and never keep both.
                //
                // `addedAt` here is the earliest of *both* copies: the remote
                // one may be the older record, and carrying only the local date
                // forward would make the book look re-added on every merge.
                let kept = winner(localBook, remoteBook) ?? localBook
                var merged = mergeCopy(winning: kept, local: localBook)
                merged.addedAt = min(localBook.addedAt, remoteBook.addedAt)
                if merged != localBook {
                    bookMap[existingID] = merged
                    changed = true
                }
                continue
            }

            bookMap[remoteBook.id] = remoteBook
            booksByOrigin[key] = remoteBook.id
            changed = true
        }

        // Fold duplicates within the local shelf itself. Without this, two
        // copies the merge failed to collapse earlier stay forever, because
        // every later merge treats them as two unrelated books.
        var seenOrigins: [OriginKey: UUID] = [:]
        for (id, book) in bookMap.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let key = OriginKey(book: book) else { continue }
            guard let keptID = seenOrigins[key], let kept = bookMap[keptID] else {
                seenOrigins[key] = id
                continue
            }
            let keptBook = mergeCopy(winning: winner(kept, book) ?? kept, local: kept)
            var folded = keptBook
            folded.addedAt = min(kept.addedAt, book.addedAt)
            if folded != kept {
                bookMap[keptID] = folded
            }
            bookMap.removeValue(forKey: id)
            changed = true
        }

        // Books whose source id was folded away point at a source that is no
        // longer on the list: they would lose their rules and show as
        // "书源已删除". Re-point them at whichever copy survived.
        if !replacedIDs.isEmpty {
            for (id, book) in bookMap where replacedIDs[book.sourceID] != nil {
                var fixed = book
                fixed.sourceID = replacedIDs[book.sourceID]!
                bookMap[id] = fixed
                changed = true
            }
        }

        // Subscriptions are a union by id, newest record wins.
        //
        // They are few (a person follows a handful of lists) and carry no
        // per-field conflicts worth resolving: an enabled flag and a timestamp
        // are the whole mutable surface. The newest `lastUpdatedAt` wins, and
        // a local-only subscription is never dropped by a device that has not
        // heard of it.
        var subscriptionMap: [UUID: SourceSubscription] = [:]
        for subscription in local.subscriptions ?? [] {
            subscriptionMap[subscription.id] = subscription
        }
        for subscription in remote.subscriptions ?? [] {
            if let existing = subscriptionMap[subscription.id] {
                let incoming = (subscription.lastUpdatedAt ?? .distantPast)
                let current = (existing.lastUpdatedAt ?? .distantPast)
                let winner = incoming > current ? subscription : existing
                if winner != existing {
                    subscriptionMap[subscription.id] = winner
                    changed = true
                }
            } else {
                subscriptionMap[subscription.id] = subscription
                changed = true
            }
        }
        let subscriptions = subscriptionMap.values.sorted { $0.addedAt < $1.addedAt }

        return Outcome(
            books: bookMap.values.sorted { $0.id.uuidString < $1.id.uuidString },
            sources: sourceMap.values.sorted { $0.id.uuidString < $1.id.uuidString },
            subscriptions: subscriptions,
            localChanged: changed
        )
    }

    /// What makes two records the same book across devices.
    ///
    /// `sourceID` alone is too coarse — one source lists thousands of novels —
    /// and `detailURL` alone would trust a URL that a source rule could serve
    /// for several entries. Together they name one page on one site.
    ///
    /// A book with no detail URL (or an empty one) gets no origin key: there is
    /// nothing to say two such books are the same, and merging on a title would
    /// fold genuinely different books — "青山" exists on more than one site.
    private struct OriginKey: Hashable {
        let sourceID: UUID
        let detailURL: String

        init?(book: Book) {
            let url = book.detailURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            self.sourceID = book.sourceID
            // Compare normalized: trailing slashes and case in the host vary
            // between how a link was copied and how the source rule built it.
            self.detailURL = url.hasSuffix("/") ? String(url.dropLast()) : url
        }
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
