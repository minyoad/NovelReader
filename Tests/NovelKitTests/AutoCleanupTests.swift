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

@Suite("Ad-clean scope: head and tail only")
struct AutoCleanupScopeTests {

    private func paragraphs(_ count: Int, _ prefix: String = "第", chars: Int = 120) -> [String] {
        (0..<count).map { index in
            let filler = String(repeating: "文", count: max(chars - 3, 1))
            return "\(prefix)\(index)\(filler)"
        }
    }

    @Test("a short chapter is sent whole")
    func shortChapterWhole() {
        let text = "开头一句。\n结尾一句。"
        let scope = AutoCleanup.scope(for: text)
        #expect(scope.isWholeChapter)
        #expect(scope.prompt == "开头一句。\n结尾一句。")
    }

    @Test("a long chapter sends only its edges and keeps the middle back")
    func longChapterSplits() {
        let text = paragraphs(30).joined(separator: "\n")
        let scope = AutoCleanup.scope(for: text)
        #expect(!scope.isWholeChapter)
        // The middle is the bulk of the chapter and is never sent.
        #expect(scope.middle.count > scope.head.count)
        #expect(!scope.prompt.contains(scope.middle))
        // Reassembly puts everything back in order, byte for byte.
        #expect(AutoCleanup.reassemble(scope: scope, cleaned: scope) == text)
    }

    @Test("no paragraph is lost between head, middle and tail")
    func everyParagraphAccountedFor() {
        // Regression: the tail scan stopped one paragraph short of the head
        // window, and that paragraph fell out of the chapter on reassembly.
        // Sizes around the loop conditions are where this hides.
        for count in 3...40 {
            for chars in [20, 300, 700, 1500] {
                let source = paragraphs(count, chars: chars)
                let text = source.joined(separator: "\n")
                let scope = AutoCleanup.scope(for: text)
                let rebuilt = AutoCleanup.reassemble(scope: scope, cleaned: scope)
                #expect(rebuilt == text, "\(count) 段 × \(chars) 字时丢内容")
            }
        }
    }

    @Test("the head and tail never overlap")
    func noOverlap() {
        let text = paragraphs(6, chars: AutoCleanup.edgeLength * 2).joined(separator: "\n")
        let scope = AutoCleanup.scope(for: text)
        #expect(!scope.isWholeChapter)
        let headParagraphs = scope.head.components(separatedBy: "\n")
        let tailParagraphs = scope.tail.components(separatedBy: "\n")
        #expect(Set(headParagraphs).isDisjoint(with: Set(tailParagraphs)))
        #expect(!scope.middle.isEmpty || headParagraphs.count + tailParagraphs.count == 6)
    }

    @Test("the prompt is two blocks separated by a marker")
    func promptHasSeparator() {
        let text = paragraphs(30).joined(separator: "\n")
        let prompt = AutoCleanup.scope(for: text).prompt
        #expect(prompt.contains(AIPrompt.scopeSeparator))
        // Exactly one marker: two would make the reply ambiguous.
        let markers = prompt.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == AIPrompt.scopeSeparator }
        #expect(markers.count == 1)
    }

    @Test("cleaned edges are quoted around the untouched middle")
    func reassembleKeepsMiddle() {
        let scope = AutoCleanup.Scope(head: "开头\n广告", tail: "求收藏\n结尾", middle: "中间正文")
        let cleaned = AutoCleanup.Scope(head: "开头", tail: "结尾", middle: "")
        #expect(AutoCleanup.reassemble(scope: scope, cleaned: cleaned) == "开头\n中间正文\n结尾")
    }

    @Test("an emptied head keeps the middle and tail")
    func emptyHead() {
        let scope = AutoCleanup.Scope(head: "全是广告", tail: "结尾", middle: "中间")
        let cleaned = AutoCleanup.Scope(head: "", tail: "结尾", middle: "")
        #expect(AutoCleanup.reassemble(scope: scope, cleaned: cleaned) == "中间\n结尾")
    }

    @Test("both edges emptied falls back to the original")
    func bothEdgesEmpty() {
        // The model rejected everything it was shown. Putting that back would
        // lose the chapter's opening and ending at once.
        let scope = AutoCleanup.Scope(head: "开头", tail: "结尾", middle: "中间")
        let cleaned = AutoCleanup.Scope(head: "", tail: "", middle: "")
        #expect(AutoCleanup.reassemble(scope: scope, cleaned: cleaned) == scope.prompt)
    }

    @Test("a whole-chapter reply that comes back empty keeps the original")
    func wholeEmpty() {
        let scope = AutoCleanup.Scope(head: "原文", tail: "", middle: "")
        let cleaned = AutoCleanup.Scope(head: "  ", tail: "", middle: "")
        #expect(AutoCleanup.reassemble(scope: scope, cleaned: cleaned) == "原文")
    }
}

@Suite("Reading a head/tail reply")
struct ScopeReplyTests {

    @Test("the marker splits head from tail")
    func splitsOnMarker() {
        let reply = "开头\n\(AIPrompt.scopeSeparator)\n结尾"
        let scope = AIPrompt.readScopeReply(reply)
        #expect(scope.head == "开头")
        #expect(scope.tail == "结尾")
    }

    @Test("a longer or shorter run of equals still counts")
    func toleratesMarkerLength() {
        // Models copy the separator with however many characters they like.
        let reply = "开头\n=====\n结尾"
        let scope = AIPrompt.readScopeReply(reply)
        #expect(scope.head == "开头")
        #expect(scope.tail == "结尾")
    }

    @Test("a reply without a marker is treated as the head")
    func noMarker() {
        // The safe side: the trailer is then kept as it was, rather than the
        // head being pasted over the whole chapter.
        let scope = AIPrompt.readScopeReply("只有一段")
        #expect(scope.head == "只有一段")
        #expect(scope.tail.isEmpty)
    }

    @Test("a code fence around the reply is stripped first")
    func fenced() {
        let reply = "```\n开头\n\(AIPrompt.scopeSeparator)\n结尾\n```"
        let scope = AIPrompt.readScopeReply(reply)
        #expect(scope.head == "开头")
        #expect(scope.tail == "结尾")
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

    @Test("the prompt explains the head/tail input")
    func promptExplainsEdges() {
        let prompt = AIPrompt.systemPrompt(for: .stripAds)
        #expect(prompt.contains("开头和结尾"))
        #expect(prompt.contains(AIPrompt.scopeSeparator))
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
