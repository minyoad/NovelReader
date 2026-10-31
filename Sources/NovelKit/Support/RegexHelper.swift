import Foundation

/// Thin convenience wrapper around `NSRegularExpression` with a small cache,
/// since the rule engine compiles a lot of patterns.
public enum RegexHelper {
    private final class Cache {
        private var storage: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
            let key = "\(options.rawValue)|\(pattern)"
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[key] { return cached }
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            storage[key] = compiled
            return compiled
        }
    }

    private static let cache = Cache()

    public static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        cache.regex(pattern, options: options)
    }

    public static func firstMatch(_ pattern: String, in text: String, group: Int = 0, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = regex(pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard group < match.numberOfRanges else { return nil }
        guard let matchRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[matchRange])
    }

    public static func allMatches(_ pattern: String, in text: String, group: Int = 0, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = regex(pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard group < match.numberOfRanges, let matchRange = Range(match.range(at: group), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    public static func replace(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = regex(pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    public static func isMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = regex(pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
