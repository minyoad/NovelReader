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

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有配置 AI 服务，请到「设置 → AI 整理」填写接口地址和密钥"
        case .invalidURL(let url): return "AI 接口地址无效：\(url)"
        case .api(let message): return "AI 服务返回错误：\(message)"
        case .emptyResponse: return "AI 没有返回内容"
        case .decoding(let message): return "无法解析 AI 返回结果：\(message)"
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
        return content
    }

    // MARK: - Chapter cleanup

    /// Cleans a whole chapter, chunking long chapters so we stay inside the
    /// model's context window. `progress` is reported in 0...1.
    public func cleanChapter(
        _ text: String,
        instruction: AIPrompt.ChapterTask,
        customInstruction: String = "",
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let chunks = AIPrompt.chunk(text, maxLength: configuration.chunkSize)
        guard !chunks.isEmpty else { return text }

        var results: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let system = AIPrompt.systemPrompt(for: instruction, custom: customInstruction)
            let answer = try await chat(system: system, user: chunk)
            results.append(AIPrompt.cleanReply(answer))
            progress?(Double(index + 1) / Double(chunks.count))
        }
        return results.joined(separator: "\n\n")
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

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tidy: return "清理排版"
            case .proofread: return "校对纠错"
            case .condense: return "精简去水"
            }
        }

        public var detail: String {
            switch self {
            case .tidy: return "删除广告、站点水印、重复段落，合并被硬换行打断的句子"
            case .proofread: return "在清理基础上修正明显的错别字和标点"
            case .condense: return "在保留剧情的前提下删掉注水内容，篇幅会变短"
            }
        }
    }

    public static func systemPrompt(for task: ChapterTask, custom: String = "") -> String {
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
