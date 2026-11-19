import Foundation
import Testing
@testable import NovelKit

struct AIResponseValidationTests {
    @Test func rejectsRefusalsIncludingReportedTypoAndMixedReplies() {
        for reply in ["I cannot Response this request", "I cannot respond to this request.",
                      "I'm sorry, I can't help with that request.", "I can’t comply with this request.",
                      "抱歉，我无法处理此请求。", "原来的正文\nI cannot respond to this request."] {
            #expect(throws: AIError.self) {
                try AIResponseValidation.validated(reply, original: "原来的正文\n广告", task: .stripAds)
            }
            #expect(AIResponseValidation.hasIntroducedRefusal(reply, original: "原来的正文\n广告"))
        }
    }

    @Test func adRemovalMayDeleteButNotInventOrRewrite() throws {
        let source = "第一段正文。\n下载广告\n第二段正文。"
        #expect(try AIResponseValidation.validated("第一段正文。\n\n第二段正文。", original: source, task: .stripAds) == "第一段正文。\n\n第二段正文。")
        #expect(try AIResponseValidation.validated("", original: "下载广告", task: .stripAds).isEmpty)
        #expect(throws: AIError.self) {
            try AIResponseValidation.validated("以下是净化结果：第一段正文。", original: source, task: .stripAds)
        }
        #expect(throws: AIError.self) {
            try AIResponseValidation.validated("第二段正文。第一段正文。", original: source, task: .stripAds)
        }
    }

    @Test func unwrapsFencesAndRetainsActualDialogue() throws {
        let source = "他回答：I cannot respond to this request.\n她说：抱歉，我无法处理此请求。"
        #expect(!AIResponseValidation.hasIntroducedRefusal(source, original: source))
        #expect(try AIResponseValidation.validated("```text\n\(source)\n```", original: source, task: .stripAds) == source)
    }

    @Test func manualProofreadingAllowsEditsButNotRefusals() throws {
        #expect(try AIResponseValidation.validated("他走进房间。", original: "他走近房间。", task: .proofread) == "他走进房间。")
        #expect(throws: AIError.self) {
            try AIResponseValidation.validated("I cannot comply with this request.", original: "原文", task: .proofread)
        }
    }

    @Test func assemblyNeverInsertsOneBadChunk() {
        #expect(AutoCleanup.reassemble(chunks: ["第一段", "第二段"],
                                       cleaned: ["第一段", "I cannot Response this request"]) == "")
    }

    @Test func repairsOldCacheOnlyWhenOriginalIsAvailableAndNotRefusal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let bookID = UUID()
        let poisoned = ChapterContent(chapterURL: "bad", text: "正文\nI cannot Response this request", cleaned: true, originalText: "正文\n广告")
        await store.saveContent(poisoned, bookID: bookID)
        let restored = try #require(await store.loadContent(bookID: bookID, chapterURL: "bad"))
        #expect(restored.text == "正文\n广告")
        #expect(!restored.cleaned)
        #expect(restored.originalText == nil)
        #expect(await LibraryStore(directory: directory).loadContent(bookID: bookID, chapterURL: "bad") == restored)
        let dialogue = "他回答：I cannot respond to this request."
        let legitimate = ChapterContent(chapterURL: "dialogue", text: dialogue, cleaned: true, fetchedAt: Date(timeIntervalSince1970: 1800000000), originalText: dialogue + "\n广告")
        await store.saveContent(legitimate, bookID: bookID)
        #expect(await store.loadContent(bookID: bookID, chapterURL: "dialogue") == legitimate)
        let missing = ChapterContent(chapterURL: "missing", text: "I cannot Response this request", cleaned: true, fetchedAt: Date(timeIntervalSince1970: 1800000000))
        await store.saveContent(missing, bookID: bookID)
        #expect(await store.loadContent(bookID: bookID, chapterURL: "missing") == missing)
    }
}
