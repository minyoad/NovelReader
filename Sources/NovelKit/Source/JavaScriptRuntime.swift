import Foundation
#if canImport(CNovelJavaScript)
import CNovelJavaScript
#endif

public enum JavaScriptRuleError: LocalizedError {
    case unavailable
    case invalidRule(String)
    case execution(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "当前平台未提供 JavaScript 执行引擎"
        case .invalidRule(let message): return "JS 规则格式错误：\(message)"
        case .execution(let message): return "JS 规则执行失败：\(message)"
        case .timeout: return "JS 规则执行超时，已中断"
        }
    }
}

/// Each evaluation is isolated and discarded synchronously, including on a
/// timeout. No native object, DOM, network, storage or filesystem bridge exists.
public enum JavaScriptRuntime {
    public static var isAvailable: Bool {
        #if canImport(CNovelJavaScript)
        return true
        #else
        return false
        #endif
    }

    public static func evaluate(
        _ script: String, result: JSONValue, baseURL: URL? = nil,
        variables: [String: String] = [:], timeoutMilliseconds: UInt32 = 250
    ) throws -> JSONValue {
        guard !script.utf8.contains(0) else { throw JavaScriptRuleError.invalidRule("脚本包含空字符") }
        let reserved = Set(["__proto__", "prototype", "constructor", "globalThis", "eval", "Function",
                            "undefined", "NaN", "Infinity", "result", "baseUrl", "baseURL", "url"])
        var globals = variables.filter { !reserved.contains($0.key) }.mapValues(JSONValue.string)
        globals["page"] = .int(variables["page"].flatMap(Int.init) ?? 1)
        globals["result"] = result
        globals["baseUrl"] = .string(baseURL?.absoluteString ?? "")
        globals["baseURL"] = globals["baseUrl"]
        globals["url"] = globals["baseUrl"]
        globals["key"] = .string(variables["key"] ?? "")
        globals["variables"] = .object(variables.mapValues(JSONValue.string))
        let input = JSONValue.object(globals).jsonText
        #if canImport(CNovelJavaScript)
        let response = script.withCString { code in
            input.withCString { context in NRJSEvaluate(code, context, min(max(timeoutMilliseconds, 1), 1000)) }
        }
        defer { NRJSFree(response) }
        if response.timed_out != 0 { throw JavaScriptRuleError.timeout }
        if let error = response.error { throw JavaScriptRuleError.execution(String(cString: error)) }
        guard let output = response.json,
              let data = String(cString: output).data(using: .utf8) else {
            throw JavaScriptRuleError.execution("没有可读取的返回值")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
        #else
        throw JavaScriptRuleError.unavailable
        #endif
    }
}
