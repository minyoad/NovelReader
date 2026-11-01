import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Turns raw HTTP bodies into strings, dealing with the character sets that
/// Chinese novel sites actually use (UTF-8, GBK/GB18030, Big5).
public enum TextDecoding {
    public static let gb18030: String.Encoding = {
        #if canImport(CoreFoundation)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        #else
        return .utf8
        #endif
    }()

    public static let big5: String.Encoding = {
        #if canImport(CoreFoundation)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0A03)))
        #else
        return .utf8
        #endif
    }()

    public static func decode(_ data: Data, contentType: String? = nil, declaredCharset: String? = nil) -> String {
        if data.isEmpty { return "" }

        // 1. BOM
        if let bom = decodeUsingBOM(data) { return bom }

        // 2. Explicit charset (source config / Content-Type header)
        var candidates: [String.Encoding] = []
        if let declaredCharset, let encoding = encoding(forName: declaredCharset) {
            candidates.append(encoding)
        }
        if let contentType, let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            let name = contentType[range.upperBound...]
                .split(separator: ";").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if let name, let encoding = encoding(forName: name) {
                candidates.append(encoding)
            }
        }

        // 3. Sniff <meta charset=...> in the first few KB
        let head = data.prefix(4096)
        if let headString = String(data: head, encoding: .isoLatin1),
           let sniffed = sniffMetaCharset(headString),
           let encoding = encoding(forName: sniffed) {
            candidates.append(encoding)
        }

        // 4. Reasonable defaults
        candidates.append(.utf8)
        candidates.append(gb18030)
        candidates.append(big5)
        candidates.append(.isoLatin1)

        var seen = Set<String.Encoding.RawValue>()
        for encoding in candidates where seen.insert(encoding.rawValue).inserted {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func encoding(forName name: String) -> String.Encoding? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb-2312", "gb18030", "gb-18030", "cp936", "x-gbk": return gb18030
        case "big5", "big-5", "cp950": return big5
        case "iso-8859-1", "latin1": return .isoLatin1
        case "utf-16", "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        default: return nil
        }
    }

    private static func decodeUsingBOM(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// `<meta charset=...>` / `content="text/html; charset=..."` 的探测。
    ///
    /// 匹配与取值都在同一个 `String` 上完成。曾经的写法是
    /// `let range = head.lowercased().range(of: marker)` 然后 `head[range.upperBound...]`，
    /// 这等于把 `lower` 的 `String.Index` 拿去索引 `head`。`String.Index` 只在
    /// 生成它的那个字符串里有效：`head` 来自 `.isoLatin1` 解码（可能由 NSString
    /// 支撑、按 UTF-16 偏移编码索引），`lowercased()` 的结果则是原生字符串（按
    /// UTF-8 偏移）。两者一旦存储方式不同，同一个 Index 的数值含义就不同，
    /// 越界后 `PartialRangeFrom.relative(to:)` 触发 precondition（EXC_BREAKPOINT）。
    private static func sniffMetaCharset(_ head: String) -> String? {
        guard let regex = RegexHelper.regex(
            // "charset" [空白] "=" [空白] [引号] 值
            "charset\\s*=\\s*[\"']?([^\"' >;\\r\\n]+)",
            options: [.caseInsensitive]
        ) else { return nil }

        let source = head as NSString
        let full = NSRange(location: 0, length: source.length)
        for match in regex.matches(in: head, range: full) {
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { continue }
            let value = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }
}
