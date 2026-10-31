import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenAISpeechError: LocalizedError {
    case invalidURL
    case missingModel
    case http(Int, String)
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "自定义朗读接口地址无效，请检查「接口地址」。"
        case .missingModel:
            return "还没有填写朗读模型名（例如 tts-1）。"
        case .http(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "朗读接口返回 \(status)\(detail.isEmpty ? "" : "：\(detail.prefix(180))")"
        case .emptyAudio:
            return "朗读接口没有返回音频。"
        }
    }
}

/// Any server that answers `POST /v1/audio/speech` the way OpenAI does.
///
/// Covers both hosted compatible services and locally hosted models, which is
/// why nothing here assumes a particular provider — only the request shape.
public struct OpenAISpeechClient: Sendable {
    public init() {}

    /// Synthesizes `text` and returns whatever audio bytes the server produced.
    ///
    /// The format is left to the server (MP3 by default); the player sniffs the
    /// container rather than trusting a file extension.
    public func synthesize(
        text: String,
        settings: RemoteTTSSettings,
        rate: Double = 1.0,
        speed: Double = 1.0
    ) async throws -> Data {
        guard let url = settings.speechURL else { throw OpenAISpeechError.invalidURL }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAISpeechError.missingModel
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60

        let body = RequestBody(
            model: settings.model,
            input: text,
            voice: settings.voice,
            response_format: "mp3",
            // OpenAI's own scale is 0.25…4.0 with 1.0 as normal; `rate` is the
            // reader's 0.5-based scale, so it has to be converted here rather
            // than in every caller.
            speed: max(0.25, min(4.0, speed * (rate / 0.5)))
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OpenAISpeechError.http(http.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
        guard !data.isEmpty else { throw OpenAISpeechError.emptyAudio }
        return data
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: String
        let voice: String
        let response_format: String
        let speed: Double
    }
}
