import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the synced state lives.
public enum SyncBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case webdav
    case s3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .webdav: return "WebDAV"
        case .s3: return "S3 / 兼容存储"
        }
    }

    public var detail: String {
        switch self {
        case .webdav: return "坚果云、Nextcloud、Alist、群晖等，填服务器地址和账号"
        case .s3: return "AWS S3、MinIO、Cloudflare R2、Backblaze B2 等，填接入点和密钥"
        }
    }
}

public enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case badURL(String)
    case unauthorized
    case notFound
    case server(Int, String)
    case transport(String)
    case unsupportedVersion(Int)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有配置同步，请到「设置 → 同步」填写"
        case .badURL(let url): return "同步地址无效：\(url)"
        case .unauthorized: return "认证失败：账号、密码或密钥不对，也可能是没有权限"
        case .notFound: return "同步地址不存在，请检查目录或存储桶名"
        case .server(let code, let message): return "同步服务返回 HTTP \(code)：\(message)"
        case .transport(let message): return "网络错误：\(message)"
        case .unsupportedVersion(let version):
            return "云端文件来自更新版本的 App（格式 \(version)），请先把 App 升级到最新版"
        case .decoding(let message): return "云端文件无法解析：\(message)"
        }
    }
}

/// WebDAV and S3 share the same operations, so they share a protocol.
public protocol SyncTransport: Sendable {
    /// Returns nil when the file does not exist yet (first ever sync).
    func read() async throws -> Data?
    func write(_ data: Data) async throws
}

// MARK: - WebDAV

/// Plain WebDAV: `PUT` to write, `GET` to read.
///
/// Most providers (坚果云, Nextcloud, Alist, 群晖) speak exactly this. Basic
/// auth over HTTPS is what they expect; anything more elaborate would exclude
/// the common ones.
public struct WebDAVTransport: SyncTransport {
    public var configuration: WebDAVConfiguration
    private let session: URLSession

    public init(configuration: WebDAVConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout + 20
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func read() async throws -> Data? {
        let url = try fileURL()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(to: &request)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("没有收到响应")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 404: return nil
        case 401, 403: throw SyncError.unauthorized
        default:
            throw SyncError.server(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
    }

    public func write(_ data: Data) async throws {
        // Some servers refuse a PUT into a directory that does not exist, so
        // create it first. A failure here is not fatal on servers that create
        // the parent implicitly.
        try? await makeDirectory()
        var request = URLRequest(url: try fileURL())
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(to: &request)
        let (body, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("没有收到响应")
        }
        switch http.statusCode {
        case 200, 201, 204: return
        case 401, 403: throw SyncError.unauthorized
        default:
            throw SyncError.server(http.statusCode, String(data: body, encoding: .utf8)?.prefix(200).description ?? "")
        }
    }

    /// `MKCOL` on the parent directory. 405 means "already exists", which is
    /// success for our purposes.
    private func makeDirectory() async throws {
        var request = URLRequest(url: try parentURL())
        request.httpMethod = "MKCOL"
        addAuth(to: &request)
        _ = try? await send(request)
    }

    private func fileURL() throws -> URL {
        guard let base = URL(string: configuration.directoryURL) else {
            throw SyncError.badURL(configuration.directoryURL)
        }
        return base.appendingPathComponent(configuration.fileName)
    }

    private func parentURL() throws -> URL {
        try fileURL().deletingLastPathComponent()
    }

    private func addAuth(to request: inout URLRequest) {
        guard !configuration.username.isEmpty else { return }
        let raw = "\(configuration.username):\(configuration.password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SyncError.transport(error.localizedDescription)
        }
    }
}

// MARK: - S3

/// S3-compatible object storage, signed with Signature V4.
///
/// Works with AWS S3, MinIO, Cloudflare R2, Backblaze B2 and anything else that
/// speaks the S3 API — which is why only path-style addressing and header
/// signing are implemented. Presigned URLs, multipart uploads and bucket
/// management are not needed for a single small JSON file.
public struct S3Transport: SyncTransport {
    public var configuration: S3Configuration
    private let session: URLSession

    public init(configuration: S3Configuration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout + 20
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func read() async throws -> Data? {
        let request = try signed(method: "GET", body: Data())
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("没有收到响应")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 404: return nil
        case 401, 403: throw SyncError.unauthorized
        default:
            throw SyncError.server(http.statusCode, Self.errorText(data))
        }
    }

    public func write(_ data: Data) async throws {
        let request = try signed(method: "PUT", body: data)
        let (body, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("没有收到响应")
        }
        switch http.statusCode {
        case 200, 201, 204: return
        case 401, 403: throw SyncError.unauthorized
        default:
            throw SyncError.server(http.statusCode, Self.errorText(body))
        }
    }

    private static func errorText(_ data: Data) -> String {
        // S3 reports failures as XML; showing the whole document would bury
        // the one line that matters.
        let text = String(data: data, encoding: .utf8) ?? ""
        if let range = text.range(of: "<Message>") {
            let rest = text[range.upperBound...]
            if let end = rest.range(of: "</Message>") {
                return String(rest[..<end.lowerBound]).prefix(200).description
            }
        }
        return text.prefix(200).description
    }

    /// The header carrying the payload hash. AWS calls it
    /// `x-amz-content-sha256`; signing it is what stops a proxy from swapping
    /// the body.
    static let payloadHashHeader = "x-amz-content-sha256"

    private func objectURL() throws -> URL {
        guard let endpoint = URL(string: configuration.endpoint) else {
            throw SyncError.badURL(configuration.endpoint)
        }
        // Path style: `https://endpoint/bucket/key`. R2 and MinIO require it;
        // AWS accepts it too and it avoids per-bucket DNS rules.
        var url = endpoint
        for component in [configuration.bucket, configuration.keyPath] where !component.isEmpty {
            url.appendPathComponent(component)
        }
        return url
    }

    private func signed(method: String, body: Data) throws -> URLRequest {
        let url = try objectURL()
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)
        let payloadHash = Self.sha256Hex(body)

        var headers: [String: String] = [
            "host": url.host ?? "",
            S3Transport.payloadHashHeader: payloadHash,
            "x-amz-date": amzDate,
        ]
        // R2 in some regions needs no session token; when present it must be
        // signed like any other header.
        if !configuration.sessionToken.isEmpty {
            headers["x-amz-security-token"] = configuration.sessionToken
        }

        let canonicalQuery = Self.canonicalQuery(url)
        let canonicalHeaders = headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
        let signedHeaders = headers.keys
            .map { $0.lowercased() }
            .sorted()
            .joined(separator: ";")

        let canonicalRequest = [
            method,
            Self.canonicalPath(url),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(configuration.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(
            secret: configuration.secretKey,
            dateStamp: dateStamp,
            region: configuration.region
        )
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers where key != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(configuration.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        if method == "PUT" {
            // Not signed, but S3 stores it and clients use it to pick a parser.
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SyncError.transport(error.localizedDescription)
        }
    }

    // MARK: Signing primitives

    static func canonicalPath(_ url: URL) -> String {
        // SigV4 requires each segment percent-encoded and the path not
        // normalised away; building it from the raw path keeps that true.
        let path = url.path.isEmpty ? "/" : url.path
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.percentEncode(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return "" }
        var pairs: [(String, String)] = []
        for item in items {
            pairs.append((percentEncode(item.name), percentEncode(item.value ?? "")))
        }
        pairs.sort { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters only.
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func signingKey(secret: String, dateStamp: String, region: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data("s3".utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Hashing

// SHA-256 and HMAC are implemented here rather than pulled from a dependency:
// the package has no external packages, and CryptoKit is not available on
// Linux, where the engine is tested.

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> Data {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < message.count {
            for index in 0..<16 {
                let base = offset + index * 4
                w[index] = UInt32(message[base]) << 24
                    | UInt32(message[base + 1]) << 16
                    | UInt32(message[base + 2]) << 8
                    | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotr(w[index - 15], 7) ^ rotr(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotr(w[index - 2], 17) ^ rotr(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for index in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[index] &+ w[index]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
            offset += 64
        }

        var output = Data()
        for word in h {
            output.append(UInt8((word >> 24) & 0xff))
            output.append(UInt8((word >> 16) & 0xff))
            output.append(UInt8((word >> 8) & 0xff))
            output.append(UInt8(word & 0xff))
        }
        return output
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

extension S3Transport {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        let blockSize = 64
        var normalized = [UInt8](key)
        if normalized.count > blockSize {
            normalized = [UInt8](SHA256.hash(key))
        }
        if normalized.count < blockSize {
            normalized.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalized.count))
        }
        var outer = [UInt8](repeating: 0x5c, count: blockSize)
        var inner = [UInt8](repeating: 0x36, count: blockSize)
        for index in 0..<blockSize {
            outer[index] ^= normalized[index]
            inner[index] ^= normalized[index]
        }
        inner.append(contentsOf: data)
        let innerHash = SHA256.hash(Data(inner))
        outer.append(contentsOf: innerHash)
        return SHA256.hash(Data(outer))
    }

    static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }
}
