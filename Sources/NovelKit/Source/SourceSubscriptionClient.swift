import Foundation

/// Fetches a subscription URL and turns it into sources.
///
/// Small enough to stay a plain function of the HTTP client: it knows the
/// legado conventions (bare array, `data` wrapper, a page that links to the
/// list) and nothing about the device. Applying the result is
/// `SourceSubscriptionSync`'s job; keeping the two apart is what lets the
/// deletion rules be tested offline.
public struct SourceSubscriptionClient: Sendable {
    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    /// The sources a subscription lists right now.
    ///
    /// A subscription that saved a shape (`sourceListKey`) is asked for that
    /// shape first: a collection site that once served `{"books": [...]}`
    /// should not be re-guessed every time.
    public func fetch(_ subscription: SourceSubscription, followLimit: Int = 2) async throws -> [BookSource] {
        guard let url = URL(string: subscription.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            throw SubscriptionError.badURL(subscription.url)
        }

        var target = url
        var nextKey = subscription.sourceListKey
        var hops = 0

        while true {
            let page = try await client.fetch(HTTPRequest(url: target.absoluteString), retries: 1)
            guard (200..<300).contains(page.statusCode) else {
                throw SubscriptionError.http(page.statusCode)
            }

            let found: SubscriptionParser.Found
            if let key = nextKey {
                found = try SubscriptionParser.parse(page.data, expectingKey: key)
            } else {
                found = try SubscriptionParser.parse(page.data)
            }

            if let next = found.followUp {
                hops += 1
                guard hops <= followLimit else {
                    throw SubscriptionError.noSources
                }
                target = next
                nextKey = found.followUpKey
                continue
            }
            return found.sources
        }
    }
}
