import Foundation

public enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case paper
    case sepia
    case night
    case black

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .paper: return "纸白"
        case .sepia: return "米黄"
        case .night: return "深灰"
        case .black: return "纯黑"
        }
    }
}

/// How the reader advances: continuous scrolling, or discrete pages swiped
/// horizontally.
public enum PageTurnMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case scroll
    case page

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .scroll: return "滚动"
        case .page: return "左右翻页"
        }
    }
}

/// Animation used when a page is turned. Only meaningful in `.page` mode.
public enum PageTurnEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case slide
    case fade
    case curl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .slide: return "覆盖"
        case .fade: return "淡入"
        case .curl: return "仿真"
        }
    }
}

public struct ReadingSettings: Codable, Hashable, Sendable {
    public var fontSize: Double
    public var lineSpacing: Double
    public var paragraphSpacing: Double
    public var horizontalPadding: Double
    public var theme: ReaderTheme
    /// `nil` means the system font.
    public var fontFamily: String?
    public var pageTurnMode: PageTurnMode
    public var pageTurnEffect: PageTurnEffect

    public init(
        fontSize: Double = 19,
        lineSpacing: Double = 8,
        paragraphSpacing: Double = 12,
        horizontalPadding: Double = 20,
        theme: ReaderTheme = .paper,
        fontFamily: String? = nil,
        pageTurnMode: PageTurnMode = .page,
        pageTurnEffect: PageTurnEffect = .slide
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.horizontalPadding = horizontalPadding
        self.theme = theme
        self.fontFamily = fontFamily
        self.pageTurnMode = pageTurnMode
        self.pageTurnEffect = pageTurnEffect
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize
        case lineSpacing
        case paragraphSpacing
        case horizontalPadding
        case theme
        case fontFamily
        case pageTurnMode
        case pageTurnEffect
    }

    /// Tolerant decoding: settings written before pagination existed have no
    /// page-turn keys, and should keep their values instead of resetting the
    /// whole `AppSettings` blob.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReadingSettings()
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        lineSpacing = try container.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? defaults.lineSpacing
        paragraphSpacing = try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? defaults.paragraphSpacing
        horizontalPadding = try container.decodeIfPresent(Double.self, forKey: .horizontalPadding) ?? defaults.horizontalPadding
        theme = try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? defaults.theme
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        pageTurnMode = try container.decodeIfPresent(PageTurnMode.self, forKey: .pageTurnMode) ?? defaults.pageTurnMode
        pageTurnEffect = try container.decodeIfPresent(PageTurnEffect.self, forKey: .pageTurnEffect) ?? defaults.pageTurnEffect
    }
}

public struct TTSSettings: Codable, Hashable, Sendable {
    public var rate: Double
    public var pitch: Double
    public var volume: Double
    public var voiceIdentifier: String?
    public var voiceName: String?
    public var autoNextChapter: Bool
    public var sentencePause: Double

    public init(
        rate: Double = 0.5,
        pitch: Double = 1.0,
        volume: Double = 1.0,
        voiceIdentifier: String? = nil,
        voiceName: String? = nil,
        autoNextChapter: Bool = true,
        sentencePause: Double = 0.15
    ) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.voiceIdentifier = voiceIdentifier
        self.voiceName = voiceName
        self.autoNextChapter = autoNextChapter
        self.sentencePause = sentencePause
    }
}

public struct NetworkSettings: Codable, Hashable, Sendable {
    public var userAgent: String
    public var timeout: Double
    public var useCookies: Bool

    public init(
        userAgent: String = NetworkSettings.defaultUserAgent,
        timeout: Double = 20,
        useCookies: Bool = true
    ) {
        self.userAgent = userAgent
        self.timeout = timeout
        self.useCookies = useCookies
    }

    public static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
}

public enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai
    case deepseek
    case moonshot
    case zhipu
    case siliconflow
    case ollama
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "月之暗面 Kimi"
        case .zhipu: return "智谱 GLM"
        case .siliconflow: return "SiliconFlow"
        case .ollama: return "Ollama（本地）"
        case .custom: return "自定义"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .deepseek: return "deepseek-chat"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .ollama: return "qwen2.5:7b"
        case .custom: return ""
        }
    }

    public var needsAPIKey: Bool {
        self != .ollama
    }
}

public struct AIConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var preset: AIProviderPreset
    public var baseURL: String
    public var model: String
    public var temperature: Double
    public var maxTokens: Int
    /// Key is persisted separately (Keychain) by the app layer; this copy is only used at runtime.
    public var apiKey: String
    public var chunkSize: Int
    public var timeout: Double
    /// Extra instruction appended to every cleanup prompt.
    public var customInstruction: String

    public init(
        enabled: Bool = false,
        preset: AIProviderPreset = .deepseek,
        baseURL: String = "",
        model: String = "",
        temperature: Double = 0.2,
        maxTokens: Int = 2048,
        apiKey: String = "",
        chunkSize: Int = 1800,
        timeout: Double = 90,
        customInstruction: String = ""
    ) {
        self.enabled = enabled
        self.preset = preset
        self.baseURL = baseURL.isEmpty ? preset.defaultBaseURL : baseURL
        self.model = model.isEmpty ? preset.defaultModel : model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.apiKey = apiKey
        self.chunkSize = chunkSize
        self.timeout = timeout
        self.customInstruction = customInstruction
    }

    public var isUsable: Bool {
        enabled && !baseURL.isEmpty && !model.isEmpty && (!preset.needsAPIKey || !apiKey.isEmpty)
    }

    public var chatCompletionsURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("/chat/completions") { return URL(string: text) }
        return URL(string: text + "/chat/completions")
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var reading: ReadingSettings
    public var tts: TTSSettings
    public var network: NetworkSettings
    public var ai: AIConfiguration
    /// Search all enabled sources at once; false means "pick one".
    public var searchAllSources: Bool

    public init(
        reading: ReadingSettings = ReadingSettings(),
        tts: TTSSettings = TTSSettings(),
        network: NetworkSettings = NetworkSettings(),
        ai: AIConfiguration = AIConfiguration(),
        searchAllSources: Bool = true
    ) {
        self.reading = reading
        self.tts = tts
        self.network = network
        self.ai = ai
        self.searchAllSources = searchAllSources
    }
}
