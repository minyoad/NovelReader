import Foundation

/// Decides how much of a book source a failed discover page takes down with it.
///
/// Filtering sources that cannot open is only useful if it does not also throw
/// away sources that can. The difference is in the error: one section address
/// going stale answers 404 and leaves the other tabs alone, while a host that
/// does not resolve, a 5xx, or a list rule that matches nothing fails every tab
/// of that source in exactly the same way.
public enum ExploreFailure {
    /// Whether the failure makes the whole source useless, not just one tab.
    public static func failsWholeSource(_ error: Error) -> Bool {
        if let http = error as? HTTPError {
            switch http {
            case .badStatus(let code, _):
                // Only a missing address is specific to one category; 403 and
                // 5xx come from the site as a whole.
                return code != 404 && code != 410
            case .badURL:
                // A broken address is the category's own problem.
                return false
            case .transport, .invalidResponse, .emptyBody:
                return true
            }
        }

        if let source = error as? SourceError {
            switch source {
            case .noResults, .unsupported:
                // The page loaded but nothing matched its selector, or the
                // rules are not something this reader can run. Both are
                // properties of the source, not of one address.
                return true
            case .notFound, .emptyContent:
                return false
            }
        }

        // Unknown failures are treated as local: a wrong guess costs one tab,
        // while hiding a working source costs the reader the whole source.
        return false
    }
}
