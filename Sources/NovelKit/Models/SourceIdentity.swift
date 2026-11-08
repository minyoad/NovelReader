import Foundation

/// What makes two source records the same source.
///
/// Shared by the importer and the sync merge so the two cannot disagree: a
/// source the importer would recognise as a re-import must also be one the
/// merge folds, or re-importing a collection on one device and syncing would
/// leave the other device with both copies.
///
/// Name plus site, not either alone: a dozen collections ship a source called
/// 笔趣阁 for unrelated sites, and one site can have two deliberate rules under
/// different names. Together they name one site as one collection calls it.
public struct SourceIdentity: Hashable, Sendable {
    public let name: String
    public let baseURL: String

    public init(name: String, baseURL: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalized the way `LegadoImporter` normalizes on import: collections
        // leave `#🎃` and trailing slashes on the URL, and a source imported
        // before and after that cleanup has to compare equal.
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = url.firstIndex(of: "#") {
            url = String(url[..<hash])
        }
        while url.hasSuffix("/") { url.removeLast() }
        self.baseURL = url
    }

    public init(of source: BookSource) {
        self.init(name: source.name, baseURL: source.baseURL)
    }
}
