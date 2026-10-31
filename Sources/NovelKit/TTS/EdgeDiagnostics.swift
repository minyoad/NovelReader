import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One line of the TTS reachability report.
public struct EdgeDiagnosticStep: Sendable, Identifiable, Equatable {
    public enum Level: String, Sendable {
        /// Worked.
        case pass
        /// Did not work; the detail explains why.
        case fail
        /// Not applicable / skipped.
        case info
    }

    public var id: String
    public var title: String
    public var detail: String
    public var level: Level

    public init(id: String, title: String, detail: String, level: Level) {
        self.id = id
        self.title = title
        self.detail = detail
        self.level = level
    }
}

/// Checks, from the device, whether the Edge read-aloud service can be reached.
///
/// Exists because a "TLS error" can come from three unrelated layers — DNS, the
/// TLS handshake, or the WebSocket upgrade — and they need different fixes. The
/// report separates them so a failure on a phone can be diagnosed without
/// attaching a debugger, which a sideloaded build makes impractical.
public enum EdgeDiagnostics {

    public static func run(proxy: String = "") async -> [EdgeDiagnosticStep] {
        var steps: [EdgeDiagnosticStep] = []

        // Start from the default order: the report is meant to describe the
        // network as it is now, not to replay whatever the last utterance
        // happened to learn.
        EdgeTTSClient.resetEndpointPreference()

        if !proxy.isEmpty, SpeechProxy(proxy) == nil {
            steps.append(
                EdgeDiagnosticStep(
                    id: "proxy-syntax",
                    title: "代理地址",
                    detail: "看不懂「\(proxy)」。请填 host:port，例如 192.168.1.5:7890。",
                    level: .fail
                )
            )
        }

        for endpoint in EdgeTTSClient.Endpoint.all {
            steps.append(await httpsStep(for: endpoint, proxy: proxy))
        }
        for endpoint in EdgeTTSClient.Endpoint.all {
            steps.append(await websocketStep(for: endpoint, proxy: proxy))
        }

        return steps
    }

    /// A plain HTTPS request to the same host.
    ///
    /// If this fails the same way the socket does, the block is at the network
    /// or TLS layer and no amount of protocol fixing will help. If it succeeds,
    /// the problem is specific to the WebSocket upgrade.
    private static func httpsStep(for endpoint: EdgeTTSClient.Endpoint, proxy: String) async -> EdgeDiagnosticStep {
        let id = "https-\(endpoint.host)"
        guard let url = URL(string: "https://\(endpoint.host)/") else {
            return EdgeDiagnosticStep(id: id, title: "HTTPS \(endpoint.host)",
                                      detail: "地址无效", level: .fail)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpMethod = "GET"

        do {
            let (_, response) = try await SpeechSession.make(proxy: proxy).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Any HTTP status means TLS completed and request/response worked;
            // even a 400 from the bare host root is a successful round trip.
            return EdgeDiagnosticStep(
                id: id,
                title: "HTTPS \(endpoint.host)",
                detail: "可访问（HTTP \(status)）",
                level: .pass
            )
        } catch {
            let code = (error as? URLError)?.errorCode
            return EdgeDiagnosticStep(
                id: id,
                title: "HTTPS \(endpoint.host)",
                detail: EdgeTTSError.transportReason(code: code),
                level: .fail
            )
        }
    }

    /// A full synthesize against one endpoint, so the report also proves the
    /// token and protocol are accepted — not just that the port is open.
    private static func websocketStep(for endpoint: EdgeTTSClient.Endpoint, proxy: String) async -> EdgeDiagnosticStep {
        let id = "wss-\(endpoint.host)"
        do {
            let speech = try await EdgeTTSClient().synthesize(
                text: "连接测试。",
                voice: "zh-CN-YunxiNeural",
                rate: 0.5,
                pitch: 1.0,
                volume: 1.0,
                endpoint: endpoint,
                proxy: proxy
            )
            return EdgeDiagnosticStep(
                id: id,
                title: "朗读 \(endpoint.host)",
                detail: "成功，收到 \(speech.audio.count) 字节音频、\(speech.boundaries.count) 条时间戳",
                level: .pass
            )
        } catch let error as EdgeTTSError {
            let detail: String
            switch error {
            case .transport(_, let code):
                detail = EdgeTTSError.transportReason(code: code)
            default:
                detail = error.errorDescription ?? "未知错误"
            }
            return EdgeDiagnosticStep(id: id, title: "朗读 \(endpoint.host)", detail: detail, level: .fail)
        } catch {
            return EdgeDiagnosticStep(
                id: id,
                title: "朗读 \(endpoint.host)",
                detail: error.localizedDescription,
                level: .fail
            )
        }
    }
}
