import Testing
import Foundation
@testable import NovelKit

@Suite("AI output formats")
struct AIFormatTests {

    private let messy = """
    第一段内容。
    第二段内容。

    第三段内容。
    """

    @Test("paragraphs keeps one line per paragraph")
    func paragraphs() {
        let result = AIPrompt.apply(.paragraphs, to: messy)
        #expect(result == "第一段内容。\n第二段内容。\n第三段内容。")
    }

    @Test("spaced inserts a blank line between paragraphs")
    func spaced() {
        let result = AIPrompt.apply(.spaced, to: messy)
        #expect(result == "第一段内容。\n\n第二段内容。\n\n第三段内容。")
    }

    @Test("continuous joins everything into one block")
    func continuous() {
        let result = AIPrompt.apply(.continuous, to: messy)
        #expect(result == "第一段内容。第二段内容。第三段内容。")
        #expect(!result.contains("\n"))
    }

    @Test("original keeps the model's own line breaks, blank lines included")
    func original() {
        let result = AIPrompt.apply(.original, to: messy)
        #expect(result == "第一段内容。\n第二段内容。\n\n第三段内容。")
    }

    @Test("empty input stays empty for every format")
    func emptyInput() {
        for format in AIPrompt.OutputFormat.allCases {
            #expect(AIPrompt.apply(format, to: "\n\n  \n").isEmpty)
        }
    }

    @Test("prompt describes the requested layout")
    func promptMentionsFormat() {
        let continuous = AIPrompt.systemPrompt(for: .tidy, format: .continuous)
        #expect(continuous.contains("连续的一整段"))

        let spaced = AIPrompt.systemPrompt(for: .tidy, format: .spaced)
        #expect(spaced.contains("空一行"))

        // Paragraph mode adds no layout instruction: the default already says
        // one newline per paragraph.
        let plain = AIPrompt.systemPrompt(for: .tidy, format: .paragraphs)
        #expect(!plain.contains("连续的一整段"))
        #expect(!plain.contains("空一行"))
    }

    @Test("custom instruction is still appended")
    func customInstruction() {
        let prompt = AIPrompt.systemPrompt(for: .proofread, custom: "保留章节标题", format: .spaced)
        #expect(prompt.contains("额外要求：保留章节标题"))
    }
}

@Suite("Reading typography settings")
struct ReadingSettingsTests {

    @Test("new fields default sensibly")
    func defaults() {
        let reading = ReadingSettings()
        #expect(reading.firstLineIndent)
        #expect(reading.alignment == .justify)
        #expect(reading.showChapterTitle)
    }

    @Test("old settings JSON still decodes and keeps its values")
    func backwardsCompatibleDecoding() throws {
        // A settings blob written by the previous build: no typography keys.
        let json = """
        {
          "fontSize": 22,
          "lineSpacing": 10,
          "paragraphSpacing": 14,
          "horizontalPadding": 24,
          "theme": "night",
          "pageTurnMode": "page",
          "pageTurnEffect": "curl"
        }
        """
        let reading = try JSONDecoder().decode(ReadingSettings.self, from: Data(json.utf8))
        #expect(reading.fontSize == 22)
        #expect(reading.lineSpacing == 10)
        #expect(reading.theme == .night)
        #expect(reading.pageTurnEffect == .curl)
        // Missing keys fall back to defaults instead of failing the decode.
        #expect(reading.firstLineIndent)
        #expect(reading.alignment == .justify)
    }

    @Test("AppSettings written before caching existed still decodes")
    func appSettingsBackwardsCompatible() throws {
        let json = """
        {
          "searchAllSources": false,
          "reading": { "fontSize": 20, "theme": "sepia" }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.searchAllSources == false)
        #expect(settings.reading.fontSize == 20)
        #expect(settings.cache.prefetchCount == 5, "缺失的缓存设置应取默认值")
        #expect(settings.aiOutputFormat == .paragraphs)
    }

    @Test("settings round-trip through JSON")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.reading.alignment = .leading
        settings.reading.firstLineIndent = false
        settings.cache.prefetchCount = 12
        settings.aiOutputFormat = .spaced

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }
}

@Suite("Chapter cleanup restore")
struct ChapterContentTests {

    @Test("cleaned content keeps the original for comparison")
    func keepsOriginal() {
        let original = ChapterContent(chapterURL: "https://example.org/1", text: "原始正文")
        let cleaned = ChapterContent(
            chapterURL: original.chapterURL,
            text: "整理后正文",
            cleaned: true,
            originalText: original.text
        )
        #expect(cleaned.cleaned)
        #expect(cleaned.originalText == "原始正文")
    }

    @Test("restored drops the cleaned text")
    func restored() {
        let cleaned = ChapterContent(
            chapterURL: "https://example.org/1",
            text: "整理后正文",
            cleaned: true,
            originalText: "原始正文"
        )
        let reverted = cleaned.restored()
        #expect(reverted.text == "原始正文")
        #expect(!reverted.cleaned)
        #expect(reverted.originalText == nil, "还原后不应再保留副本")
    }

    @Test("restoring without an original is a no-op")
    func restoreWithoutOriginal() {
        let content = ChapterContent(chapterURL: "https://example.org/1", text: "正文")
        #expect(content.restored() == content)
    }

    @Test("old cached content decodes without the new field")
    func oldCacheDecodes() throws {
        let json = """
        {"chapterURL":"https://example.org/1","text":"正文","cleaned":false,
         "fetchedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try decoder.decode(ChapterContent.self, from: Data(json.utf8))
        #expect(content.text == "正文")
        #expect(content.originalText == nil)
    }
}
