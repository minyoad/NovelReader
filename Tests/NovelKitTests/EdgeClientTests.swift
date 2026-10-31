import Foundation
import Testing
@testable import NovelKit

@Suite("Edge protocol parsing")
struct EdgeTTSClientTests {

    @Test("path is read from the header block, not the body")
    func readsPath() {
        let frame = "X-RequestId:abc\r\nContent-Type:application/json; charset=utf-8\r\nPath:audio.metadata\r\n\r\n{\"Metadata\":[]}"
        #expect(EdgeTTSClient.path(inTextFrame: frame) == "audio.metadata")
        #expect(EdgeTTSClient.path(inTextFrame: "no separator") == nil)
    }

    @Test("header lookup is case insensitive")
    func headerIsCaseInsensitive() {
        let frame = "path:turn.end\r\n\r\n"
        #expect(EdgeTTSClient.header("Path", in: frame) == "turn.end")
    }

    @Test("binary frames yield only the audio body")
    func parsesBinaryFrame() {
        let header = "X-RequestId:abc\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n"
        let headerData = Array(header.utf8)
        var data = Data([UInt8(headerData.count >> 8), UInt8(headerData.count & 0xFF)])
        data.append(contentsOf: headerData)
        data.append(contentsOf: [0xFF, 0xF3, 0x64, 0xC4])

        let payload = EdgeTTSClient.audioPayload(fromBinary: data)
        #expect(payload == Data([0xFF, 0xF3, 0x64, 0xC4]))
    }

    @Test("non-audio binary frames are ignored")
    func ignoresOtherBinaryFrames() {
        let header = "Path:unknown\r\n"
        let headerData = Array(header.utf8)
        var data = Data([UInt8(headerData.count >> 8), UInt8(headerData.count & 0xFF)])
        data.append(contentsOf: headerData)
        data.append(contentsOf: [1, 2, 3])
        #expect(EdgeTTSClient.audioPayload(fromBinary: data) == nil)
    }

    @Test("sentence boundaries are decoded into seconds")
    func decodesBoundaries() throws {
        let body = #"{"Metadata":[{"Type":"SentenceBoundary","Data":{"Offset":1000000,"Duration":17000000,"text":{"Text":"他推开石门。","Length":6,"BoundaryType":"SentenceBoundary"}}},{"Type":"WordBoundary","Data":{"Offset":0,"Duration":0,"text":{"Text":"x"}}}]}"#
        let frame = "Path:audio.metadata\r\n\r\n" + body
        let boundaries = EdgeTTSClient.boundaries(fromMetadataFrame: frame)

        #expect(boundaries.count == 1)
        #expect(boundaries[0].text == "他推开石门。")
        #expect(abs(boundaries[0].start - 0.1) < 0.0001)
        #expect(abs(boundaries[0].duration - 1.7) < 0.0001)
    }

    @Test("ssml maps the reader's scales onto the service's")
    func ssmlMapping() {
        let ssml = EdgeTTSClient.ssml(text: "你好。", voice: "zh-CN-YunxiNeural", rate: 0.5, pitch: 1.0, volume: 1.0)
        // 0.5 is the reader's "normal" speed, i.e. +0% for the service.
        #expect(ssml.contains("rate='+0%'"))
        #expect(ssml.contains("pitch='+0Hz'"))
        #expect(ssml.contains("volume='+0%'"))
        #expect(ssml.contains("<voice name='zh-CN-YunxiNeural'>"))
    }

    @Test("ssml escapes markup and drops control characters")
    func ssmlEscaping() {
        let ssml = EdgeTTSClient.ssml(text: "a<b>&'\"\u{0001}", voice: "v", rate: 0.75, pitch: 1.0, volume: 1.0)
        #expect(ssml.contains("a&lt;b&gt;&amp;&apos;&quot;"))
        #expect(!ssml.contains("\u{0001}"))
        // 0.75 on the reader scale is 50% faster than normal.
        #expect(ssml.contains("rate='+50%'"))
    }

    @Test("ssml clamping keeps prosody inside the accepted range")
    func ssmlClamping() {
        let fast = EdgeTTSClient.ssml(text: "x", voice: "v", rate: 3.0, pitch: 5.0, volume: 3.0)
        #expect(fast.contains("rate='+100%'"))
        #expect(fast.contains("pitch='+50Hz'"))
        #expect(fast.contains("volume='+100%'"))

        let slow = EdgeTTSClient.ssml(text: "x", voice: "v", rate: 0.01, pitch: 0.1, volume: 0)
        #expect(slow.contains("rate='-50%'"))
        #expect(slow.contains("pitch='-45Hz'"))
        #expect(slow.contains("volume='-100%'"))
    }

    @Test("handshake URL carries the token, version and connection id")
    func buildsHandshakeURL() throws {
        let url = try #require(EdgeTTSClient.url(connectionID: "abc123", token: "TKN-ABC"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        #expect(components.scheme == "wss")
        #expect(components.host == "speech.platform.bing.com")
        #expect(items.first { $0.name == "Sec-MS-GEC" }?.value == "TKN-ABC")
        #expect(items.first { $0.name == "Sec-MS-GEC-Version" }?.value == EdgeToken.version)
        #expect(items.first { $0.name == "ConnectionId" }?.value == "abc123")
        #expect(items.first { $0.name == "TrustedClientToken" }?.value == EdgeToken.trustedClientToken)
    }

    @Test("handshake headers carry a fresh muid of the right shape")
    func handshakeHeaders() {        let headers = EdgeTTSClient.handshakeHeaders()
        let cookie = try? #require(headers["Cookie"])
        #expect(cookie?.hasPrefix("muid=") == true)
        #expect(cookie?.hasSuffix(";") == true)
        #expect(cookie?.count == 38) // "muid=" + 32 hex chars + ";"
        #expect(headers["Pragma"] == "no-cache")
    }
}

@Suite("OpenAI compatible speech settings")
struct OpenAISpeechSettingsTests {

    private func settings(_ base: String, model: String = "tts-1") -> RemoteTTSSettings {
        var settings = RemoteTTSSettings()
        settings.baseURL = base
        settings.model = model
        return settings
    }

    @Test("the speech path is appended the way each convention expects")
    func buildsURL() {
        #expect(settings("https://api.example.com/v1").speechURL?.absoluteString
            == "https://api.example.com/v1/audio/speech")
        #expect(settings("https://api.example.com/v1/").speechURL?.absoluteString
            == "https://api.example.com/v1/audio/speech")
        #expect(settings("https://api.example.com").speechURL?.absoluteString
            == "https://api.example.com/v1/audio/speech")
        #expect(settings("https://api.example.com/v1/audio/speech").speechURL?.absoluteString
            == "https://api.example.com/v1/audio/speech")
        #expect(settings("   ").speechURL == nil)
    }

    @Test("remote engines are only usable once configured")
    func usability() {
        var tts = TTSSettings(engine: .system)
        #expect(!tts.isRemoteUsable)

        tts.engine = .edge
        #expect(tts.isRemoteUsable)

        tts.engine = .openAICompatible
        #expect(!tts.isRemoteUsable)

        tts.remote.baseURL = "http://127.0.0.1:8880/v1"
        tts.remote.model = "tts-1"
        #expect(tts.isRemoteUsable)
    }

    @Test("old settings blobs keep working and pick up the new engine default")
    func backwardsCompatible() throws {
        let json = """
        {"rate":0.45,"pitch":1.1,"volume":1.0,"autoNextChapter":false,"sentencePause":0.2}
        """
        let tts = try JSONDecoder().decode(TTSSettings.self, from: Data(json.utf8))
        #expect(tts.rate == 0.45)
        #expect(tts.autoNextChapter == false)
        // Blobs written before the engine choice existed have no key at all.
        // They inherit the current default rather than a stale one, so an
        // upgrade gets the natural voices the feature was added for.
        #expect(tts.engine == .edge)

        let fresh = TTSSettings()
        #expect(fresh.engine == .edge)
        #expect(fresh.cacheEnabled)
        #expect(fresh.cacheLimitMB == 300)
    }
}
