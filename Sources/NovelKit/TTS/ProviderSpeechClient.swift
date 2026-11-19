import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderSpeechError: LocalizedError {
    case configuration, http(Int), service(Int), invalidAudio, incomplete
    public var errorDescription: String? {
        switch self {
        case .configuration: return "朗读服务配置不完整，请检查区域、密钥、音色或网关地址。"
        case .http(let status): return "语音服务返回 HTTP \(status)，请检查密钥、服务权限、额度和网络。"
        case .service(let code): return "豆包语音返回错误 \(code)，请检查语音 API Key、资源 ID、音色权限和额度。"
        case .invalidAudio: return "语音接口未返回可播放的 MP3/WAV 音频。"
        case .incomplete: return "语音返回不完整，已放弃本次音频，请重试。"
        }
    }
}

public struct ProviderSpeechClient: Sendable {
    public init() {}
    public func synthesize(text: String, settings: TTSSettings) async throws -> Data {
        let request = try Self.request(text: text, settings: settings)
        let session = SpeechSession.make(proxy: settings.proxy)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ProviderSpeechError.invalidAudio }
        guard (200...299).contains(response.statusCode) else { throw ProviderSpeechError.http(response.statusCode) }
        guard data.count <= 64 * 1024 * 1024 else { throw ProviderSpeechError.invalidAudio }
        let audio = settings.engine == .doubao ? try Self.doubaoAudio(data) : data
        try Self.validateAudio(audio)
        return audio
    }

    static func request(text: String, settings: TTSSettings) throws -> URLRequest {
        guard settings.isRemoteUsable else { throw ProviderSpeechError.configuration }
        var request: URLRequest
        switch settings.engine {
        case .azure:
            let service = settings.remote.azure
            let url = URL(string: "https://\(service.region).tts.speech.microsoft.com/cognitiveservices/v1")!
            request = URLRequest(url: url)
            request.setValue(service.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
            request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
            request.setValue("NovelReader", forHTTPHeaderField: "User-Agent")
            request.httpBody = Data(EdgeTTSClient.ssml(text: text, voice: service.voice, rate: settings.rate,
                                                      pitch: settings.pitch, volume: settings.volume).utf8)
        case .doubao:
            let service = settings.remote.doubao
            request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse")!)
            request.setValue(service.apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(service.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "user": ["uid": "novelreader"],
                "req_params": ["text": text, "speaker": service.voice,
                               "audio_params": ["format": "mp3", "sample_rate": 24000,
                                                "speech_rate": max(-50, min(100, Int(((settings.rate / 0.5 - 1) * 100).rounded())))]]
            ])
        case .cosyVoice:
            let service = settings.remote.cosyVoice
            guard let url = service.speechURL else { throw ProviderSpeechError.configuration }
            request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !service.apiKey.isEmpty { request.setValue("Bearer \(service.apiKey)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": service.model, "input": text, "voice": service.voice,
                "response_format": "wav", "speed": max(0.5, min(2, settings.rate / 0.5))
            ])
        default: throw ProviderSpeechError.configuration
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        return request
    }

    static func doubaoAudio(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw ProviderSpeechError.invalidAudio }
        var audio = Data()
        var finished = false
        var sawFrame = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            sawFrame = true
            guard !finished,
                  let bytes = String(line.dropFirst(5)).data(using: .utf8),
                  let frame = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let code = frame["code"] as? Int else { throw ProviderSpeechError.invalidAudio }
            guard code == 0 || code == 20000000 else { throw ProviderSpeechError.service(code) }
            if let base64 = frame["data"] as? String, !base64.isEmpty {
                guard let part = Data(base64Encoded: base64), audio.count + part.count <= 32 * 1024 * 1024 else {
                    throw ProviderSpeechError.invalidAudio
                }
                audio.append(part)
            }
            if code == 20000000 { finished = true }
        }
        guard sawFrame else { throw ProviderSpeechError.invalidAudio }
        guard finished else { throw ProviderSpeechError.incomplete }
        guard !audio.isEmpty else { throw ProviderSpeechError.invalidAudio }
        return audio
    }

    static func validateAudio(_ data: Data) throws {
        let bytes = [UInt8](data.prefix(12))
        let mp3 = bytes.starts(with: [0x49, 0x44, 0x33]) || (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
        let wav = bytes.count == 12 && bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && Array(bytes[8...11]) == [0x57, 0x41, 0x56, 0x45]
        guard mp3 || wav else { throw ProviderSpeechError.invalidAudio }
    }
}
