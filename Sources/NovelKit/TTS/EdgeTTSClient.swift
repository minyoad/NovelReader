import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EdgeTTSError: LocalizedError {
    case tokenRejected
    case noAudio
    case unexpectedFrame(String)
    case closedEarly
    /// The socket never came up. `code` is the `URLError.Code` raw value when
    /// one was available, so the message can name the actual cause instead of
    /// surfacing Foundation's English text.
    case transport(host: String, code: Int?)
    /// Every known endpoint failed. Carries the individual reasons so the
    /// reader can see whether it was one host or the whole network.
    case allEndpointsFailed([String])

    public var errorDescription: String? {
        switch self {
        case .tokenRejected:
            return "Edge 朗读拒绝了这次请求（令牌或版本已过期）。请稍后重试；若一直失败，说明接口已变更。"
        case .noAudio:
            return "Edge 朗读没有返回音频，可能是文本为空或服务临时故障。"
        case .unexpectedFrame(let detail):
            return "Edge 朗读返回了意料之外的数据：\(detail)"
        case .closedEarly:
            return "Edge 朗读连接被提前关闭。"
        case .transport(let host, let code):
            return """
            连接 Edge 朗读（\(host)）时\(Self.transportReason(code: code))
            如果两个地址都失败，先检查手机是否开着代理 / VPN 或网络受限；也可以点「朗读网络诊断」看具体是哪一层不通。\
            临时可以先切回「系统朗读」离线听。
            """
        case .allEndpointsFailed(let reasons):
            return """
            连接微软朗读服务失败，已试过全部地址：
            \(reasons.joined(separator: "\n"))

            多半是手机的网络环境问题（系统代理 / VPN / 网络限制），而不是令牌。\
            先试试关掉系统代理或 VPN，也可以在设置里点「朗读网络诊断」定位。\
            临时可以切回「系统朗读」。
            """
        }
    }

    static func transportReason(code: Int?) -> String {
        switch code.map({ URLError.Code(rawValue: $0) }) {
        case .some(.secureConnectionFailed):
            // Seen in practice with a system-wide proxy or VPN in the path:
            // it intercepts the TLS handshake to Microsoft's speech host. Worth
            // naming first, because it is the easiest thing to turn off.
            return "TLS 握手被中断。常见原因是手机开着代理 / VPN 拦截了这次连接，或者当前网络到该域名不通。"
        case .some(.serverCertificateUntrusted),
             .some(.serverCertificateHasBadDate),
             .some(.serverCertificateNotYetValid),
             .some(.serverCertificateHasUnknownRoot):
            return "证书校验失败，网络中间可能有代理或劫持。"
        case .some(.notConnectedToInternet):
            return "设备当前没有联网。"
        case .some(.timedOut):
            return "连接超时。"
        case .some(.cannotFindHost), .some(.dnsLookupFailed):
            return "无法解析域名。代理或 DNS 可能有问题。"
        case .some(.cannotConnectToHost):
            return "无法建立连接，端口可能被阻断。"
        case .some(.networkConnectionLost):
            return "连接中途断开。"
        case .some(.badServerResponse):
            return "服务端没有返回正常的 WebSocket 握手（可能被拒绝）。"
        default:
            return "网络请求失败。"
        }
    }

    /// Whether trying a different host could plausibly succeed. A rejected
    /// token or an empty result would fail the same way everywhere.
    var isRetryable: Bool {
        switch self {
        case .transport, .closedEarly, .unexpectedFrame:
            return true
        case .tokenRejected, .noAudio, .allEndpointsFailed:
            return false
        }
    }
}

/// One sentence of synthesized audio, as reported by the service.
///
/// The service emits these alongside the audio, which is what lets the reader
/// highlight the sentence being spoken instead of guessing from a byte count.
public struct EdgeSentenceBoundary: Sendable, Equatable, Codable {
    public var text: String
    /// Seconds from the start of the returned audio.
    public var start: Double
    public var duration: Double

    public init(text: String, start: Double, duration: Double) {
        self.text = text
        self.start = start
        self.duration = duration
    }
}

/// Audio plus the sentence timings that go with it.
public struct EdgeSpeech: Sendable {
    public var audio: Data
    public var boundaries: [EdgeSentenceBoundary]

    public init(audio: Data, boundaries: [EdgeSentenceBoundary]) {
        self.audio = audio
        self.boundaries = boundaries
    }
}

/// Synthesizes speech through Microsoft Edge's read-aloud service.
///
/// Implemented against the wire protocol directly rather than through a
/// dependency: there is no maintained Swift client, and the protocol is small.
/// The service is undocumented and free — see `EdgeToken` for the handshake.
///
/// One instance per request keeps this `Sendable`; the app creates a new one per
/// synthesis rather than pooling connections, because the service closes the
/// socket after each utterance anyway.
public struct EdgeTTSClient: Sendable {
    /// One reachable form of the service.
    ///
    /// Microsoft migrated the synthesis socket to `api.msedgeservices.com` and
    /// the old hostname is filtered on some networks, so both are tried. The
    /// pair is ordered deliberately: the original host is still the faster one
    /// where it works, and the new host is the fallback rather than the
    /// default, so nothing changes for users who never hit the problem.
    struct Endpoint: Sendable, Equatable {
        var host: String
        var path: String
        /// The query parameter the trusted client token is sent under. The
        /// migrated endpoint reused the same token value under a different
        /// name.
        var tokenParameter: String

        static let legacy = Endpoint(
            host: "speech.platform.bing.com",
            path: "/consumer/speech/synthesize/readaloud/edge/v1",
            tokenParameter: "TrustedClientToken"
        )
        static let current = Endpoint(
            host: "api.msedgeservices.com",
            path: "/tts/cognitiveservices/websocket/v1",
            tokenParameter: "Ocp-Apim-Subscription-Key"
        )

        static let all: [Endpoint] = [.legacy, .current]
    }

    public init() {}

    /// The endpoint that last worked, tried first afterwards.
    ///
    /// Without this, a network that filters one host would pay a failed TLS
    /// handshake on every single utterance — and a chapter is dozens of them,
    /// so reading aloud would stall for tens of seconds per sentence group.
    /// Remembered for the process lifetime only: which host works depends on
    /// the network, and an app relaunch is exactly when that may have changed.
    private static let preferenceLock = NSLock()
    nonisolated(unsafe) private static var preferredEndpoint: Endpoint?

    /// Endpoints in the order they should be tried.
    static var attemptOrder: [Endpoint] {
        preferenceLock.lock()
        defer { preferenceLock.unlock() }
        guard let preferred = preferredEndpoint, Endpoint.all.contains(preferred) else {
            return Endpoint.all
        }
        return [preferred] + Endpoint.all.filter { $0 != preferred }
    }

    static func remember(_ endpoint: Endpoint) {
        preferenceLock.lock()
        preferredEndpoint = endpoint
        preferenceLock.unlock()
    }

    /// Clears the remembered endpoint, so tests and the diagnostics screen start
    /// from the default order.
    public static func resetEndpointPreference() {
        preferenceLock.lock()
        preferredEndpoint = nil
        preferenceLock.unlock()
    }

    /// Synthesizes `text` and returns MP3 bytes plus sentence timings.
    ///
    /// `rate` and `pitch` use the model's multipliers (0.5 = normal rate,
    /// 1.0 = normal pitch) and are translated into the `+N%` / `+NHz` strings
    /// the service expects.
    ///
    /// Tries each known endpoint in turn. The first one is usually enough; the
    /// second exists because the hostnames are filtered on some networks, where
    /// the symptom is a TLS handshake failure rather than an HTTP error.
    public func synthesize(
        text: String,
        voice: String,
        rate: Double = 0.5,
        pitch: Double = 1.0,
        volume: Double = 1.0,
        proxy: String = ""
    ) async throws -> EdgeSpeech {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EdgeTTSError.noAudio }

        var failures: [String] = []
        for endpoint in Self.attemptOrder {
            do {
                let speech = try await synthesize(
                    text: trimmed,
                    voice: voice,
                    rate: rate,
                    pitch: pitch,
                    volume: volume,
                    endpoint: endpoint,
                    proxy: proxy
                )
                Self.remember(endpoint)
                return speech
            } catch let error as EdgeTTSError where error.isRetryable {
                failures.append(Self.describe(error, host: endpoint.host))
                continue
            }
        }
        throw EdgeTTSError.allEndpointsFailed(failures)
    }

    private static func describe(_ error: EdgeTTSError, host: String) -> String {
        switch error {
        case .transport(_, let code):
            return "· \(host)：\(EdgeTTSError.transportReason(code: code))"
        default:
            return "· \(host)：\(error.errorDescription ?? "未知错误")"
        }
    }

    /// One attempt against a single host.
    func synthesize(
        text: String,
        voice: String,
        rate: Double,
        pitch: Double,
        volume: Double,
        endpoint: Endpoint,
        proxy: String = ""
    ) async throws -> EdgeSpeech {
        let token = EdgeToken.generate()
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        guard let url = Self.url(connectionID: connectionID, token: token, endpoint: endpoint) else {
            throw EdgeTTSError.tokenRejected
        }

        var request = URLRequest(url: url)
        for (key, value) in Self.handshakeHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Without this the handshake can hang until the socket times out, which
        // on a filtered network looks like the app freezing.
        request.timeoutInterval = 20

        let session = SpeechSession.make(proxy: proxy)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        do {
            try await task.send(.string(Self.configurationMessage()))

            let ssml = Self.ssml(text: text, voice: voice, rate: rate, pitch: pitch, volume: volume)
            try await task.send(.string(Self.ssmlMessage(ssml: ssml, connectionID: connectionID)))

            var audio = Data()
            var boundaries: [EdgeSentenceBoundary] = []
            var receivedAudio = false

            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    // A close before `turn.end` still leaves usable audio in hand
                    // when every chunk already arrived; only fail when nothing did.
                    if receivedAudio { break }
                    throw Self.transportError(error, host: endpoint.host)
                }

                switch message {
                case .data(let data):
                    if let chunk = Self.audioPayload(fromBinary: data) {
                        audio.append(chunk)
                        receivedAudio = true
                    }
                case .string(let text):
                    guard let path = Self.path(inTextFrame: text) else { continue }
                    if path == "turn.end" {
                        guard !audio.isEmpty else { throw EdgeTTSError.noAudio }
                        return EdgeSpeech(audio: audio, boundaries: boundaries)
                    }
                    if path == "audio.metadata" {
                        boundaries.append(contentsOf: Self.boundaries(fromMetadataFrame: text))
                        continue
                    }
                    if path == "turn.start" || path == "response" { continue }
                    throw EdgeTTSError.unexpectedFrame(path)
                @unknown default:
                    continue
                }
            }

            guard !audio.isEmpty else { throw EdgeTTSError.noAudio }
            return EdgeSpeech(audio: audio, boundaries: boundaries)
        } catch let error as EdgeTTSError {
            throw error
        } catch {
            // Anything thrown here is a URL-level failure: the handshake was
            // rejected or the socket never opened. `task.send` is where a TLS
            // error surfaces, since the WebSocket upgrade happens on first use.
            throw Self.transportError(error, host: endpoint.host)
        }
    }

    // MARK: - Protocol

    static func url(connectionID: String, token: String) -> URL? {
        url(connectionID: connectionID, token: token, endpoint: .legacy)
    }

    static func url(connectionID: String, token: String, endpoint: Endpoint) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = endpoint.host
        components.path = endpoint.path
        components.queryItems = [
            URLQueryItem(name: endpoint.tokenParameter, value: EdgeToken.trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionID),
            URLQueryItem(name: "Sec-MS-GEC", value: token),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: EdgeToken.version),
        ]
        return components.url
    }

    /// Wraps a Foundation networking error into something the UI can explain.
    ///
    /// TLS and DNS failures are the interesting ones here: they mean the host
    /// is unreachable from this network, not that the request was wrong, and
    /// the distinction decides whether retrying the other endpoint is worth it.
    static func transportError(_ error: Error, host: String) -> EdgeTTSError {
        let code = (error as? URLError)?.errorCode
        return .transport(host: host, code: code)
    }

    static func handshakeHeaders(now: Date = Date()) -> [String: String] {
        [
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            "Accept-Encoding": "gzip, deflate, br, zstd",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                + " (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
            // The service keys sessions to this cookie; a fresh one per
            // connection is what the reference client does.
            "Cookie": "muid=\(muid(now: now));",
        ]
    }

    static func muid(now: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16)
            .map { _ in String(format: "%02X", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    static func configurationMessage() -> String {
        let timestamp = httpDate(Date())
        return "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
            + "\r\n"
    }

    static func ssmlMessage(ssml: String, connectionID: String) -> String {
        "X-RequestId:\(connectionID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            // The service expects the timestamp with a trailing Z; the
            // reference client appends it inside the header.
            + "X-Timestamp:\(httpDate(Date()))Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
    }

    static func ssml(text: String, voice: String, rate: Double, pitch: Double, volume: Double) -> String {
        // `rate` uses the same scale as the system voice, where 0.5 is the
        // default speaking speed. The service wants a percentage offset from
        // normal, so 0.5 maps to +0% and 1.0 to +100%. Clamped because the
        // service rejects values outside its accepted prosody range outright
        // rather than saturating them.
        let ratePercent = max(-50, min(100, Int(((rate / 0.5 - 1) * 100).rounded())))
        // Pitch is a multiplier in the model but a signed offset in Hz for the
        // service; 50 Hz per unit matches how the reference client maps it.
        let pitchHz = max(-50, min(50, Int(((pitch - 1) * 50).rounded())))
        let volumePercent = max(-100, min(100, Int(((volume - 1) * 100).rounded())))

        func signed(_ value: Int, unit: String) -> String {
            "\(value >= 0 ? "+" : "")\(value)\(unit)"
        }

        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(escapeXML(voice))'>"
            + "<prosody pitch='\(signed(pitchHz, unit: "Hz"))'"
            + " rate='\(signed(ratePercent, unit: "%"))'"
            + " volume='\(signed(volumePercent, unit: "%"))'>"
            + escapeXML(text)
            + "</prosody></voice></speak>"
    }

    static func escapeXML(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        // The service rejects a handful of control characters outright rather
        // than ignoring them, so strip them up front.
        return String(result.unicodeScalars.filter { scalar in
            !(scalar.value <= 8 || (11...12).contains(scalar.value) || (14...31).contains(scalar.value))
        }.map(Character.init))
    }

    /// Parses the sentence timings out of an `audio.metadata` body.
    ///
    /// Offsets are in 100-nanosecond ticks from the start of the returned audio,
    /// which is the only way to know where a sentence begins without decoding
    /// the MP3.
    static func boundaries(fromMetadataFrame frame: String) -> [EdgeSentenceBoundary] {
        guard let separator = frame.range(of: "\r\n\r\n") else { return [] }
        let body = String(frame[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let data = body.data(using: .utf8) else { return [] }

        struct Envelope: Decodable {
            struct Entry: Decodable {
                struct Payload: Decodable {
                    struct TextPart: Decodable { let Text: String }
                    let Offset: Int64
                    let Duration: Int64
                    let text: TextPart
                }
                let type: String
                let Data: Payload?

                private enum CodingKeys: String, CodingKey {
                    case type = "Type"
                    case Data
                }
            }
            let Metadata: [Entry]
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return envelope.Metadata.compactMap { entry in
            guard entry.type == "SentenceBoundary", let payload = entry.Data else { return nil }
            return EdgeSentenceBoundary(
                text: payload.text.Text,
                start: Double(payload.Offset) / 10_000_000,
                duration: Double(payload.Duration) / 10_000_000
            )
        }
    }

    /// Text frames carry a small HTTP-like header block, then the body.
    static func path(inTextFrame frame: String) -> String? {
        header("Path", in: frame)
    }

    static func header(_ name: String, in frame: String) -> String? {
        guard let separator = frame.range(of: "\r\n\r\n") else { return nil }
        let head = frame[frame.startIndex..<separator.lowerBound]
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Binary frames start with a big-endian byte count for their header block.
    static func audioPayload(fromBinary data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let bodyStart = 2 + headerLength
        guard data.count > bodyStart else { return nil }

        let headerEnd = data.startIndex + 2 + headerLength
        let headerData = data[(data.startIndex + 2)..<headerEnd]
        let header = String(decoding: headerData, as: UTF8.self)
        guard header.contains("Path:audio") || header.contains("Path: audio") else { return nil }

        return data[data.index(data.startIndex, offsetBy: bodyStart)...]
    }

    /// RFC 1123 date, which is what the timestamp headers use.
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }
}
