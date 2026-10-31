import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An HTTP proxy for the speech engines, parsed from a user-entered URL.
///
/// Needed because the Edge service is blocked from some networks — mainland
/// China in particular resets the TLS handshake — while the rest of the reader
/// works fine. The proxy is deliberately scoped to speech: routing novel
/// fetches through it too would change how book sources see the reader.
///
/// Both `http://host:port` and bare `host:port` are accepted, because that is
/// what people tend to type.
public struct SpeechProxy: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Accept the scheme even though only plain HTTP proxies are supported;
        // a `socks5://` prefix is a common mistake and better reported as
        // "unsupported" than silently treated as a hostname.
        var scheme = "http"
        if let range = trimmed.range(of: "://") {
            scheme = String(trimmed[trimmed.startIndex..<range.lowerBound]).lowercased()
            trimmed = String(trimmed[range.upperBound...])
        }
        guard scheme == "http" || scheme == "https" else { return nil }

        // Strip any path or credentials the user pasted along with the address.
        if let slash = trimmed.firstIndex(of: "/") {
            trimmed = String(trimmed[trimmed.startIndex..<slash])
        }
        if let at = trimmed.lastIndex(of: "@") {
            trimmed = String(trimmed[trimmed.index(after: at)...])
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard let hostPart = parts.first, !hostPart.isEmpty else { return nil }
        // A default port is better than refusing: most local proxy clients use
        // 7890, and being off by a port is a dead end the user cannot see.
        let port = parts.count == 2 ? Int(parts[1]) : 7890
        guard let port, (1...65535).contains(port) else { return nil }

        self.host = String(hostPart)
        self.port = port
    }

    /// CFNetwork's proxy dictionary, which is what `URLSession` reads.
    ///
    /// The keys are the raw CF constants' names rather than the constants
    /// themselves so this compiles on Linux too, where CFNetwork is absent.
    public var dictionary: [AnyHashable: Any] {
        [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
    }

    public var displayName: String { "\(host):\(port)" }
}

/// Builds the `URLSession` used by the remote speech engines.
public enum SpeechSession {
    /// Sessions already built, keyed by the proxy string.
    ///
    /// A fresh session per utterance would drop its connection pool, so every
    /// sentence group would pay a new TLS handshake — over a proxy that is far
    /// more expensive than direct. Caching keeps the tunnel warm; the set is
    /// tiny because it only grows when the user edits the proxy field.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]

    /// A session configured for `proxy`, or the shared one when no proxy is set.
    public static func make(proxy: String) -> URLSession {
        guard let proxy = SpeechProxy(proxy) else { return .shared }

        let key = proxy.displayName
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] { return existing }

        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = proxy.dictionary
        configuration.timeoutIntervalForRequest = 30
        // Failing fast is the point: a filtered host would otherwise hold the
        // request open until the timeout, and the reader shows a spinner.
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        #endif
        let session = URLSession(configuration: configuration)
        sessions[key] = session
        return session
    }

    /// Drops cached sessions, e.g. when the proxy is cleared.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        sessions.values.forEach { $0.invalidateAndCancel() }
        sessions.removeAll()
    }
}
