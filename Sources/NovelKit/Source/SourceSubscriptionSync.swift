import Foundation

/// Applies one subscription's fetched list to the sources on this device.
///
/// Pure: it takes the sources as they are, the sources the subscription now
/// delivers, and the shelf, and returns what to keep plus a report. The
/// networking and the disk writes stay outside, which is what makes the rules
/// — the part that can delete a source or strand a book — testable without a
/// site to point at.
///
/// The rules, in order of who wins:
///
/// 1. **Shelf books win over the list.** A source a book on the shelf still
///    uses is never deleted, even if the subscription dropped it. Books in
///    progress are the thing this app exists to keep; a list that forgot a
///    site is not a reason to lose the only way back to a chapter 300 in.
/// 2. **A subscription only removes its own sources.** Sources the user
///    pasted, imported from a collection or got with the build are untouchable
///    here. Otherwise subscribing would be a way to lose a hand-tuned source.
/// 3. **Identity is name + site**, the same pair the importer and the sync
///    merge use. A source the list renames or moves counts as removed + added,
///    which is honest: it is a different record to everything else.
public enum SourceSubscriptionSync {

    public struct Outcome: Sendable, Equatable {
        /// The device's sources after the refresh, in their original order
        /// with additions appended.
        public var sources: [BookSource]
        /// Whether anything changed, so the caller knows to write.
        public var changed: Bool
        public var report: SubscriptionRefreshResult

        public init(
            sources: [BookSource],
            changed: Bool,
            report: SubscriptionRefreshResult
        ) {
            self.sources = sources
            self.changed = changed
            self.report = report
        }
    }

    /// - Parameters:
    ///   - current: everything on the device right now.
    ///   - delivered: the sources the subscription lists now, freshly parsed.
    ///   - subscriptionID: the subscription being refreshed.
    ///   - shelfSourceIDs: sources some book on the shelf still points at.
    ///   - shelfBookNames: book title for each source id on the shelf, so a
    ///     kept-but-dropped source can say which books it is holding up.
    public static func apply(
        current: [BookSource],
        delivered: [BookSource],
        subscriptionID: UUID,
        shelfSourceIDs: Set<UUID> = [],
        shelfBookNames: [UUID: [String]] = [:]
    ) -> Outcome {
        var sources = current
        var added = 0
        var updated = 0

        // Index by identity once: a two-hundred-source list against a
        // two-hundred-source device is otherwise forty thousand comparisons.
        var byIdentity: [SourceIdentity: Int] = [:]
        for (index, source) in sources.enumerated() {
            byIdentity[SourceIdentity(of: source)] = index
        }

        var deliveredIdentities = Set<SourceIdentity>()

        for var incoming in delivered {
            let identity = SourceIdentity(of: incoming)
            deliveredIdentities.insert(identity)

            if let index = byIdentity[identity] {
                let existing = sources[index]
                // Keep the id: books on the shelf point at it, and the
                // subscription is refreshing rules, not replacing records.
                incoming.id = existing.id
                incoming.isBuiltIn = existing.isBuiltIn
                // The user's on/off choice outlives a rules update.
                incoming.enabled = existing.enabled
                // Ownership never moves here.
                //
                // A source that was already here — pasted by hand, imported
                // from a collection, or left by a subscription the user has
                // since removed — stays where it is. Adopting it now would
                // hand this subscription the right to delete it later, and the
                // user never asked for that. A delivered source that is absent
                // by identity is added below and belongs to this subscription.
                incoming.subscriptionID = existing.subscriptionID

                if !sameContent(existing, incoming) {
                    sources[index] = incoming
                    updated += 1
                } else if existing.subscriptionID != incoming.subscriptionID {
                    sources[index] = incoming
                }
            } else {
                incoming.subscriptionID = subscriptionID
                sources.append(incoming)
                byIdentity[identity] = sources.count - 1
                added += 1
            }
        }

        // Removal: only this subscription's sources, and only when the list no
        // longer has them.
        var removed = 0
        var kept = 0
        var keptNames: [String] = []
        var removedIDs = Set<UUID>()

        for source in sources where source.subscriptionID == subscriptionID {
            guard !deliveredIdentities.contains(SourceIdentity(of: source)) else { continue }
            if shelfSourceIDs.contains(source.id) {
                kept += 1
                keptNames.append(source.name)
            } else {
                removedIDs.insert(source.id)
                removed += 1
            }
        }

        if !removedIDs.isEmpty {
            sources.removeAll { removedIDs.contains($0.id) }
        }

        // Books whose source this refresh just deleted: the shelf can still
        // show them (the source name is denormalised on the book), but they
        // cannot be read until a new source is picked.
        var orphaned: [String] = []
        for id in removedIDs {
            orphaned.append(contentsOf: shelfBookNames[id] ?? [])
        }

        var report = SubscriptionRefreshResult(
            added: added,
            updated: updated,
            removed: removed,
            keptInUse: kept,
            keptSourceNames: keptNames.sorted(),
            orphanedBookNames: orphaned.sorted()
        )
        report.summary = summarize(report)

        return Outcome(
            sources: sources,
            changed: added > 0 || updated > 0 || removed > 0,
            report: report
        )
    }

    /// Whether two records of the same source carry the same rules.
    ///
    /// Compares everything that affects fetching, but not the bookkeeping: a
    /// source with the same rules is not "updated" just because the list
    /// re-ordered its own fields or the record's id was reassigned.
    static func sameContent(_ lhs: BookSource, _ rhs: BookSource) -> Bool {
        var a = lhs
        var b = rhs
        a.id = b.id
        a.isBuiltIn = b.isBuiltIn
        a.lastUsedAt = b.lastUsedAt
        a.subscriptionID = b.subscriptionID
        a.enabled = b.enabled
        return a == b
    }

    static func summarize(_ report: SubscriptionRefreshResult) -> String {
        var parts: [String] = []
        if report.added > 0 { parts.append("新增 \(report.added)") }
        if report.updated > 0 { parts.append("更新 \(report.updated)") }
        if report.removed > 0 { parts.append("移除 \(report.removed)") }
        if report.keptInUse > 0 { parts.append("保留 \(report.keptInUse)（书架在用）") }
        guard !parts.isEmpty else { return "已是最新" }
        return parts.joined(separator: "，")
    }
}
