import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public var url: String
    public var method: Method
    public var headers: [String: String]
    public var body: Data?
    /// Charset override coming from the source / URL options.
    public var charset: String?

    public init(
        url: String,
        method: Method = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        charset: String? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.charset = charset
    }

    /// Convenience for legado style form bodies: `key=value&key2=value2`.
    public static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = pairs.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

public struct FetchedPage: Sendable {
    public var finalURL: URL
    public var text: String
    public var data: Data
    public var statusCode: Int
    public var contentType: String?

    public init(finalURL: URL, text: String, data: Data, statusCode: Int, contentType: String?) {
        self.finalURL = finalURL
        self.text = text
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
    }

    public var json: JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public enum HTTPError: LocalizedError {
    case badURL(String)
    case invalidResponse
    case badStatus(Int, String)
    case emptyBody(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url): return "无效的链接：\(url)"
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case .badStatus(let code, let url): return "HTTP \(code)：\(url)"
        case .emptyBody(let url): return "内容为空：\(url)"
        case .transport(let message): return message
        }
    }
}

/// Small async HTTP client tuned for scraping: shared cookie jar, per-source
/// headers, charset aware decoding and a couple of retries for flaky hosts.
public final class HTTPClient: @unchecked Sendable {
    public var settings: NetworkSettings

    private let session: URLSession
    private let lock = NSLock()

    public init(settings: NetworkSettings = NetworkSettings()) {
        self.settings = settings

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = settings.timeout
        configuration.timeoutIntervalForResource = max(settings.timeout, 45)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = settings.useCookies
        configuration.httpCookieStorage = settings.useCookies ? HTTPCookieStorage.shared : nil
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9"]
        self.session = URLSession(configuration: configuration)
    }

    public func update(settings: NetworkSettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    public func fetch(_ request: HTTPRequest, referer: String? = nil, retries: Int = 2) async throws -> FetchedPage {
        var lastError: Error = HTTPError.invalidResponse

        for attempt in 0...retries {
            do {
                return try await perform(request, referer: referer)
            } catch {
                lastError = error
                if let httpError = error as? HTTPError {
                    switch httpError {
                    case .badStatus(let code, _) where (400..<500).contains(code) && code != 429:
                        throw error // no point retrying client errors
                    case .badURL:
                        throw error
                    default:
                        break
                    }
                }
                if attempt < retries {
                    let delay = UInt64(300 * (attempt + 1)) * 1_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError
    }

    private func perform(_ request: HTTPRequest, referer: String?) async throws -> FetchedPage {
        guard let url = URL(string: request.url) else {
            throw HTTPError.badURL(request.url)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        if let referer, !referer.isEmpty {
            urlRequest.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if request.method == .post {
            urlRequest.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw HTTPError.badStatus(httpResponse.statusCode, request.url)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        let text = TextDecoding.decode(data, contentType: contentType, declaredCharset: request.charset)

        guard !text.isEmpty else {
            throw HTTPError.emptyBody(request.url)
        }

        return FetchedPage(
            finalURL: httpResponse.url ?? url,
            text: text,
            data: data,
            statusCode: httpResponse.statusCode,
            contentType: contentType
        )
    }
}
