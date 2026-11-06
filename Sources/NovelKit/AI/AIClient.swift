import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case api(String)
    case emptyResponse
    case decoding(String)
    case truncated(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有配置 AI 服务，请到「设置 → AI 整理」填写接口地址和密钥"
        case .invalidURL(let url): return "AI 接口地址无效：\(url)"
        case .api(let message): return "AI 服务返回错误：\(message)"
        case .emptyResponse: return "AI 没有返回内容"
        case .decoding(let message): return "无法解析 AI 返回结果：\(message)"
        case .truncated(let limit):
            return "AI 输出被截断（上限 \(limit) token），请调大「最大输出」或调小「分块大小」"
        }
    }
}

/// Minimal OpenAI-compatible chat client. Works with OpenAI, DeepSeek, Kimi,
/// GLM, SiliconFlow and any local server that speaks `/v1/chat/completions`.
public struct AIClient {
    public var configuration: AIConfiguration
    private let session: URLSession

    public init(configuration: AIConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout + 30
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func chat(system: String, user: String) async throws -> String {
        try await chat(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ])
    }

    public func chat(messages: [ChatMessage]) async throws -> String {
        guard configuration.isUsable else { throw AIError.notConfigured }
        guard let url = configuration.chatCompletionsURL else { throw AIError.invalidURL(configuration.baseURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AIError.api("HTTP \(http.statusCode) \(message.prefix(300))")
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AIError.decoding("invalid JSON")
        }
        if let error = json["error"]?["message"]?.stringValue {
            throw AIError.api(error)
        }
        guard let content = json["choices"]?[0]?["message"]?["content"]?.stringValue,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.emptyResponse
        }
        // A reply that ran into the output budget is half a chapter. Treating
        // it as success would silently save a chapter with a missing ending.
        if let reason = json["choices"]?[0]?["finish_reason"]?.stringValue, reason == "length" {
            throw AIError.truncated(limit: configuration.maxTokens)
        }
        return content
    }

    // MARK: - Chapter cleanup

    /// Cleans a whole chapter, chunking long chapters so we stay inside the
    /// model's context window. `progress` is reported in 0...1.
    ///
    /// Chunks are sent **concurrently**. Sequentially, a three-chunk chapter
    /// cost three full round trips before a single character came back, and
    /// the wait grew with the chapter. The results are rejoined in order, so
    /// the output is identical — only the waiting is shorter.
    public func cleanChapter(
        _ text: String,
        instruction: AIPrompt.ChapterTask,
        customInstruction: String = "",
        format: AIPrompt.OutputFormat = .paragraphs,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let chunks = AIPrompt.chunk(text, maxLength: configuration.chunkSize)
        guard !chunks.isEmpty else { return text }
        let system = AIPrompt.systemPrompt(for: instruction, custom: customInstruction, format: format)

        // Indexed results, filled as each chunk finishes: order in the reply
        // must be the order of the chapter, not the order of arrival.
        var results = [String?](repeating: nil, count: chunks.count)
        var finished = 0
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    (index, try await chat(system: system, user: chunk))
                }
            }
            for try await (index, answer) in group {
                results[index] = AIPrompt.cleanReply(answer)
                finished += 1
                progress?(Double(finished) / Double(chunks.count))
            }
        }
        let cleaned = results.compactMap { $0 }
        // Chunks are cleaned independently, so the model cannot see paragraph
        // boundaries across a split; re-applying the format here makes the
        // result consistent even when the individual replies disagree.
        let joined: String
        if instruction == .stripAds {
            // A stripped chunk can come back empty (it was nothing but ads).
            // Joining empties with "\n\n" would leave blank blocks behind, so
            // drop them: the chapter simply has one block fewer.
            joined = cleaned.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        } else {
            joined = cleaned.joined(separator: "\n\n")
        }
        return AIPrompt.apply(format, to: joined)
    }
}

public struct ChatMessage: Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum AIPrompt {
    public enum ChapterTask: String, CaseIterable, Identifiable, Sendable {
        case tidy
        case proofread
        case condense
        /// The automatic pass: only removes what does not belong, never rewrites.
        ///
        /// Separate from `tidy` on purpose. `tidy` also re-paragraphs and
        /// deduplicates, which is fine when the user asks for it but too much
        /// for text they never chose to send: an automatic pass that quietly
        /// merges paragraphs makes the whole chapter look wrong, while a stray
        /// ad line is merely annoying.
        case stripAds

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tidy: return "清理排版"
            case .proofread: return "校对纠错"
            case .condense: return "精简去水"
            case .stripAds: return "去广告"
            }
        }

        public var detail: String {
            switch self {
            case .tidy: return "删除广告、站点水印、重复段落，合并被硬换行打断的句子"
            case .proofread: return "在清理基础上修正明显的错别字和标点"
            case .condense: return "在保留剧情的前提下删掉注水内容，篇幅会变短"
            case .stripAds: return "只删广告代码、与剧情无关的废话、章节末尾附加的话语，正文一字不改"
            }
        }

        /// Tasks offered in the reader's manual menu.
        ///
        /// `stripAds` is automatic only: running it by hand on a chapter that
        /// has nothing left to strip would cost an API call to return the same
        /// text.
        public static var manualTasks: [ChapterTask] {
            allCases.filter { $0 != .stripAds }
        }
    }

    /// How the cleaned text should be laid out on screen. Kept separate from
    /// `ChapterTask` because it is a presentation choice, not a content one:
    /// the same cleanup can be rendered with or without paragraph breaks.
    public enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
        /// One paragraph per line — the reader's normal paragraph flow.
        case paragraphs
        /// Keep the model's own line breaks verbatim.
        case original
        /// Join everything into a single flowing block.
        case continuous
        /// Two newlines between paragraphs, for readers that render blank lines.
        case spaced

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .paragraphs: return "按段换行"
            case .original: return "保留原换行"
            case .continuous: return "整段连排"
            case .spaced: return "段间空行"
            }
        }

        public var detail: String {
            switch self {
            case .paragraphs: return "模型给出的每一段占一行，阅读器统一控制段距"
            case .original: return "完全沿用模型输出里的换行位置"
            case .continuous: return "所有段落合并成一整段，适合小屏或快速扫读"
            case .spaced: return "段落之间插入空行，观感更松散"
            }
        }
    }

    /// Applies an `OutputFormat` to cleaned text. Pure string work, so it is
    /// unit tested without the network.
    public static func apply(_ format: OutputFormat, to text: String) -> String {
        switch format {
        case .original:
            // Truly verbatim: keep the model's own line breaks (including blank
            // lines) and only tidy trailing whitespace on each line.
            let lines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        case .paragraphs:
            return normalizedLines(text).joined(separator: "\n")

        case .continuous:
            return normalizedLines(text).joined()

        case .spaced:
            return normalizedLines(text).joined(separator: "\n\n")
        }
    }

    /// Trimmed, non-empty paragraphs of `text`.
    private static func normalizedLines(_ text: String) -> [String] {
        TextProcessing.normalizeParagraphs(text)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func systemPrompt(
        for task: ChapterTask,
        custom: String = "",
        format: OutputFormat = .paragraphs
    ) -> String {
        var prompt = """
        你是一个中文网络小说的文本整理助手。你的任务是清洗从盗版网站抓取下来的章节正文，让它读起来像正常出版/连载的段落。

        必须遵守：
        1. 只输出整理后的正文，不要任何解释、标题、代码块或前后缀。
        2. 删除广告、网址、站点名、求票求收藏、「本章未完请点击下一页」等与剧情无关的内容。
        3. 删除重复出现的段落和明显的乱码、占位符。
        4. 按语义重新分段，每段之间用一个换行。
        5. 不要改写剧情，不要增加原文没有的内容，不要改变人物和对话。
        """

        switch task {
        case .tidy:
            prompt += "\n6. 保留原文用词，只做结构整理。"
        case .proofread:
            prompt += "\n6. 修正明显的错别字、错误的地得、缺失的标点，但不要润色文笔。"
        case .condense:
            prompt += "\n6. 删掉重复叙述和明显注水的段落，可以缩短篇幅，但保留全部关键情节和对话。"
        case .stripAds:
            // Written as an allow-list of what may change: an automatic pass
            // runs on text the user never chose to send, so the model must not
            // "improve" anything it is not certain is junk.
            prompt = """
            你是一个中文网络小说的正文过滤器。用户从盗版网站抓取的章节里混进了广告和站点的自动附加文字，你只负责把这些删掉，正文保持原样。

            只删除下面三类内容：
            1. 广告代码与广告文字：网址、域名、QQ 群号、微信号、公众号名、下载 App 的提示、二维码说明、`<script>` 之类残留标签、「本章由某某网站首发」「更多章节请访问……」等推广语。
            2. 与剧情无关的废话：站点公告、求推荐票 / 收藏 / 月票 / 打赏、更新说明、作者请假或催更回复、无关的读者留言，以及「本站最新网址」「手机阅读请访问」这类穿插在段落中间的干扰句。
            3. 章节末尾附加的无关话语：正文结束后多出来的求票、预告、声明、下章更新时间、站点口号等。

            必须遵守：
            1. 只输出过滤后的正文，不要任何解释、标题、代码块或前后缀。
            2. 除了上述三类，一个字都不要改：不改写、不润色、不合并段落、不调整段落顺序、不修正错别字，保留原有的换行和标点。
            3. 只能整行或整段删除，不能在保留的句子里删掉半句话。某一段里混着广告时，只删掉广告那一行，保留该段其余文字，不要因此改写周围的句子。
            4. 拿不准某句话是不是正文时保留它。宁可留下一条广告，也不要删掉一句剧情或人物名字。
            5. 如果原文里没有上述内容，就原样输出。

            输入说明：为了提速，长章节会被切成多段分别发送，每段之间可能有
            一两段重复，那是上下文重叠，不是原文重复。照常清理即可，
            不要因为重复就删掉段落，也不要补全没有发来的部分。
            """

            // The paragraph rules above would conflict with "do not
            // re-paragraph" for the spaced/continuous formats, so an automatic
            // strip keeps the site's own line breaks.
            return prompt

        }

        switch format {
        case .paragraphs, .original:
            break
        case .continuous:
            prompt += "\n7. 输出时把所有段落合并为连续的一整段，不要在段与段之间换行。"
        case .spaced:
            prompt += "\n7. 段落之间空一行输出（即两个换行）。"
        }

        if !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n额外要求：\(custom)"
        }
        return prompt
    }

    /// The model sometimes wraps the answer in a code fence or adds a preamble.
    public static func cleanReply(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = RegexHelper.replace("(?s)^```[a-zA-Z]*\\n", in: result, with: "")
        result = RegexHelper.replace("(?s)\\n```$", in: result, with: "")
        let prefixes = ["整理后的正文：", "整理后：", "以下是整理后的正文：", "以下是整理后的内容："]
        for prefix in prefixes where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Splits text on paragraph boundaries, keeping chunks under `maxLength`.
    public static func chunk(_ text: String, maxLength: Int) -> [String] {
        let limit = max(maxLength, 300)
        let paragraphs = TextProcessing.normalizeParagraphs(text).components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if paragraph.isEmpty { continue }
            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 1 <= limit {
                current += "\n" + paragraph
            } else {
                chunks.append(current)
                current = paragraph
            }

            // A single oversized paragraph gets hard-split.
            while current.count > limit {
                let cut = current.index(current.startIndex, offsetBy: limit)
                chunks.append(String(current[..<cut]))
                current = String(current[cut...])
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
