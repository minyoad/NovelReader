import Foundation
import Testing
@testable import NovelKit

/// Hits the real service. Skipped unless `EDGE_TTS_LIVE=1`, so the normal test
/// run stays offline and deterministic — the token, frame parsing and SSML are
/// covered by the unit tests above.
///
/// Needs `URLSessionWebSocketTask`, which Foundation on Linux cannot provide
/// (libcurl has no WebSocket support), so this only runs on Apple platforms.
#if canImport(Darwin)
@Suite("Edge live synthesis", .enabled(if: ProcessInfo.processInfo.environment["EDGE_TTS_LIVE"] == "1"))
struct EdgeLiveTests {

    @Test("a short Chinese sentence comes back as MP3 with timings")
    func synthesizes() async throws {
        let text = "他推开石门。风从甬道深处灌出来，带着潮湿的土腥味。"
        let speech = try await EdgeTTSClient().synthesize(text: text, voice: "zh-CN-YunxiNeural")

        // A valid MP3 frame starts with an 0xFF sync byte.
        #expect(speech.audio.count > 1000)
        #expect(speech.audio.first == 0xFF)
        #expect(speech.boundaries.count == 2)
        #expect(speech.boundaries[0].text == "他推开石门。")
        #expect(speech.boundaries[1].start > speech.boundaries[0].start)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("edge-live.mp3")
        try speech.audio.write(to: path)
        print("LIVE_AUDIO \(speech.audio.count) bytes, \(speech.boundaries.count) boundaries, saved to \(path.path)")
    }
}
#endif
