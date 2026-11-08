import Testing
import Foundation
@testable import NovelKit

/// The remote file in the wild had one extra `}` on the end. Every book was
/// intact, but the whole sync refused to run.
@Suite("Tolerating a damaged remote file")
struct SyncDamagedFileTests {

    private func samplePayload() throws -> Data {
        let book = Book(
            sourceID: UUID(),
            sourceName: "源",
            detailURL: "https://example.com/1",
            name: "书",
            progress: ReadingProgress(chapterIndex: 3, updatedAt: Date(timeIntervalSince1970: 100))
        )
        let payload = SyncPayload(deviceID: "A", books: [book], sources: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    @Test("a trailing brace is trimmed and the payload survives")
    func trailingBrace() throws {
        var data = try samplePayload()
        data.append(UInt8(ascii: "}"))

        // Plain decoding fails, which is what the app reported.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect((try? decoder.decode(SyncPayload.self, from: data)) == nil)

        // The tolerant path keeps all the data.
        let payload = try SyncService.decodeForPreview(data)
        #expect(payload.books.count == 1)
        #expect(payload.books.first?.progress.chapterIndex == 3)
    }

    @Test("trailing whitespace and newlines are tolerated")
    func trailingWhitespace() throws {
        var data = try samplePayload()
        data.append(contentsOf: Data("\n}\n\n".utf8))
        let payload = try SyncService.decodeForPreview(data)
        #expect(payload.books.count == 1)
    }

    @Test("a brace inside a string does not end the object early")
    func braceInsideString() throws {
        // The brace counter must respect string literals, otherwise a book
        // whose title contains `}` would be cut in half.
        let book = Book(
            sourceID: UUID(),
            sourceName: "源",
            detailURL: "https://example.com/1",
            name: "书名里有 } 和 \" 引号",
            intro: "还有 \\ 反斜杠",
            progress: ReadingProgress(chapterIndex: 1, updatedAt: Date(timeIntervalSince1970: 5))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(SyncPayload(deviceID: "A", books: [book], sources: []))
        data.append(UInt8(ascii: "}"))

        let payload = try SyncService.decodeForPreview(data)
        #expect(payload.books.first?.name == "书名里有 } 和 \" 引号")
        #expect(payload.books.first?.intro == "还有 \\ 反斜杠")
    }

    @Test("a file that is not JSON at all still fails")
    func htmlStillFails() {
        // An HTML error page must not be mistaken for an empty sync state, or
        // the upload would wipe whatever is on the server.
        let data = Data("<!DOCTYPE html><html>error</html>".utf8)
        #expect(throws: (any Error).self) {
            _ = try SyncService.decodeForPreview(data)
        }
    }

    @Test("a newer version is still refused even when trimmed")
    func versionStillChecked() throws {
        let payload = SyncPayload(version: 99, deviceID: "X", books: [], sources: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(payload)
        data.append(UInt8(ascii: "}"))

        do {
            _ = try SyncService.decodeForPreview(data)
            Issue.record("应当拒绝更新版本")
        } catch let error as SyncError {
            guard case .unsupportedVersion(99) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }

    @Test("trimToFirstValue returns nil for non-object input")
    func trimRequiresObject() {
        #expect(SyncService.trimToFirstValue(Data("[1,2]".utf8)) == nil)
        #expect(SyncService.trimToFirstValue(Data("{".utf8)) == nil)
        #expect(SyncService.trimToFirstValue(Data("{\"a\":1}".utf8)) != nil)
    }
}
