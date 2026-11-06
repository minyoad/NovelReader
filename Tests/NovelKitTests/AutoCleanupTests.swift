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
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.aiAutoClean)
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
