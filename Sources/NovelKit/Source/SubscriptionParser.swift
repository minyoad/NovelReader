import Foundation

/// Pulls the source list out of what a subscription URL actually serves.
///
/// The legado convention is a bare JSON array of `bookSourceName` records, and
/// that is what the importer already handles. But subscription URLs in the
/// wild are links to collection sites as well as files, and a site addresses
/// its data with `links: [{url: ...}]` or wraps it under a name that means
/// nothing to `LegadoImporter` ("books", "result"). This unwraps those one at
/// a time so a subscription to a collection page works, while still refusing
/// anything that does not contain sources at all.
///
/// Deliberately shallow: it follows `data` by name, any array whose members
/// look like sources, and any `url` a wrapper points at *only* when the caller
/// asks for it. Guessing deeper than that turns a wrong URL into a slow crawl
/// of the wrong site.
public enum SubscriptionParser {

    /// Where sources were found inside a document.
    public enum Location: Hashable, Sendable {
        /// The document itself is the array (legado's usual shape).
        case root
        /// A key whose value is the array, e.g. `data` or `books`.
        case key(String)
        /// A wrapper gave the link to the real list, still to be fetched.
        /// - Parameter key: the same key on the follow-up document.
        case link(String, url: String, key: String?)
    }

    public struct Found: Sendable {
        /// Parsed sources when the document contained them.
        public var sources: [BookSource]
        /// Set when the caller must fetch another document first.
        public var followUp: URL?
        /// Which key on the follow-up holds the sources.
        public var followUpKey: String?
        /// Where they were found, so a refresh can remember the shape.
        public var location: Location

        public init(
            sources: [BookSource] = [],
            followUp: URL? = nil,
            followUpKey: String? = nil,
            location: Location
        ) {
            self.sources = sources
            self.followUp = followUp
            self.followUpKey = followUpKey
            self.location = location
        }
    }

    /// Keys tried before falling back to "the first array that looks right".
    ///
    /// Ordered by how common they are in legado-adjacent exports; `data` is
    /// last because it is also the generic wrapper every API uses, and an
    /// object with both `data` and an error field should read the error.
    static let preferredKeys = ["bookSources", "sources", "books", "list", "result", "items", "data"]

    /// Keys a wrapper uses to point at the real list.
    static let linkKeys = ["url", "link", "downloadUrl", "fileUrl"]

    public static func parse(_ data: Data) throws -> Found {
        let decoder = JSONDecoder()
        let value: JSONValue
        do {
            value = try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw SubscriptionError.notJSON
        }

        switch value {
        case .array(let items):
            let sources = items.compactMap(\.objectValue).filter(looksLikeSource)
            guard !sources.isEmpty else { throw SubscriptionError.noSources }
            let imported = try LegadoImporter.importSources(from: data)
            return Found(sources: imported.sources, location: .root)

        case .object(let object):
            // A named key first, in the order above.
            for key in preferredKeys {
                guard let array = object[key]?.arrayValue else { continue }
                guard array.contains(where: { $0.objectValue.map(looksLikeSource) ?? false }) else { continue }
                return try importArray(array, key: key)
            }

            // Then any key at all, so an unknown wrapper name still works.
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                guard let array = child.arrayValue,
                      array.contains(where: { $0.objectValue.map(looksLikeSource) ?? false }) else { continue }
                return try importArray(array, key: key)
            }

            // Finally a link to the real list, e.g. a collection site's
            // `{ "links": [{ "url": "...", ... }] }`.
            if let link = findLink(in: object) {
                return link
            }

            throw SubscriptionError.noSources

        default:
            throw SubscriptionError.noSources
        }
    }

    /// Parses a follow-up document that is expected to hold its list under
    /// `key`, falling back to the normal search when it does not.
    ///
    /// The fallback matters because sites re-shape their pages: a remembered
    /// `books` key that has since become `data` should refresh, not fail
    /// forever on a stale shape.
    public static func parse(_ data: Data, expectingKey key: String) throws -> Found {
        let decoder = JSONDecoder()
        guard let value = try? decoder.decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            return try parse(data)
        }
        if let array = object[key]?.arrayValue,
           array.contains(where: { $0.objectValue.map(looksLikeSource) ?? false }) {
            return try importArray(array, key: key)
        }
        return try parse(data)
    }

    private static func importArray(_ array: [JSONValue], key: String) throws -> Found {
        let data = try JSONEncoder().encode(JSONValue.array(array))
        let imported = try LegadoImporter.importSources(from: data)
        guard !imported.sources.isEmpty else { throw SubscriptionError.noSources }
        return Found(sources: imported.sources, location: .key(key))
    }

    /// A wrapper object holding a URL to the real list.
    ///
    /// Only arrays of wrapper objects and a top-level `url` are considered, and
    /// only if the site looks like a source host — a random page with a `url`
    /// field must not turn into a download.
    private static func findLink(in object: [String: JSONValue]) -> Found? {
        var candidates: [(String, String)] = []

        for key in linkKeys {
            if let url = object[key]?.stringValue, isHTTP(url) {
                candidates.append((key, url))
            }
        }

        for (_, child) in object.sorted(by: { $0.key < $1.key }) {
            guard let array = child.arrayValue else { continue }
            for item in array {
                guard let wrapper = item.objectValue else { continue }
                for key in linkKeys {
                    if let url = wrapper[key]?.stringValue, isHTTP(url) {
                        candidates.append((key, url))
                    }
                }
            }
        }

        guard let (key, url) = candidates.first,
              let parsed = URL(string: url) else { return nil }
        // The list itself is expected under the same wrapper key on the
        // followed document when it names one; `data` otherwise.
        return Found(followUp: parsed, followUpKey: key, location: .link(key, url: url, key: key))
    }

    private static func isHTTP(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    /// Whether an object is a legado book source rather than metadata.
    static func looksLikeSource(_ object: [String: JSONValue]) -> Bool {
        let hasName = object["bookSourceName"] != nil || object["name"] != nil
        let hasURL = object["bookSourceUrl"] != nil || object["url"] != nil
        return hasName && hasURL
    }
}

public enum SubscriptionError: LocalizedError {
    case notJSON
    case noSources
    case badURL(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notJSON:
            return "这个链接返回的不是 JSON"
        case .noSources:
            return "没在返回内容里找到书源。链接要指向 legado 书源数组，或者一个给出了书源地址的合集页。"
        case .badURL(let text):
            return "书源订阅地址无效：\(text)"
        case .http(let code):
            return "服务器返回 HTTP \(code)"
        }
    }
}
