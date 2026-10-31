import Foundation

/// Which speech engine reads a chapter aloud.
public enum TTSEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `AVSpeechSynthesizer`. Offline, zero setup, but robotic on long prose.
    case system
    /// Microsoft's Edge read-aloud service. Free, no key, but needs the network
    /// and is an unofficial endpoint.
    case edge
    /// Any OpenAI-compatible `/audio/speech` endpoint, including local ones.
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "系统朗读"
        case .edge: return "Edge 在线（推荐）"
        case .openAICompatible: return "自定义接口"
        }
    }

    public var detail: String {
        switch self {
        case .system:
            return "iOS 内置语音，完全离线、没有延迟，但长句听起来机械。可在系统「辅助功能 → 朗读内容」里下载更好的中文语音。"
        case .edge:
            return "微软 Edge 的朗读音色，自然度接近真人，免费且无需注册。需要联网，属于未公开接口，可能随时失效。"
        case .openAICompatible:
            return "任何兼容 OpenAI /audio/speech 的服务，可以指向本地部署的模型。需要自行填写地址、音色和密钥。"
        }
    }

    /// Whether audio has to be fetched before it can be played.
    public var needsNetwork: Bool { self != .system }
}

/// Settings for the remote engines.
public struct RemoteTTSSettings: Codable, Hashable, Sendable {
    /// Edge voice short name, e.g. `zh-CN-YunxiNeural`.
    public var edgeVoice: String
    /// Base URL of an OpenAI-compatible server, without the trailing path.
    public var baseURL: String
    /// Model name for the `/audio/speech` request.
    public var model: String
    /// Voice name passed through to the server.
    public var voice: String
    public var apiKey: String

    public init(
        edgeVoice: String = "zh-CN-YunxiNeural",
        baseURL: String = "",
        model: String = "",
        voice: String = "alloy",
        apiKey: String = ""
    ) {
        self.edgeVoice = edgeVoice
        self.baseURL = baseURL
        self.model = model
        self.voice = voice
        self.apiKey = apiKey
    }

    public var speechURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("/audio/speech") { return URL(string: text) }
        if text.hasSuffix("/v1") { return URL(string: text + "/audio/speech") }
        return URL(string: text + "/v1/audio/speech")
    }

    private enum CodingKeys: String, CodingKey {
        case edgeVoice, baseURL, model, voice, apiKey
    }

    /// Tolerant decoding so adding a field never wipes the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RemoteTTSSettings()
        edgeVoice = try container.decodeIfPresent(String.self, forKey: .edgeVoice) ?? defaults.edgeVoice
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? defaults.voice
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
    }
}

/// A voice offered by a remote engine, for the settings picker.
public struct TTSVoiceOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// The Edge voices worth offering. This is the full set of mainland and
/// dialect Chinese voices the service exposes; fetching the live list is also
/// supported, but a built-in list means the picker works before the first
/// network call and keeps the settings screen usable offline.
public enum EdgeVoiceCatalog {
    public static let chinese: [TTSVoiceOption] = [
        TTSVoiceOption(id: "zh-CN-YunxiNeural", name: "云希 · 男声", detail: "活泼阳光，长篇小说最耐用"),
        TTSVoiceOption(id: "zh-CN-YunjianNeural", name: "云健 · 男声", detail: "激昂，适合热血、体育"),
        TTSVoiceOption(id: "zh-CN-YunyangNeural", name: "云扬 · 男声", detail: "专业沉稳，适合旁白"),
        TTSVoiceOption(id: "zh-CN-YunxiaNeural", name: "云夏 · 男声", detail: "可爱，适合轻小说"),
        TTSVoiceOption(id: "zh-CN-XiaoxiaoNeural", name: "晓晓 · 女声", detail: "温柔，适合言情、都市"),
        TTSVoiceOption(id: "zh-CN-XiaoyiNeural", name: "晓伊 · 女声", detail: "活泼，适合故事"),
        TTSVoiceOption(id: "zh-CN-liaoning-XiaobeiNeural", name: "小北 · 东北话", detail: "幽默"),
        TTSVoiceOption(id: "zh-CN-shaanxi-XiaoniNeural", name: "小妮 · 陕西话", detail: "明快"),
        TTSVoiceOption(id: "zh-HK-HiuMaanNeural", name: "曉曼 · 粤语女声", detail: "亲切"),
        TTSVoiceOption(id: "zh-HK-WanLungNeural", name: "雲龍 · 粤语男声", detail: "亲切"),
        TTSVoiceOption(id: "zh-TW-HsiaoChenNeural", name: "曉臻 · 台湾女声", detail: "亲切"),
        TTSVoiceOption(id: "zh-TW-YunJheNeural", name: "雲哲 · 台湾男声", detail: "亲切"),
    ]

    public static func name(for id: String) -> String {
        chinese.first { $0.id == id }?.name ?? id
    }
}
