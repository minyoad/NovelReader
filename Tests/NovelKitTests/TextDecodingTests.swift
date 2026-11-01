import Foundation
import XCTest
@testable import NovelKit

/// `<meta charset=...>` 探测曾经用 `head.lowercased()` 的下标去切 `head`
/// 本身（跨字符串复用 `String.Index`），在设备上稳定触发
/// `EXC_BREAKPOINT` / `PartialRangeFrom.relative(to:)` 断言。
/// 这里用「声明出现在高位字节之后」的样本把当时的下标错配场景固化下来。
final class TextDecodingTests: XCTestCase {
    /// 「汉字」的 GBK 字节。用它来验证 sniff 出来的编码真的被用上了。
    private let hanziGBK: [UInt8] = [0xBA, 0xBA, 0xD7, 0xD6]

    private func gbkPage(declaration: String) -> Data {
        var bytes = Array(declaration.utf8)
        bytes.append(contentsOf: hanziGBK)
        return Data(bytes)
    }

    func testSniffsDoubleQuotedCharset() {
        let data = gbkPage(declaration: "<meta charset=\"gbk\">")
        XCTAssertEqual(TextDecoding.decode(data), "<meta charset=\"gbk\">汉字")
    }

    func testSniffsSingleQuotedCharset() {
        let data = gbkPage(declaration: "<meta charset='gbk'>")
        XCTAssertEqual(TextDecoding.decode(data), "<meta charset='gbk'>汉字")
    }

    func testSniffsUnquotedCharset() {
        let data = gbkPage(declaration: "<meta charset=gbk>")
        XCTAssertEqual(TextDecoding.decode(data), "<meta charset=gbk>汉字")
    }

    func testSniffsCharsetInContentAttribute() {
        let declaration = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=gbk\">"
        let data = gbkPage(declaration: declaration)
        XCTAssertEqual(TextDecoding.decode(data), declaration + "汉字")
    }

    func testNoCharsetDeclarationFallsBackToUTF8() {
        XCTAssertEqual(TextDecoding.decode(Data("没有声明".utf8)), "没有声明")
    }

    /// 关键回归：声明出现在 4096 字节探测窗口的末尾附近。
    /// `data.prefix(4096)` 之后 `head` 被截断，任何对不上号的切片都会在这里暴露。
    func testCharsetNearProbeWindowBoundary() {
        for padding in [4000, 4060, 4080, 4085, 4090, 4096, 4100] {
            let data = gbkPage(declaration: String(repeating: "a", count: padding) + "<meta charset=\"gbk\">")
            XCTAssertEqual(
                TextDecoding.decode(data).hasSuffix("汉字"), true,
                "padding=\(padding) 时没能用上声明的编码"
            )
        }
    }

    /// 回归：`lowercased()` 会改变长度的字符（U+0130 -> "i" + U+0307）。
    /// 它们出现在声明之前时，旧实现里 `lower` 的 upperBound 会越过 `head.endIndex`。
    func testExpandingLowercaseCharactersBeforeDeclaration() {
        for scalars in [[0x0130], [0x023A], [0x023E]] {
            let filler = scalars.compactMap { Unicode.Scalar($0) }.map(String.init).joined()
            let data = gbkPage(declaration: String(repeating: filler, count: 200) + "<meta charset=\"gbk\">")
            XCTAssertTrue(TextDecoding.decode(data).hasSuffix("汉字"))
        }
    }

    /// 回归：Latin-1 高位字节（`.isoLatin1` 解码后落在 U+0080–U+00FF）。
    /// 旧实现的崩溃样本正是这类页面上带 charset 声明。
    func testHighLatin1BytesBeforeDeclaration() {
        var bytes: [UInt8] = []
        for _ in 0..<500 { bytes.append(contentsOf: [0xC0, 0xE9, 0xFF, 0x80]) }
        bytes.append(contentsOf: Array("<meta charset=\"gbk\">".utf8))
        bytes.append(contentsOf: hanziGBK)
        XCTAssertNoThrow(TextDecoding.decode(Data(bytes)))
    }

    /// 任意 Latin-1 字节流都不应该让解码崩掉。
    func testArbitraryLatin1BytesNeverCrash() {
        var seed: UInt64 = 0x5EED_1234
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }
        for _ in 0..<200 {
            var bytes = [UInt8]()
            let count = Int(next() % 5_000)
            for _ in 0..<count { bytes.append(UInt8(next() % 256)) }
            if count > 64, next() % 2 == 0 {
                let insert = Int(next() % UInt64(count - 32))
                bytes.insert(contentsOf: Array("charset=gbk".utf8), at: insert)
            }
            XCTAssertNoThrow(TextDecoding.decode(Data(bytes)))
        }
    }

    func testExplicitCharsetParameterWins() {
        XCTAssertEqual(TextDecoding.decode(Data(hanziGBK), declaredCharset: "gb18030"), "汉字")
    }

    func testContentTypeCharsetIsHonoured() {
        XCTAssertEqual(
            TextDecoding.decode(Data(hanziGBK), contentType: "text/html; charset=GBK"),
            "汉字"
        )
    }

    func testBOMStripsBOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("汉字".utf8)
        XCTAssertEqual(TextDecoding.decode(data), "汉字")
    }
}
