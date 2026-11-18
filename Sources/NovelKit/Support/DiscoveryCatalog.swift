import Foundation

public struct DiscoveryEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public var variants: [SearchResult]
    public var primary: SearchResult { variants[0] }
    public var sourceCount: Int { Set(variants.map(\.sourceID)).count }
}

public struct DiscoverySourceHealth: Codable, Equatable, Sendable {
    public var lastSuccess: Date?
    public var latency: Double?
    public var failures: Int = 0
    public var retryAfter: Date?
    public init() {}

    public mutating func record(success: Bool, latency: Double, now: Date) {
        if success {
            lastSuccess = now
            self.latency = latency
            failures = 0
            retryAfter = nil
        } else {
            failures = min(failures + 1, 6)
            retryAfter = now.addingTimeInterval(min(1800, 300 * Double(failures)))
        }
    }
}

public struct DiscoveryFeedCache: Codable, Sendable {
    public var version = 1
    // The store's shared ISO-8601 encoder drops fractional seconds. Preserve
    // ordering between streamed pages/preferences saved within the same second.
    private var savedAtSeconds: Double
    public var savedAt: Date {
        get { Date(timeIntervalSince1970: savedAtSeconds) }
        set { savedAtSeconds = newValue.timeIntervalSince1970 }
    }
    public var updatedAt: Date?
    public var results: [SearchResult]
    public var fingerprints: [String: String]
    public var health: [String: DiscoverySourceHealth]
    public var selectedSourceIDs: [UUID]
    public var visibleIDs: [String]
    public var round: Int

    public init(savedAt: Date = Date(), updatedAt: Date? = nil, results: [SearchResult] = [],
                fingerprints: [String: String] = [:], health: [String: DiscoverySourceHealth] = [:],
                selectedSourceIDs: [UUID] = [], visibleIDs: [String] = [], round: Int = 0) {
        self.savedAtSeconds = savedAt.timeIntervalSince1970
        self.updatedAt = updatedAt
        self.results = results
        self.fingerprints = fingerprints
        self.health = health
        self.selectedSourceIDs = selectedSourceIDs
        self.visibleIDs = visibleIDs
        self.round = round
    }
}

/// Identity is conservative: title + a known author can merge across sources;
/// missing/unknown authors retain source + URL identity. All versions survive.
public enum DiscoveryCatalog {
    public static let batchSize = 20
    public static let sourceLimit = 5
    public static let automaticSourceCount = 3
    public static let resultLimit = 40
    public static let cacheLimit = 300

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { !$0.isWhitespace }
    }

    private static func knownAuthor(_ value: String) -> String? {
        let author = normalized(value)
        return ["", "佚名", "未知", "未知作者", "作者未知", "匿名"].contains(author) ? nil : author
    }

    public static func identity(_ result: SearchResult) -> String {
        guard let author = knownAuthor(result.author) else { return "origin|\(result.id)" }
        // Lengths avoid delimiter collisions without rewriting book titles.
        let title = normalized(result.name)
        return "book|\(title.count):\(title)|\(author.count):\(author)"
    }

    public static func entries(_ results: [SearchResult]) -> [DiscoveryEntry] {
        var positions: [String: Int] = [:]
        var entries: [DiscoveryEntry] = []
        for result in results where !result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !result.detailURL.isEmpty {
            let id = identity(result)
            if let index = positions[id] {
                if let variant = entries[index].variants.firstIndex(where: { $0.id == result.id }) {
                    entries[index].variants[variant] = result
                } else {
                    entries[index].variants.append(result)
                }
            } else {
                positions[id] = entries.count
                entries.append(DiscoveryEntry(id: id, variants: [result]))
            }
        }
        return entries
    }

    public static func merge(_ incoming: [SearchResult], into existing: [SearchResult]) -> [SearchResult] {
        var results = existing
        var positions = Dictionary(existing.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for result in boundedResults(incoming, limit: resultLimit) {
            if let index = positions[result.id] { results[index] = result }
            else { positions[result.id] = results.count; results.append(result) }
        }
        return Array(results.suffix(cacheLimit))
    }

    /// Discovery stores summaries, not full chapter-sized descriptions from a
    /// broken listing rule. Detail/preview still fetches the complete metadata.
    public static func boundedResults(_ results: [SearchResult], limit: Int = cacheLimit) -> [SearchResult] {
        results.prefix(max(0, limit)).compactMap { item in
            guard item.name.utf8.count <= 1024, item.author.utf8.count <= 512,
                  item.detailURL.utf8.count <= 8192 else { return nil }
            var item = item
            item.sourceName = String(item.sourceName.prefix(128))
            item.intro = String(item.intro.prefix(1200))
            item.kind = String(item.kind.prefix(128))
            item.updateTime = String(item.updateTime.prefix(128))
            item.lastChapterTitle = String(item.lastChapterTitle.prefix(256))
            if (item.coverURL?.utf8.count ?? 0) > 8192 { item.coverURL = nil }
            return item
        }
    }

    public static func preferredEntries(_ results: [SearchResult], health: [String: DiscoverySourceHealth], now: Date = Date()) -> [DiscoveryEntry] {
        entries(results).map { entry in
            var ranked = entry
            ranked.variants = entry.variants.enumerated().sorted { left, right in
                let l = health[left.element.sourceID.uuidString], r = health[right.element.sourceID.uuidString]
                let lc = (l?.retryAfter ?? .distantPast) > now, rc = (r?.retryAfter ?? .distantPast) > now
                if lc != rc { return !lc }
                let lu = l?.lastSuccess.map { now.timeIntervalSince($0) < 86400 } ?? false
                let ru = r?.lastSuccess.map { now.timeIntervalSince($0) < 86400 } ?? false
                if lu != ru { return lu }
                if l?.latency != r?.latency { return (l?.latency ?? .infinity) < (r?.latency ?? .infinity) }
                return left.offset < right.offset
            }.map(\.element)
            return ranked
        }
    }

    /// Round-robin between primary sources prevents one long list from filling
    /// the entire batch. Existing visible IDs are kept by the UI while streaming.
    public static func batch(_ entries: [DiscoveryEntry], excluding: Set<String>, limit: Int = batchSize) -> [DiscoveryEntry] {
        var order: [UUID] = []
        var buckets: [UUID: [DiscoveryEntry]] = [:]
        for entry in entries where !excluding.contains(entry.id) {
            let source = entry.primary.sourceID
            if buckets[source] == nil { order.append(source) }
            buckets[source, default: []].append(entry)
        }
        var result: [DiscoveryEntry] = []
        var index = 0
        while result.count < max(limit, 0) {
            var added = false
            for source in order where result.count < limit {
                if let bucket = buckets[source], bucket.indices.contains(index) {
                    result.append(bucket[index]); added = true
                }
            }
            if !added { break }
            index += 1
        }
        return result
    }

    public static func shelfBook(for entry: DiscoveryEntry, in books: [Book]) -> Book? {
        books.first { book in
            if entry.variants.contains(where: { $0.sourceID == book.sourceID && $0.detailURL == book.detailURL }) { return true }
            guard let author = knownAuthor(entry.primary.author), let bookAuthor = knownAuthor(book.author) else { return false }
            return normalized(entry.primary.name) == normalized(book.name) && author == bookAuthor
        }
    }

    public static func fingerprint(_ source: BookSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Only discovery inputs participate: pinning/reading a source should
        // not invalidate cached books or health measurements.
        let value: [String: JSONValue] = [
            "base": .string(source.baseURL), "name": .string(source.name), "header": .string(source.header),
            "categories": .string(source.exploreURL),
            "search": (try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(source.search))) ?? .null,
            "explore": (try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(source.explore))) ?? .null
        ]
        let data = (try? encoder.encode(JSONValue.object(value))) ?? Data()
        return StableHash.hex(String(decoding: data, as: UTF8.self))
    }

    public static func validResults(_ cache: DiscoveryFeedCache, sources: [BookSource]) -> [SearchResult] {
        guard cache.version == 1 else { return [] }
        let valid = Dictionary(sources.filter { $0.enabled && $0.type == .text && $0.canExplore }
            .map { ($0.id, fingerprint($0)) }, uniquingKeysWith: { first, _ in first })
        let selected = Set(cache.selectedSourceIDs)
        return boundedResults(Array(cache.results.filter {
            valid[$0.sourceID] != nil && valid[$0.sourceID] == cache.fingerprints[$0.sourceID.uuidString]
                && (selected.isEmpty || selected.contains($0.sourceID))
        }.suffix(cacheLimit)))
    }

    public static func plan(sources: [BookSource], selected: [UUID], health: [String: DiscoverySourceHealth],
                            round: Int, rotate: Bool, force: Bool, now: Date = Date()) -> [BookSource] {
        let selected = Set(selected.prefix(sourceLimit))
        var candidates = sources.filter {
            $0.enabled && $0.type == .text && $0.canExplore && (selected.isEmpty || selected.contains($0.id))
                && (force || (health[$0.id.uuidString]?.retryAfter ?? .distantPast) <= now)
        }
        candidates.sort {
            let left = health[$0.id.uuidString], right = health[$1.id.uuidString]
            if (left?.lastSuccess != nil) != (right?.lastSuccess != nil) { return left?.lastSuccess != nil }
            if left?.latency != right?.latency { return (left?.latency ?? .infinity) < (right?.latency ?? .infinity) }
            return $0.id.uuidString < $1.id.uuidString
        }
        if selected.isEmpty, rotate, !candidates.isEmpty {
            let offset = (max(round, 0) % candidates.count * automaticSourceCount) % candidates.count
            candidates = Array(candidates[offset...]) + Array(candidates[..<offset])
        }
        return Array(candidates.prefix(selected.isEmpty ? automaticSourceCount : sourceLimit))
    }

    public static func category(for source: BookSource, round: Int) -> ExploreCategory? {
        let keywords = ["推荐", "精选", "热门", "排行", "新书", "最新"]
        let categories = source.openableExploreCategories.enumerated().sorted { left, right in
            let l = keywords.firstIndex { left.element.name.contains($0) } ?? keywords.count
            let r = keywords.firstIndex { right.element.name.contains($0) } ?? keywords.count
            return l == r ? left.offset < right.offset : l < r
        }.map(\.element)
        guard !categories.isEmpty else { return nil }
        return categories[max(round, 0) % categories.count]
    }
}
