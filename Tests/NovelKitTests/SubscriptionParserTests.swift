import Testing
import Foundation
@testable import NovelKit

@Suite("书源订阅：解析")
struct SubscriptionParserTests {

    static let singleSource = """
    {
      "bookSourceName": "示例站",
      "bookSourceUrl": "https://example.com",
      "searchUrl": "https://example.com/search?q={{key}}",
      "ruleSearch": { "bookList": ".item", "name": ".title", "bookUrl": "a@href" }
    }
    """

    static let arrayJSON = "[\(singleSource)]"

    @Test("legado 裸数组")
    func bareArray() throws {
        let found = try SubscriptionParser.parse(Data(Self.arrayJSON.utf8))
        #expect(found.sources.count == 1)
        #expect(found.sources[0].name == "示例站")
        #expect(found.followUp == nil)
        #expect(found.location == .root)
    }

    @Test("包在 data 里的数组")
    func dataWrapper() throws {
        let json = #"{"data": \#(Self.arrayJSON)}"#
        let found = try SubscriptionParser.parse(Data(json.utf8))
        #expect(found.sources.count == 1)
        #expect(found.location == .key("data"))
    }

    @Test("合集页常见形状：books 键")
    func booksKey() throws {
        let json = #"{"books": \#(Self.arrayJSON)}"#
        let found = try SubscriptionParser.parse(Data(json.utf8))
        #expect(found.sources.count == 1)
        #expect(found.location == .key("books"))
    }

    @Test("未知键名也能找到数组")
    func unknownKey() throws {
        let json = #"{"whatever": \#(Self.arrayJSON)}"#
        let found = try SubscriptionParser.parse(Data(json.utf8))
        #expect(found.sources.count == 1)
    }

    @Test("只给链接的合集页：返回跟随地址")
    func linkWrapper() throws {
        let json = #"{"links": [{"url": "https://cdn.example.com/sources.json"}]}"#
        let found = try SubscriptionParser.parse(Data(json.utf8))
        #expect(found.sources.isEmpty)
        #expect(found.followUp?.absoluteString == "https://cdn.example.com/sources.json")
    }

    @Test("顶层 url 字段")
    func topLevelURL() throws {
        let json = #"{"title": "某合集", "url": "https://example.com/list.json"}"#
        let found = try SubscriptionParser.parse(Data(json.utf8))
        #expect(found.followUp?.absoluteString == "https://example.com/list.json")
    }

    @Test("不是 JSON 时报明确错误")
    func notJSON() {
        #expect(throws: SubscriptionError.self) {
            try SubscriptionParser.parse(Data("<html>404</html>".utf8))
        }
    }

    @Test("能解析 JSON 但里面没有书源")
    func noSources() {
        #expect(throws: SubscriptionError.self) {
            try SubscriptionParser.parse(Data(#"{"code": 0, "msg": "ok"}"#.utf8))
        }
    }

    @Test("空数组不算有效订阅")
    func emptyArray() {
        #expect(throws: SubscriptionError.self) {
            try SubscriptionParser.parse(Data("[]".utf8))
        }
    }

    @Test("记住的键不存在时，退回到通用查找")
    func fallbackFromStaleKey() throws {
        let json = #"{"data": \#(Self.arrayJSON)}"#
        let found = try SubscriptionParser.parse(Data(json.utf8), expectingKey: "books")
        #expect(found.sources.count == 1)
        #expect(found.location == .key("data"))
    }

    @Test("记住的键还在时直接使用")
    func usesExpectedKey() throws {
        let json = #"{"books": \#(Self.arrayJSON)}"#
        let found = try SubscriptionParser.parse(Data(json.utf8), expectingKey: "books")
        #expect(found.location == .key("books"))
    }
}
