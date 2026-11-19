import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovelKit

struct SpeechProviderTests {
    private func configured(_ engine: TTSEngine) -> TTSSettings {
        var settings = TTSSettings(engine: engine)
        settings.remote.apiKey = "legacy-key"
        settings.remote.azure.apiKey = "azure-key"
        settings.remote.doubao.apiKey = "doubao-key"
        settings.remote.doubao.voice = "authorized-speaker"
        settings.remote.cosyVoice.baseURL = "http://192.168.1.10:8880/v1"
        return settings
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func oldSettingsDecodeWithoutLosingExistingVoiceOrKey() throws {
        let old = Data(#"{"edgeVoice":"zh-CN-YunxiNeural","apiKey":"old","baseURL":"https://custom.test/v1","model":"model"}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteTTSSettings.self, from: old)
        #expect(decoded.apiKey == "old")
        #expect(decoded.edgeVoice == "zh-CN-YunxiNeural")
        #expect(decoded.azure.region == "eastasia")
        #expect(decoded.doubao.resourceID == "seed-tts-2.0")
        #expect(decoded.cosyVoice.voice == "default")
        #expect(TTSSettings().engine == .edge)
    }

    @Test func azureUsesResourceKeyRegionalSSMLAndMP3() throws {
        var settings = configured(.azure)
        settings.rate = 0.75
        let request = try ProviderSpeechClient.request(text: "你 & 我 <他说>", settings: settings)
        #expect(request.url?.absoluteString == "https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "azure-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat") == "audio-24khz-48kbitrate-mono-mp3")
        let xml = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(xml.contains("你 &amp; 我 &lt;他说&gt;"))
        #expect(xml.contains("rate='+50%'"))
        #expect(xml.contains("zh-CN-XiaoxiaoNeural"))
        settings.remote.azure.region = "evil.test/path"
        #expect(!settings.isRemoteUsable)
        #expect(throws: ProviderSpeechError.self) { try ProviderSpeechClient.request(text: "text", settings: settings) }
    }

    @Test func doubaoUsesItsOwnKeyResourceAndSpeed() throws {
        var settings = configured(.doubao)
        settings.rate = 0.25
        let request = try ProviderSpeechClient.request(text: "你好", settings: settings)
        #expect(request.url?.path == "/api/v3/tts/unidirectional/sse")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "doubao-key")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "seed-tts-2.0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let params = try #require(try json(request)["req_params"] as? [String: Any])
        #expect(params["speaker"] as? String == "authorized-speaker")
        let audio = try #require(params["audio_params"] as? [String: Any])
        #expect(audio["speech_rate"] as? Int == -50)
        #expect(audio["format"] as? String == "mp3")
    }

    @Test func cosyUsesWAVAndDoesNotLeakAnotherProvidersKey() throws {
        let settings = configured(.cosyVoice)
        let request = try ProviderSpeechClient.request(text: "你好", settings: settings)
        #expect(request.url?.absoluteString == "http://192.168.1.10:8880/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try json(request)["response_format"] as? String == "wav")
        #expect(try json(request)["voice"] as? String == "default")
        #expect(try json(request)["speed"] as? Double == 1)
    }

    @Test func streamsRequireSuccessAndPreserveAudioOrder() throws {
        let stream = "event: 352\r\ndata: {\"code\":0,\"data\":\"SUQz\"}\r\n\r\ndata: {\"code\":0,\"sentence\":{},\"data\":null}\n\ndata: {\"code\":0,\"data\":\"YWJj\"}\n\ndata: {\"code\":20000000,\"data\":null}\n"
        let audio = try ProviderSpeechClient.doubaoAudio(Data(stream.utf8))
        #expect(audio == Data("ID3abc".utf8))
        try ProviderSpeechClient.validateAudio(audio)
        for invalid in ["data: {\"code\":0,\"data\":\"SUQz\"}\n",
                        "data: {\"code\":45000000}\n", "data: {\"code\":20000000}\n",
                        "data: {\"code\":0,\"data\":\"bad!\"}\n", "data: not-json\n"] {
            #expect(throws: (any Error).self) { try ProviderSpeechClient.doubaoAudio(Data(invalid.utf8)) }
        }
        #expect(throws: ProviderSpeechError.self) {
            try ProviderSpeechClient.doubaoAudio(Data("\(stream)data: {\"code\":55000000}\n".utf8))
        }
    }

    @Test func invalidCredentialsStopRetryingButRateLimitsCanRecover() {
        #expect(SpeechRetryRules.isPermanent(ProviderSpeechError.configuration))
        #expect(SpeechRetryRules.isPermanent(ProviderSpeechError.http(401)))
        #expect(SpeechRetryRules.isPermanent(ProviderSpeechError.service(45000000)))
        #expect(!SpeechRetryRules.isPermanent(ProviderSpeechError.http(429)))
        #expect(!SpeechRetryRules.isPermanent(ProviderSpeechError.http(503)))
        #expect(!SpeechRetryRules.isPermanent(ProviderSpeechError.incomplete))
    }

    @Test func audioValidationRejectsHTTP200JSONAndHTML() {
        for text in ["", "<html>error</html>", "{\"error\":\"invalid key\"}"] {
            #expect(throws: ProviderSpeechError.self) { try ProviderSpeechClient.validateAudio(Data(text.utf8)) }
        }
    }

    @Test func allProviderSecretsAreStrippedFromPersistence() throws {
        var app = AppSettings()
        app.tts = configured(.azure)
        app.tts.remote.cosyVoice.apiKey = "cosy-key"
        let stripped = app.strippingSecrets
        #expect(stripped.tts.remote.azure.apiKey.isEmpty)
        #expect(stripped.tts.remote.doubao.apiKey.isEmpty)
        #expect(stripped.tts.remote.cosyVoice.apiKey.isEmpty)
        #expect(stripped.tts.remote.apiKey.isEmpty)
        #expect(stripped.tts.remote.azure.region == "eastasia")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(stripped))
        #expect(decoded.tts.remote.cosyVoice.baseURL == app.tts.remote.cosyVoice.baseURL)
    }

    @Test func cacheSeparatesRegionResourceAndEndpointButNotSecrets() {
        var settings = configured(.azure)
        let original = settings.providerVoiceIdentity
        settings.remote.azure.apiKey = "rotated-key"
        #expect(settings.providerVoiceIdentity == original)
        settings.remote.azure.region = "westus"
        #expect(settings.providerVoiceIdentity != original)
        settings = configured(.doubao)
        let doubao = settings.providerVoiceIdentity
        settings.remote.doubao.resourceID = "seed-tts-1.0"
        #expect(settings.providerVoiceIdentity != doubao)
        settings = configured(.cosyVoice)
        let cosy = settings.providerVoiceIdentity
        settings.remote.cosyVoice.baseURL = "http://other:8880/v1"
        #expect(settings.providerVoiceIdentity != cosy)
    }
}
