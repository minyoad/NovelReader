import Foundation
import Testing
@testable import NovelKit

@Suite("Basic JavaScript source rules", .serialized)
struct JavaScriptRuleTests {
    private let engine = RuleEngine(variables: ["key": "长夜", "page": "2"])
    private let text = RuleScope(payload: .text("广告正文##尾声"), baseURL: URL(string: "https://example.com/read/1"))

    @Test("Pure JS and selector transforms use the previous result")
    func transformations() {
        #expect(engine.value("@js:result.replace('广告','')", in: text) == "正文##尾声")
        let html = RuleScope.html("<head><script>head-marker</script></head><body><p id='content'>广告正文</p></body>", baseURL: text.baseURL)
        #expect(engine.value("#content@text<js>result.replace('广告','')</js>", in: html) == "正文")
        #expect(engine.value("@js:result.includes('head-marker')", in: html) == "true")
    }

    @Test("JS operators and literal delimiters remain inside the script")
    func protectedOperators() {
        #expect(engine.value("<js>result && result.includes('##') ? 'ok||@@' : '';</js>##ok##done", in: text) == "done||@@")
        #expect(engine.value("@js: 'left' || 'right'", in: text) == "left")
        #expect(engine.value("<js>''</js>||@text", in: text) == "广告正文##尾声")
        #expect(engine.value("<js>null</js>@@@text", in: text) == "广告正文##尾声")
        #expect(engine.value("<js>'一'</js>&&<js>'二'</js>", in: text) == "一二")
        #expect(engine.value("<js>'广告'</js><js>result + '正文'</js>", in: text) == "广告正文")
        #expect(engine.values("<js>[1]</js><js>result.map(x => x + 1)</js>", in: text) == ["2"])
        #expect(engine.values("<js>[]</js><js>result.concat(['first'])</js>", in: text) == ["first"])
    }

    @Test("Tagged strings, templates, comments and regexes may contain delimiters")
    func taggedLiterals() {
        #expect(engine.value(#"<js>'</js>||##'</js>"#, in: text) == "</js>||##")
        #expect(engine.value(#"<js>`before</js>after`</js>"#, in: text) == "before</js>after")
        #expect(engine.value(#"<js>`outer${`inner</js>`}`</js>"#, in: text) == "outerinner</js>")
        #expect(engine.value(#"<js>/* </js> */ 'ok';</js>"#, in: text) == "ok")
        #expect(engine.value(#"<js>result.replace(/广告|##/g, '')</js>"#, in: text) == "正文尾声")
    }

    @Test("Arrays and objects remain usable as list-item scopes")
    func objectLists() throws {
        let raw = #"{"chapters":[{"name":"第一章","url":"/1"},{"name":"第二章","url":"/2"}]}"#
        let scope = RuleScope(payload: .text(raw), baseURL: text.baseURL)
        let items = engine.scopes(for: "@js:JSON.parse(result).chapters", in: scope)
        #expect(items.count == 2)
        #expect(items.map { engine.value("$.name", in: $0) } == ["第一章", "第二章"])
        #expect(engine.value("@js:baseUrl + result.url", in: items[0]) == "https://example.com/read/1/1")
        #expect(engine.values("@js:['a', 'b', null]", in: text) == ["a", "b"])
        #expect(engine.value("<js>JSON.stringify({value:'parsed'})</js>$.value", in: text) == "parsed")
        #expect(engine.scopes(for: "@text<js>JSON.parse(result).chapters</js>", in: scope).count == 2)
        #expect(engine.scopes(for: "<js>['first', 'middle', 'last']</js>!0:-1", in: text).map(\.plainText) == ["middle"])
        let encoded = try #require(engine.value("@js:({name:'正文', count:2})", in: text))
        let object = try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8))
        #expect(object["name"]?.stringValue == "正文")
        #expect(object["count"]?.intValue == 2)
    }

    @Test("Injected variables are data, page is numeric and contexts do not leak")
    func globals() throws {
        #expect(engine.value("@js:key + ':' + (page + 1) + ':' + baseUrl", in: text) == "长夜:3:https://example.com/read/1")
        #expect(try JavaScriptRuntime.evaluate("page", result: .null) == .int(1))
        let attack = "'); throw new Error('injected'); //"
        let value = try JavaScriptRuntime.evaluate("key", result: .null, variables: ["key": attack])
        #expect(value == .string(attack))
        _ = try JavaScriptRuntime.evaluate("globalThis.previous = 42", result: .null)
        #expect(try JavaScriptRuntime.evaluate("typeof previous", result: .null) == .string("undefined"))
        #expect(try JavaScriptRuntime.evaluate("typeof java + ':' + typeof fetch + ':' + typeof require", result: .null) == .string("undefined:undefined:undefined"))
    }

    @Test("Concurrent source evaluations keep their contexts separate")
    func concurrentSources() async throws {
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let value = try JavaScriptRuntime.evaluate("key + result", result: .string("!"), variables: ["key": String(index)])
                    return value.stringValue ?? ""
                }
            }
            var results: [String] = []
            for try await value in group { results.append(value) }
            return results
        }
        #expect(Set(results) == Set((0..<12).map { "\($0)!" }))
    }

    @Test("Explicit return and ordinary completion values both work")
    func returns() {
        #expect(engine.value("@js:return result.replace('广告','');", in: text) == "正文##尾声")
        #expect(engine.value("@js:function transform(x){ return x + '!'; } transform(key)", in: text) == "长夜!")
        #expect(engine.value("@js:false", in: text) == "false")
        #expect(engine.value("@js:undefined", in: text) == nil)
    }

    @Test("Errors are visible and never return untransformed input")
    func errorsAndFallback() {
        var warnings: [String] = []
        let engine = RuleEngine(onWarning: { warnings.append($0) })
        #expect(engine.value("@text<js>java.ajax(baseUrl)</js>", in: text) == nil)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("JS 规则执行失败"))
        #expect(engine.value("<js>throw new Error('bad')</js>||@text", in: text) == "广告正文##尾声")
        #expect(engine.value("<js>result", in: text) == nil)
        #expect(warnings.last?.contains("缺少 </js>") == true)
        let deepTemplate = "<js>" + String(repeating: "`${", count: 100) + "0"
            + String(repeating: "}`", count: 100) + "</js>"
        #expect(engine.value(deepTemplate, in: text) == nil)
        let literal = RuleScope.html("<p data-note='&lt;js&gt;'>文本</p>", baseURL: nil)
        #expect(engine.value("p[data-note='<js>']@text", in: literal) == "文本")
    }

    @Test("Timeout, stack and memory limits stop bad scripts and the next request still works")
    func resourceLimits() throws {
        do {
            _ = try JavaScriptRuntime.evaluate("while (true) {}", result: .null, timeoutMilliseconds: 20)
            Issue.record("An infinite loop must be interrupted")
        } catch JavaScriptRuleError.timeout { /* expected */ }
        #expect(throws: (any Error).self) {
            _ = try JavaScriptRuntime.evaluate("new Uint8Array(64 * 1024 * 1024)", result: .null)
        }
        #expect(throws: (any Error).self) {
            _ = try JavaScriptRuntime.evaluate("function recurse(){return recurse()} recurse()", result: .null)
        }
        #expect(throws: (any Error).self) {
            _ = try JavaScriptRuntime.evaluate("Promise.resolve('not-supported')", result: .null)
        }
        #expect(throws: (any Error).self) {
            _ = try JavaScriptRuntime.evaluate("Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0)", result: .null)
        }
        #expect(try JavaScriptRuntime.evaluate("1 + 2", result: .null) == .int(3))
    }

    @Test("A timed-out rule is not re-run for each item in the same response")
    func timeoutQuarantine() {
        var warnings: [String] = []
        let engine = RuleEngine(onWarning: { warnings.append($0) })
        #expect(engine.value("@js:while(true) {}", in: text) == nil)
        #expect(engine.value("@js:while(true) {}", in: text) == nil)
        #expect(warnings.first?.contains("已中断") == true)
        #expect(warnings.last?.contains("不再重复执行") == true)
        #expect(engine.value("@js:'still works'", in: text) == "still works")
    }

    @Test("Pure JS is compatible while missing host APIs remain marked")
    func compatibility() {
        var source = BookSource(name: "基础 JS", baseURL: "https://example.com")
        source.search.bookList = "@js:JSON.parse(result).books"
        #expect(source.compatibility.level == .supported)
        #expect(source.compatibility.hasJavaScript)
        #expect(source.compatibility.unsupportedRoles.isEmpty)
        source.search.bookList = "@js:java.getElements('li')"
        #expect(source.compatibility.level == .unreadable)
        #expect(source.compatibility.unsupportedFeatures.contains("java"))
        source.search.bookList = #"<js>({java: 'java.ajax'})</js>"#
        #expect(source.compatibility.level == .supported)
        source.search.bookList = #"<js>`${java.ajax(baseUrl)}`</js>"#
        #expect(source.compatibility.level == .unreadable)
    }
}
