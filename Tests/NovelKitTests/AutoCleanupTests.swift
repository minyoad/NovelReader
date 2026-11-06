import Testing
import Foundation
@testable import NovelKit

@Suite("Automatic ad cleanup")
struct AutoCleanupTests {

    private func body(_ text: String, cleaned: Bool = false) -> ChapterContent {
        ChapterContent(chapterURL: "https://example.org/1", text: text, cleaned: cleaned)
    }

    @Test("new chapters run once the switch is on")
    func runsWhenEnabled() {
        let raw = body("陆离推开门。\n本章由某某小说网首发，更多章节请访问 www.example.com")
        #expect(AutoCleanup.shouldRun(content: raw, enabled: true, chapterTitle: "第一章"))
    }

    @Test("the switch off means no API call, even for text that needs one")
    func offByDefault() {
        let raw = body("正文\n求收藏求推荐")
        #expect(!AutoCleanup.shouldRun(content: raw, enabled: false, chapterTitle: "第一章"))
    }

    @Test("already cleaned text is not sent again")
    func skipsCleaned() {
        let cleaned = body("正文", cleaned: true)
        // Re-running costs an API call and risks the model touching prose that
        // an earlier pass already accepted.
        #expect(!AutoCleanup.shouldRun(content: cleaned, enabled: true, chapterTitle: "第一章"))
    }

    @Test("empty bodies are not sent")
    func skipsEmpty() {
        #expect(!AutoCleanup.shouldRun(content: body("   \n\n "), enabled: true, chapterTitle: "第一章"))
    }

    @Test("placeholder bodies are not sent")
    func skipsPlaceholder() {
        // A paywall stub is not prose: a model asked to tidy it invents a
        // chapter, and the reader would cache that as the real text.
        let stub = body("内容正在获取中，稍候重试")
        #expect(TextProcessing.isPlaceholderContent(stub.text, chapterTitle: "第一章"))
        #expect(!AutoCleanup.shouldRun(content: stub, enabled: true, chapterTitle: "第一章"))
    }

    @Test("the failure banner names the chapter")
    func failureMessage() {
        let message = AutoCleanup.failureMessage(chapterTitle: "第七章 夜雨")
        #expect(message.contains("第七章 夜雨"))
        #expect(message.contains("原文"))
    }
}

@Suite("Ad-clean chunks: the whole chapter is sent")
struct AutoCleanupChunkTests {

    private func paragraphs(_ count: Int, _ prefix: String = "第", chars: Int = 120) -> [String] {
        (0..<count).map { index in
            let filler = String(repeating: "文", count: max(chars - 3, 1))
            return "\(prefix)\(index)\(filler)"
        }
    }

    @Test("a chapter that fits in one request is sent as one")
    func oneRequestWhenItFits() {
        // Splitting a chapter that fits would pay for the system prompt once
        // per chunk and make the model judge the prose in pieces. The limit
        // comes from the output budget, so this is the common case.
        let limit = AutoCleanup.chunkLength(maxTokens: 2048)
        let text = paragraphs(5, chars: limit / 6).joined(separator: "\n")
        #expect(text.count <= limit)
        #expect(AutoCleanup.chunks(for: text, limit: limit).count == 1)
    }

    @Test("the chunk limit is derived from the output budget, not a guess")
    func limitFromOutputBudget() {
        // A reply is as long as what was sent, so a chunk must fit in
        // max_tokens after the safety margin.
        for maxTokens in [1024, 2048, 4096, 8192] {
            let limit = AutoCleanup.chunkLength(maxTokens: maxTokens)
            let estimated = Double(limit) * AutoCleanup.tokensPerCharacter
            #expect(estimated <= Double(maxTokens), "\(maxTokens) token 不够输出 \(limit) 字")
        }
        // More budget must buy longer chunks, never shorter ones.
        let budgets = [1024, 2048, 4096].map { AutoCleanup.chunkLength(maxTokens: $0) }
        #expect(budgets == budgets.sorted())
        // The old hard-coded 1800 did not fit the default 2048 budget.
        #expect(AutoCleanup.chunkLength(maxTokens: 2048) < 1800)
    }

    @Test("the user's chunk size is capped by the output budget")
    func userSettingCapped() {
        // The stepper goes up to 4000 while the default budget tops out near
        // 1100. Taking the user's number at face value would cut replies off.
        let capped = AutoCleanup.effectiveChunkLength(chunkSize: 4000, maxTokens: 2048)
        #expect(capped == AutoCleanup.chunkLength(maxTokens: 2048))
        // A smaller number is respected as-is: it is the safer direction.
        #expect(AutoCleanup.effectiveChunkLength(chunkSize: 600, maxTokens: 2048) == 600)
        // A bigger output budget lets the user's number through.
        #expect(AutoCleanup.effectiveChunkLength(chunkSize: 4000, maxTokens: 8192) == 4000)
    }

    @Test("a short chapter is one chunk")
    func shortChapter() {
        let text = "开头一句。\n结尾一句。"
        #expect(AutoCleanup.chunks(for: text) == [text])
    }

    @Test("the middle of a long chapter is sent, not skipped")
    func middleIsSent() {
        // The regression this guards: an ad URL pasted between two middle
        // paragraphs. An edges-only scope never showed it to the model.
        let lines = paragraphs(30)
        let middle = lines[15]
        let text = (lines.enumerated().flatMap { index, line in
            index == 15 ? [line, "最新网址 www.example.com"] : [line]
        }).joined(separator: "\n")
        let chunks = AutoCleanup.chunks(for: text)
        #expect(chunks.count > 1)
        #expect(chunks.contains { $0.contains(middle) })
        #expect(chunks.contains { $0.contains("www.example.com") })
    }

    @Test("every chunk is within budget or a single oversized paragraph")
    func sizesWithinBudget() {
        // 40 paragraphs × 200 chars = 8000, so several chunks.
        let text = paragraphs(40, chars: 200).joined(separator: "\n")
        let chunks = AutoCleanup.chunks(for: text)
        #expect(chunks.count >= 4)
        for chunk in chunks {
            let lines = chunk.components(separatedBy: "\n")
            if lines.count > 1 {
                #expect(chunk.count <= 1100 + AutoCleanup.overlapParagraphs * 200)
            }
        }
    }

    @Test("a paragraph longer than the budget is not cut in half")
    func oversizedParagraphWhole() {
        // Cutting a paragraph gives the model a half-line, which it is told
        // never to delete partially — and which it will happily rewrite.
        let huge = String(repeating: "长", count: AutoCleanup.chunkLength(maxTokens: 2048) * 3)
        let chunks = AutoCleanup.chunks(for: "短\n" + huge + "\n短")
        #expect(chunks.contains { $0.contains(huge) })
    }

    @Test("neighbouring chunks share one paragraph of context")
    func overlapExists() {
        let text = paragraphs(30).joined(separator: "\n")
        let chunks = AutoCleanup.chunks(for: text)
        #expect(chunks.count > 1)
        for index in 1..<chunks.count {
            let previousLast = chunks[index - 1].components(separatedBy: "\n").last
            let currentFirst = chunks[index].components(separatedBy: "\n").first
            #expect(previousLast == currentFirst, "第 \(index) 块没有带上文")
        }
    }

    @Test("no heading runs past the overlap")
    func overlapIsOne() {
        let text = paragraphs(30).joined(separator: "\n")
        let chunks = AutoCleanup.chunks(for: text)
        let firstLines = Set(chunks[0].components(separatedBy: "\n"))
        let secondLines = chunks[1].components(separatedBy: "\n")
        #expect(secondLines.filter { firstLines.contains($0) }.count == AutoCleanup.overlapParagraphs)
    }

    @Test("nothing is lost when the model changes nothing")
    func roundTripUnchanged() {
        for count in 3...40 {
            for chars in [20, 300, 700, 1500] {
                let source = paragraphs(count, chars: chars)
                let text = source.joined(separator: "\n")
                let chunks = AutoCleanup.chunks(for: text)
                let rebuilt = AutoCleanup.reassemble(chunks: chunks, cleaned: chunks)
                #expect(rebuilt == text, "\(count) 段 × \(chars) 字时丢内容或重复")
            }
        }
    }

    @Test("cleaned chunks come back in order without the overlap")
    func reassemblesCleaned() {
        let chunks = ["甲\n乙", "乙\n丙\n广告", "丙\n丁"]
        let cleaned = ["甲\n乙", "乙\n丙", "丙\n丁"]
        #expect(AutoCleanup.reassemble(chunks: chunks, cleaned: cleaned) == "甲\n乙\n丙\n丁")
    }

    @Test("a chunk that was nothing but ads disappears")
    func emptyChunk() {
        let chunks = ["甲\n乙", "乙\n丙"]
        let cleaned = ["甲\n乙", ""]
        #expect(AutoCleanup.reassemble(chunks: chunks, cleaned: cleaned) == "甲\n乙")
    }

    @Test("an overlap the model also deleted does not eat new text")
    func deletedOverlap() {
        // The model judged the carried-over paragraph to be part of a block it
        // removed. The next chunk's own first paragraph must survive.
        let chunks = ["甲\n乙", "乙\n丙"]
        let cleaned = ["甲", "丙"]
        #expect(AutoCleanup.reassemble(chunks: chunks, cleaned: cleaned) == "甲\n丙")
    }

    @Test("a genuine repeated line after the seam is kept")
    func repeatedDialogueKept() {
        let chunks = ["甲\n乙", "乙\n乙"]
        let cleaned = chunks
        // "<chunk1 last>" is the overlap; the second "乙" belongs to chunk 2.
        #expect(AutoCleanup.reassemble(chunks: chunks, cleaned: cleaned) == "甲\n乙\n乙")
    }

    @Test("a mismatched reply count is rejected rather than misaligned")
    func countMismatch() {
        // Returning "" makes the caller keep the original; guessing an
        // alignment could splice the wrong paragraphs together.
        #expect(AutoCleanup.reassemble(chunks: ["甲", "乙"], cleaned: ["甲"]) == "")
    }

    @Test("a truncated reply is an error, not half a chapter")
    func truncatedIsError() {
        // Before this, `finish_reason: length` was ignored and the clipped
        // reply was saved as the cleaned chapter — the ending simply vanished.
        let error: Error = AIError.truncated(limit: 2048)
        let message = error.localizedDescription
        #expect(message.contains("截断"))
        // The message has to say what to change, since the reader cannot see
        // which knob is responsible.
        #expect(message.contains("最大输出") || message.contains("分块大小"))
    }
}

@Suite("Cleaning ahead")
struct CleanAheadTests {

    @Test("queues the next chapters in reading order")
    func orders() {
        let plan = AutoCleanup.cleanAheadIndices(
            currentIndex: 4, chapterCount: 20, ahead: 3,
            alreadyCleaned: [], failed: []
        )
        #expect(plan == [5, 6, 7])
    }

    @Test("skips chapters already cleaned")
    func skipsCleaned() {
        // A reader who flips back and forth must not pay for the same chapter
        // twice.
        let plan = AutoCleanup.cleanAheadIndices(
            currentIndex: 4, chapterCount: 20, ahead: 3,
            alreadyCleaned: [5], failed: []
        )
        #expect(plan == [6, 7, 8])
    }

    @Test("skips chapters that failed before")
    func skipsFailed() {
        let plan = AutoCleanup.cleanAheadIndices(
            currentIndex: 4, chapterCount: 20, ahead: 3,
            alreadyCleaned: [], failed: [5]
        )
        #expect(plan == [6, 7, 8])
    }

    @Test("stops at the end of the book")
    func stopsAtEnd() {
        let plan = AutoCleanup.cleanAheadIndices(
            currentIndex: 18, chapterCount: 20, ahead: 5,
            alreadyCleaned: [], failed: []
        )
        #expect(plan == [19])
    }

    @Test("zero ahead disables the queue")
    func zeroAhead() {
        let plan = AutoCleanup.cleanAheadIndices(
            currentIndex: 0, chapterCount: 10, ahead: 0,
            alreadyCleaned: [], failed: []
        )
        #expect(plan.isEmpty)
    }

    @Test("three chapters ahead by default")
    func defaultSetting() {
        // The default has to be non-zero: with 0 the queue is off and every
        // page turn waits for the model again, which is the bug this fixes.
        #expect(AppSettings().aiCleanAhead == 3)
    }

    @Test("an old settings file without the new key gets the default")
    func backwardsCompatible() throws {
        let json = """
        { "aiAutoClean": true, "searchAllSources": true }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.aiAutoClean)
        #expect(settings.aiCleanAhead == 3)
    }
}

@Suite("Ad-strip prompt")
struct AdStripPromptTests {

    @Test("stripAds is automatic only, not offered in the manual menu")
    func notInManualMenu() {
        #expect(AIPrompt.ChapterTask.allCases.contains(.stripAds))
        #expect(!AIPrompt.ChapterTask.manualTasks.contains(.stripAds))
        #expect(AIPrompt.ChapterTask.manualTasks.count == 3)
        // The manual menu must not lose the tasks it already had.
        #expect(AIPrompt.ChapterTask.manualTasks.contains(.tidy))
    }

    @Test("the prompt names all three kinds of junk to remove")
    func promptCoversThreeKinds() {
        let prompt = AIPrompt.systemPrompt(for: .stripAds)
        #expect(prompt.contains("广告"))
        #expect(prompt.contains("与剧情无关的废话"))
        #expect(prompt.contains("章节末尾附加"))
        // Ads between paragraphs are the reason the whole chapter is sent.
        #expect(prompt.contains("段落中间"))
    }

    @Test("the prompt forbids rewriting and re-paragraphing")
    func promptKeepsBodyVerbatim() {
        let prompt = AIPrompt.systemPrompt(for: .stripAds)
        #expect(prompt.contains("不改写"))
        #expect(prompt.contains("不合并段落"))
        // Deleting half a sentence is how an ad filter ends up removing a
        // character's name; whole lines only.
        #expect(prompt.contains("整行或整段删除"))
        // Unsure means keep: leaving one ad in beats deleting a line of plot.
        #expect(prompt.contains("宁可留下一条广告"))
    }

    @Test("the prompt explains the chunking")
    func promptExplainsChunks() {
        let prompt = AIPrompt.systemPrompt(for: .stripAds)
        #expect(prompt.contains("切成多段"))
        #expect(prompt.contains("重复"))
        // The old head/tail wording would make the model think the middle is
        // an ellipsis and is free to be dropped.
        #expect(!prompt.contains("开头和结尾"))
    }

    @Test("layout instructions do not leak into an automatic strip")
    func noLayoutInstructions() {
        // The user's manual format setting must not make an automatic pass
        // join the chapter into one block or insert blank lines.
        for format in AIPrompt.OutputFormat.allCases {
            let prompt = AIPrompt.systemPrompt(for: .stripAds, format: format)
            #expect(!prompt.contains("连续的一整段"))
            #expect(!prompt.contains("空一行输出"))
        }
    }

    @Test("other tasks keep their layout instructions")
    func othersUnaffected() {
        let tidy = AIPrompt.systemPrompt(for: .tidy, format: .continuous)
        #expect(tidy.contains("连续的一整段"))
    }
}

@Suite("AppSettings: auto cleanup switch")
struct AutoCleanSettingsTests {

    @Test("absent from an old settings file means off")
    func defaultsOff() throws {
        // Existing installs must not start spending API calls after an update.
        let json = """
        { "searchAllSources": true, "aiOutputFormat": "paragraphs" }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.aiAutoClean == false)
        #expect(AppSettings().aiAutoClean == false)
    }

    @Test("the switch survives a JSON round-trip")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.aiAutoClean = true
        settings.aiCleanAhead = 5
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.aiAutoClean)
        #expect(decoded.aiCleanAhead == 5)
    }

    @Test("cleanup after the model leaves ordinary paragraphs alone")
    func cleanupKeepsProse() {
        // `aiClean` passes the model's reply through `cleanupChapterText`, which
        // also strips ad lines and consecutive duplicates. An automatic strip
        // must not have its correct output damaged by that second pass.
        let reply = "陆离推开门。\n雨下得很大。\n「进来吧。」"
        let cleaned = TextProcessing.cleanupChapterText(reply)
        #expect(cleaned == reply)
        // Repeated dialogue stays: it is often genuinely repeated in a novel,
        // and only *consecutive* identical lines are dropped.
        let dialogue = "「你来了。」\n「你来了。」\n他点头。"
        #expect(TextProcessing.cleanupChapterText(dialogue).components(separatedBy: "\n").count >= 2)
    }
}
