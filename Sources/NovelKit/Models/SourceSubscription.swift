import Foundation

/// One book-source subscription: a legado source list kept in sync from a URL.
///
/// A subscription is a *link*, not a copy. The sources it delivers are stored
/// as ordinary `BookSource` records tagged with this id, so everything that
/// already works on a source — search, explore, the reader, sync — keeps
/// working without knowing where it came from. What the subscription adds is
/// the right to go back and ask the URL what the list looks like *now*.
public struct SourceSubscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Shown in the settings list; defaults to the URL's host when blank.
    public var name: String
    /// Direct link to a legado JSON array of sources.
    public var url: String
    public var isEnabled: Bool
    /// A source list found inside a wrapper object (a collection site's page)
    /// rather than a bare array of `bookSourceName` records.
    ///
    /// Only consulted when the subscription's own latest fetch was shaped that
    /// way. Kept per subscription because the shape belongs to the site.
    public var sourceListKey: String?
    public var addedAt: Date
    public var lastUpdatedAt: Date?
    /// What the last refresh did, in words, for the settings row.
    public var lastResult: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        url: String,
        isEnabled: Bool = true,
        sourceListKey: String? = nil,
        addedAt: Date = Date(),
        lastUpdatedAt: Date? = nil,
        lastResult: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.sourceListKey = sourceListKey
        self.addedAt = addedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastResult = lastResult
    }

    /// The name to show: the user's, else the host.
    public var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return URL(string: url)?.host ?? url
    }
}

/// What one refresh of one subscription changed.
public struct SubscriptionRefreshResult: Codable, Hashable, Sendable {
    /// Sources the subscription delivered that were not on this device before.
    public var added: Int
    /// Sources whose rules changed. Same identity (name + site), new content.
    public var updated: Int
    /// Sources the subscription no longer lists, and that no shelf book uses.
    public var removed: Int
    /// Sources the subscription dropped but the shelf still needs. Kept, so a
    /// book in progress does not lose the only source that can open it.
    public var keptInUse: Int
    /// Names of the kept sources, for the shelf's banner.
    public var keptSourceNames: [String]
    /// Books on the shelf whose source this refresh deleted.
    public var orphanedBookNames: [String]
    /// A human sentence, stored on the subscription for the settings row.
    public var summary: String
    /// Set when the fetch or parse failed. The old sources are left alone.
    public var error: String?

    public init(
        added: Int = 0,
        updated: Int = 0,
        removed: Int = 0,
        keptInUse: Int = 0,
        keptSourceNames: [String] = [],
        orphanedBookNames: [String] = [],
        summary: String = "",
        error: String? = nil
    ) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.keptInUse = keptInUse
        self.keptSourceNames = keptSourceNames
        self.orphanedBookNames = orphanedBookNames
        self.summary = summary
        self.error = error
    }

    public var isFailure: Bool { error != nil }

    /// Whether anything needs telling to the user beyond the settings row.
    public var changedSomething: Bool {
        added + updated + removed > 0
    }
}
