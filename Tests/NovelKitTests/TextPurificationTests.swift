import Foundation
import Testing
@testable import NovelKit

struct TextPurificationTests {
    private func settings(_ pattern: String, replacement: String = "", regex: Bool = false) -> TextPurificationSettings {
        var rule = TextPurificationRule()
        rule.pattern = pattern; rule.replacement = replacement; rule.isRegex = regex
        var settings = TextPurificationSettings()
        settings.enabled = true; settings.rules = [rule]
        return settings
    }

    @Test func literalReplacementDoesNotInterpretMetacharacters() {
        let result = TextPurification.apply("正文 [广告].* 正文", settings: settings("[广告].*", replacement: "$1\\尾"))
        #expect(result.text == "正文 $1\\尾 正文")
        #expect(result.warnings.isEmpty)
    }

    @Test func regexSupportsGroupsAndMultilineRemoval() {
        let result = TextPurification.apply("第123章\n广告：下载应用\n正文", settings: settings("(?m)^广告.*\\n?", regex: true))
        #expect(result.text == "第123章\n正文")
        let groups = TextPurification.apply("第123章", settings: settings("第(\\d+)章", replacement: "章节 $1", regex: true))
        #expect(groups.text == "章节 123")
    }

    @Test func sequentialRulesDisabledRulesAndReversibility() {
        var config = settings("广告")
        var next = TextPurificationRule(); next.pattern = "正文"; next.replacement = "故事"
        config.rules.append(next)
        var disabled = next; disabled.enabled = false; disabled.pattern = "故事"; disabled.replacement = "坏"
        config.rules.append(disabled)
        let original = "广告正文"
        #expect(TextPurification.apply(original, settings: config).text == "故事")
        config.enabled = false
        #expect(TextPurification.apply(original, settings: config).text == original)
    }

    @Test func invalidOrEmptyRulesPreserveInput() {
        for pattern in ["(", ""] {
            let config = settings(pattern, regex: true)
            #expect(config.rules[0].validationError != nil)
            let result = TextPurification.apply("正文", settings: config)
            #expect(result.text == "正文")
            #expect(!result.warnings.isEmpty)
        }
    }

    @Test func excessiveMatchesAreAbortedWithoutPartialEdits() {
        let original = String(repeating: "a", count: 11000)
        let result = TextPurification.apply(original, settings: settings("a", replacement: "b", regex: true))
        #expect(result.text == original)
        #expect(!result.warnings.isEmpty)
    }

    @Test func pathologicalRegexStopsWithinBudget() {
        let input = String(repeating: "a", count: 5000) + "!"
        let result = TextPurification.apply(input, settings: settings("(a+)+$", regex: true))
        #expect(result.text == input)
        #expect(!result.warnings.isEmpty)
    }

    @Test func persistenceIsScopedToEachBookAndDoesNotAlterContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let first = UUID(), second = UUID()
        let config = settings("广告")
        await store.saveTextPurification([first.uuidString: config])
        let content = ChapterContent(chapterURL: "chapter", text: "广告正文")
        await store.saveContent(content, bookID: first)
        let restored = await LibraryStore(directory: directory).loadTextPurification()
        #expect(restored[first.uuidString] == config)
        #expect(restored[second.uuidString] == nil)
        #expect(TextPurification.apply(content.text, settings: config).text == "正文")
        #expect(await store.loadContent(bookID: first, chapterURL: "chapter")?.text == "广告正文")
    }

    @Test func shelfProgressCoversUnreadUnknownAndOutOfRange() {
        #expect(ShelfReadingProgress(progress: ReadingProgress(), chapterCount: 10).label == "未读")
        let progress = ReadingProgress(chapterIndex: 2, characterOffset: 50, updatedAt: Date())
        let known = ShelfReadingProgress(progress: progress, chapterCount: 10, textLength: 100)
        #expect(known.fraction == 0.25)
        #expect(known.label == "约 25% · 3/10 章")
        #expect(ShelfReadingProgress(progress: progress, chapterCount: 0).fraction == nil)
        #expect(ShelfReadingProgress(progress: progress, chapterCount: 10).fraction == 0.2)
        let invalid = ReadingProgress(chapterIndex: -4, characterOffset: -1, updatedAt: Date())
        #expect(ShelfReadingProgress(progress: invalid, chapterCount: 10, textLength: 100).fraction == 0)
        let end = ReadingProgress(chapterIndex: 100, characterOffset: 200, updatedAt: Date())
        #expect(ShelfReadingProgress(progress: end, chapterCount: 10, textLength: 100).fraction == 1)
    }
}
