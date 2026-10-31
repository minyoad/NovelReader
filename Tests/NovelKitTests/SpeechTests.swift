import Foundation
import Testing
@testable import NovelKit

@Suite("Speech chunking")
struct SpeechChunkerTests {

    @Test("short sentences are grouped into one request")
    func groupsShortSentences() {
        let sentences = ["他推开石门。", "风从甬道深处灌出来。", "远处有一点灯火。"]
        let chunks = SpeechChunker.sentenceChunks(sentences)
        #expect(chunks.count == 1)
        #expect(chunks[0].sentenceStart == 0)
        #expect(chunks[0].sentenceCount == 3)
        #expect(chunks[0].text == "他推开石门。风从甬道深处灌出来。远处有一点灯火。")
    }

    @Test("chunks break before the character limit and keep sentence indices contiguous")
    func splitsOnLimit() {
        let sentences = Array(repeating: String(repeating: "字", count: 40) + "。", count: 12)
        let chunks = SpeechChunker.sentenceChunks(sentences, maxCharacters: 100)

        #expect(chunks.count > 1)
        // Every sentence must appear exactly once, in order, across the chunks.
        #expect(chunks.reduce(0) { $0 + $1.sentenceCount } == sentences.count)
        var expectedStart = 0
        for chunk in chunks {
            #expect(chunk.sentenceStart == expectedStart)
            #expect(chunk.text.count <= 100)
            expectedStart += chunk.sentenceCount
        }
    }

    @Test("a single over-long sentence still becomes its own chunk")
    func keepsOverlongSentence() {
        let long = String(repeating: "字", count: 500)
        let chunks = SpeechChunker.sentenceChunks([long], maxCharacters: 100)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == long)
    }

    @Test("blank sentences are skipped without shifting indices")
    func skipsBlanks() {
        let sentences = ["", "第一句。", "   ", "第二句。"]
        let chunks = SpeechChunker.sentenceChunks(sentences)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "第一句。第二句。")
        // Two sentences were sent, so the highlight range covers both even
        // though the blanks were dropped.
        #expect(chunks[0].sentenceCount == 2)
    }

    @Test("paragraph text is chunked without crossing blank lines")
    func paragraphChunks() {
        let text = "第一段。\n\n第二段。"
        let chunks = SpeechChunker.chunks(from: text)
        #expect(chunks == ["第一段。", "第二段。"])
    }
}

@Suite("Speech cache")
struct SpeechCacheTests {

    @Test("key changes with engine, voice, rate, pitch and text")
    func keyCoversInputs() {
        let base = SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "zh-CN-YunxiNeural", rate: 0.5, pitch: 1.0)
        #expect(SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "zh-CN-YunxiNeural", rate: 0.5, pitch: 1.0) == base)

        #expect(SpeechCacheKey.key(text: "再见。", engine: .edge, voice: "zh-CN-YunxiNeural", rate: 0.5, pitch: 1.0) != base)
        #expect(SpeechCacheKey.key(text: "你好。", engine: .system, voice: "zh-CN-YunxiNeural", rate: 0.5, pitch: 1.0) != base)
        #expect(SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "zh-CN-XiaoxiaoNeural", rate: 0.5, pitch: 1.0) != base)
        #expect(SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "zh-CN-YunxiNeural", rate: 0.7, pitch: 1.0) != base)
        #expect(SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "zh-CN-YunxiNeural", rate: 0.5, pitch: 1.1) != base)
    }

    @Test("sub-cent slider noise does not invalidate the cache")
    func keyIgnoresTinyDrift() {
        let a = SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "v", rate: 0.500, pitch: 1.0)
        let b = SpeechCacheKey.key(text: "你好。", engine: .edge, voice: "v", rate: 0.501, pitch: 1.0)
        #expect(a == b)
    }

    @Test("nothing is evicted when under the limit")
    func noEvictionUnderLimit() {
        let entries = [
            (key: "a", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 1)),
            (key: "b", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 2)),
        ]
        #expect(SpeechCachePolicy.evictionOrder(entries: entries, limitBytes: 1000).isEmpty)
    }

    @Test("oldest entries go first until the cache fits")
    func evictsOldestFirst() {
        let entries = [
            (key: "new", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 30)),
            (key: "old", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 10)),
            (key: "mid", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 20)),
        ]
        // 300 bytes cached against a 100 byte cap: the two oldest have to go.
        let doomed = SpeechCachePolicy.evictionOrder(entries: entries, limitBytes: 100)
        #expect(doomed == ["old", "mid"])
    }

    @Test("eviction stops as soon as the cache fits")
    func evictsOnlyWhatIsNeeded() {
        let entries = [
            (key: "new", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 30)),
            (key: "old", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 10)),
            (key: "mid", size: Int64(100), lastUsed: Date(timeIntervalSince1970: 20)),
        ]
        // 300 cached, 250 allowed: dropping the single oldest is enough, and
        // deleting a second file would throw away audio for nothing.
        #expect(SpeechCachePolicy.evictionOrder(entries: entries, limitBytes: 250) == ["old"])
    }

    @Test("a zero limit means unlimited, not delete everything")
    func zeroLimitIsUnlimited() {
        let entries = [(key: "a", size: Int64(100), lastUsed: Date())]
        #expect(SpeechCachePolicy.evictionOrder(entries: entries, limitBytes: 0).isEmpty)
    }
}

@Suite("Speech cache storage")
struct SpeechCacheStoreTests {

    private func makeStore() -> LibraryStore {
        LibraryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelReaderSpeech-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("written audio is readable and counted")
    func roundTrip() async {
        let store = makeStore()
        await store.saveSpeech(Data([1, 2, 3, 4]), key: "abc")

        #expect(await store.hasSpeech(key: "abc"))
        #expect(await store.loadSpeech(key: "abc") == Data([1, 2, 3, 4]))
        #expect(await store.speechCacheCount() == 1)
        #expect(await store.speechCacheSize() == 4)
    }

    @Test("trimming removes least recently used files")
    func trims() async {
        let store = makeStore()
        await store.saveSpeech(Data(repeating: 0, count: 100), key: "old")
        await store.saveSpeech(Data(repeating: 0, count: 100), key: "new")

        // Backdate the older one; the store uses mtime as "last used".
        let oldURL = await store.speechFileURL(key: "old")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)],
            ofItemAtPath: oldURL.path
        )

        let result = await store.trimSpeechCache(limitBytes: 150)
        #expect(result.removed == 1)
        #expect(result.freed == 100)
        #expect(await store.hasSpeech(key: "new"))
        #expect(!(await store.hasSpeech(key: "old")))
    }

    @Test("clearing removes every utterance")
    func clears() async {
        let store = makeStore()
        await store.saveSpeech(Data(repeating: 0, count: 10), key: "a")
        await store.saveSpeech(Data(repeating: 0, count: 20), key: "b")

        let result = await store.clearSpeechCache()
        #expect(result.removed == 2)
        #expect(result.freed == 30)
        #expect(await store.speechCacheCount() == 0)
    }
}
