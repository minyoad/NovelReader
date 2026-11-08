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

    /// Whether the interface around the text should also go dark.
    ///
    /// The reader draws its own paper and ink, so the chrome has to be told
    /// separately: without this the top bar, the sheets and the status bar keep
    /// following the system appearance, which leaves a light toolbar sitting on
    /// a dark page.
    public var isDark: Bool {
        switch self {
        case .paper, .sepia: return false
        case .night, .black: return true
        }
    }

    /// This theme's twin in the other appearance family.
    ///
    /// Used by "follow system": the phone's light/dark switch picks the family
    /// while the user's choice picks the variant within it. Defined once here
    /// so the resolver and the settings row that explains it cannot drift.
    public var darkCounterpart: ReaderTheme {
        isDark ? self : .night
    }

    public var lightCounterpart: ReaderTheme {
        isDark ? .paper : self
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

/// Horizontal alignment of body paragraphs. Chinese prose reads best justified;
/// a ragged-right option helps when a book has mixed Latin text.
public enum BodyAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case justify
    case leading

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .justify: return "两端对齐"
        case .leading: return "左对齐"
        }
    }
}

public struct ReadingSettings: Codable, Hashable, Sendable {
    public var fontSize: Double
    public var lineSpacing: Double
    public var paragraphSpacing: Double
    public var horizontalPadding: Double
    public var theme: ReaderTheme
    /// PostScript / family name of the body font; `nil` means the system serif.
    public var fontFamily: String?
    public var pageTurnMode: PageTurnMode
    public var pageTurnEffect: PageTurnEffect
    /// Indent the first line of every paragraph by two characters, the usual
    /// convention for Chinese prose.
    public var firstLineIndent: Bool
    public var alignment: BodyAlignment
    /// Follow the phone's light/dark switch instead of using `theme`.
    ///
    /// On by default: a reader who never opens the settings still expects the
    /// app to go dark at night. `theme` is kept so switching this off returns to
    /// the paper the user picked, rather than to a default.
    public var followSystemAppearance: Bool
    /// Reopen the last book at its saved position on launch.
    ///
    /// Off is for readers who want the shelf first: the resume happens before
    /// they can tap anything, so it has to be an explicit choice.
    public var resumeLastReading: Bool

    public init(
        fontSize: Double = 26,
        lineSpacing: Double = 13,
        paragraphSpacing: Double = 12,
        horizontalPadding: Double = 20,
        theme: ReaderTheme = .paper,
        fontFamily: String? = nil,
        pageTurnMode: PageTurnMode = .page,
        pageTurnEffect: PageTurnEffect = .slide,
        firstLineIndent: Bool = true,
        alignment: BodyAlignment = .justify,
        followSystemAppearance: Bool = true,
        resumeLastReading: Bool = true
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.horizontalPadding = horizontalPadding
        self.theme = theme
        self.fontFamily = fontFamily
        self.pageTurnMode = pageTurnMode
        self.pageTurnEffect = pageTurnEffect
        self.firstLineIndent = firstLineIndent
        self.alignment = alignment
        self.followSystemAppearance = followSystemAppearance
        self.resumeLastReading = resumeLastReading
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
        case firstLineIndent
        case alignment
        case followSystemAppearance
        case resumeLastReading
    }

    /// Tolerant decoding: settings written before pagination (or before the
    /// typography options) existed have no such keys, and should keep their
    /// values instead of resetting the whole `AppSettings` blob.
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
        firstLineIndent = try container.decodeIfPresent(Bool.self, forKey: .firstLineIndent) ?? defaults.firstLineIndent
        alignment = try container.decodeIfPresent(BodyAlignment.self, forKey: .alignment) ?? defaults.alignment
        followSystemAppearance = try container.decodeIfPresent(Bool.self, forKey: .followSystemAppearance)
            ?? defaults.followSystemAppearance
        resumeLastReading = try container.decodeIfPresent(Bool.self, forKey: .resumeLastReading)
            ?? defaults.resumeLastReading
    }

    /// The paper and ink to draw with.
    ///
    /// With follow-system on, the phone's light/dark mode picks the *family*,
    /// while the user's chosen theme still picks the variant within it. So a
    /// reader who likes 纯黑 gets 纯黑 in the dark, and 纸白 in daylight — instead
    /// of a system toggle silently overriding their contrast choice.
    public func resolvedTheme(systemIsDark: Bool) -> ReaderTheme {
        guard followSystemAppearance else { return theme }
        return systemIsDark ? theme.darkCounterpart : theme.lightCounterpart
    }

    /// One-time migration to the current typography defaults.
    ///
    /// Only fires for installs still sitting on the old defaults, which is what
    /// `19`/`8` mean here: someone who picked their own size should keep it.
    /// Returns `true` when it changed anything, so the caller can persist.
    ///
    /// A migration is needed at all because the stored blob carries every key:
    /// decoding would otherwise keep the old numbers forever and the new
    /// default would only ever reach fresh installs.
    @discardableResult
    public mutating func adoptTypographyDefaults(hasMigrated: Bool) -> Bool {
        guard !hasMigrated else { return false }
        guard fontSize == 19, lineSpacing == 8 else { return false }
        fontSize = 26
        lineSpacing = 13
        return true
    }

    /// One-time migration for installs created while "follow system" defaulted
    /// to off: those users never saw the reader go dark, and had every reason
    /// to assume it was broken rather than switched off.
    ///
    /// `hasMigrated` is the caller's persisted flag. Guarding on a flag rather
    /// than on the stored value is what makes this safe: a reader who switches
    /// the toggle off afterwards keeps it off, because the migration never runs
    /// again. Returns `true` when it flipped the value, so the caller can
    /// persist the change.
    @discardableResult
    public mutating func adoptSystemAppearance(hasMigrated: Bool) -> Bool {
        guard !hasMigrated, !followSystemAppearance else { return false }
        followSystemAppearance = true
        return true
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
    /// Which engine reads the text.
    public var engine: TTSEngine
    /// Remote engine configuration; ignored by the system engine.
    public var remote: RemoteTTSSettings
    /// Keep synthesized audio on disk so replaying a chapter costs nothing.
    public var cacheEnabled: Bool
    /// Upper bound on cached speech, in megabytes. 0 means no limit.
    public var cacheLimitMB: Int
    /// Optional HTTP proxy for the remote engines, `host:port`.
    ///
    /// Empty means connect directly. Only speech goes through it: the novel
    /// sources keep using the normal session, since a proxy that exists to
    /// reach Microsoft's voice service would otherwise also silently change
    /// which IP a book site sees.
    public var proxy: String

    public init(
        rate: Double = 0.5,
        pitch: Double = 1.0,
        volume: Double = 1.0,
        voiceIdentifier: String? = nil,
        voiceName: String? = nil,
        autoNextChapter: Bool = true,
        sentencePause: Double = 0.15,
        engine: TTSEngine = .edge,
        remote: RemoteTTSSettings = RemoteTTSSettings(),
        cacheEnabled: Bool = true,
        cacheLimitMB: Int = 300,
        proxy: String = ""
    ) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.voiceIdentifier = voiceIdentifier
        self.voiceName = voiceName
        self.autoNextChapter = autoNextChapter
        self.sentencePause = sentencePause
        self.engine = engine
        self.remote = remote
        self.cacheEnabled = cacheEnabled
        self.cacheLimitMB = cacheLimitMB
        self.proxy = proxy
    }

    private enum CodingKeys: String, CodingKey {
        case rate, pitch, volume, voiceIdentifier, voiceName
        case autoNextChapter, sentencePause, engine, remote
        case cacheEnabled, cacheLimitMB, proxy
    }

    /// Tolerant decoding: installs that predate the engine choice keep their
    /// system voice and speed instead of resetting to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TTSSettings()
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? defaults.rate
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch) ?? defaults.pitch
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume
        voiceIdentifier = try container.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        voiceName = try container.decodeIfPresent(String.self, forKey: .voiceName)
        autoNextChapter = try container.decodeIfPresent(Bool.self, forKey: .autoNextChapter) ?? defaults.autoNextChapter
        sentencePause = try container.decodeIfPresent(Double.self, forKey: .sentencePause) ?? defaults.sentencePause
        engine = try container.decodeIfPresent(TTSEngine.self, forKey: .engine) ?? defaults.engine
        remote = try container.decodeIfPresent(RemoteTTSSettings.self, forKey: .remote) ?? defaults.remote
        cacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? defaults.cacheEnabled
        cacheLimitMB = try container.decodeIfPresent(Int.self, forKey: .cacheLimitMB) ?? defaults.cacheLimitMB
        proxy = try container.decodeIfPresent(String.self, forKey: .proxy) ?? defaults.proxy
    }

    /// The remote engine is only useful if it has been pointed at something.
    public var isRemoteUsable: Bool {
        switch engine {
        case .system:
            return false
        case .edge:
            return !remote.edgeVoice.isEmpty
        case .openAICompatible:
            return remote.speechURL != nil && !remote.model.isEmpty
        }
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

public struct CacheSettings: Codable, Hashable, Sendable {
    /// Download the next N chapters in the background while reading, so lines
    /// keep coming when the network drops.
    public var prefetchCount: Int
    /// Cache a whole book when it is added to the shelf.
    public var autoCacheOnAdd: Bool
    /// Upper bound on how many cached chapters to keep per book; older ones are
    /// dropped from the tail of the read position. 0 means "no limit".
    public var maxCachedChaptersPerBook: Int

    public init(
        prefetchCount: Int = 5,
        autoCacheOnAdd: Bool = false,
        maxCachedChaptersPerBook: Int = 0
    ) {
        self.prefetchCount = prefetchCount
        self.autoCacheOnAdd = autoCacheOnAdd
        self.maxCachedChaptersPerBook = maxCachedChaptersPerBook
    }

    private enum CodingKeys: String, CodingKey {
        case prefetchCount
        case autoCacheOnAdd
        case maxCachedChaptersPerBook
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CacheSettings()
        prefetchCount = try container.decodeIfPresent(Int.self, forKey: .prefetchCount) ?? defaults.prefetchCount
        autoCacheOnAdd = try container.decodeIfPresent(Bool.self, forKey: .autoCacheOnAdd) ?? defaults.autoCacheOnAdd
        maxCachedChaptersPerBook = try container.decodeIfPresent(Int.self, forKey: .maxCachedChaptersPerBook)
            ?? defaults.maxCachedChaptersPerBook
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var reading: ReadingSettings
    public var tts: TTSSettings
    public var network: NetworkSettings
    public var ai: AIConfiguration
    public var cache: CacheSettings
    /// Search all enabled sources at once; false means "pick one".
    public var searchAllSources: Bool
    /// Output layout applied after AI cleanup.
    public var aiOutputFormat: AIPrompt.OutputFormat
    /// Strip ads and site trailers from every chapter automatically.
    ///
    /// Off by default: it spends the user's API quota on every chapter, and
    /// only makes sense once an API is configured at all.
    public var aiAutoClean: Bool
    /// How many chapters ahead to download and clean while reading.
    ///
    /// 0 turns the queue off, which brings back a wait at every page turn.
    /// Each chapter in the window costs one model call, so this trades quota
    /// for a page turn that never blocks.
    public var aiCleanAhead: Int
    /// Recent search keywords, newest first.
    ///
    /// Kept short on purpose: a list long enough to scroll is one the user
    /// scrolls past rather than taps.
    public var searchHistory: [String]
    /// Cross-device sync of shelf, sources and reading progress.
    public var sync: SyncSettings

    public init(
        reading: ReadingSettings = ReadingSettings(),
        tts: TTSSettings = TTSSettings(),
        network: NetworkSettings = NetworkSettings(),
        ai: AIConfiguration = AIConfiguration(),
        cache: CacheSettings = CacheSettings(),
        searchAllSources: Bool = true,
        aiOutputFormat: AIPrompt.OutputFormat = .paragraphs,
        aiAutoClean: Bool = false,
        aiCleanAhead: Int = 3,
        searchHistory: [String] = [],
        sync: SyncSettings = SyncSettings()
    ) {
        self.reading = reading
        self.tts = tts
        self.network = network
        self.ai = ai
        self.cache = cache
        self.searchAllSources = searchAllSources
        self.aiOutputFormat = aiOutputFormat
        self.aiAutoClean = aiAutoClean
        self.aiCleanAhead = aiCleanAhead
        self.searchHistory = searchHistory
        self.sync = sync
    }

    private enum CodingKeys: String, CodingKey {
        case reading
        case tts
        case network
        case ai
        case cache
        case searchAllSources
        case aiOutputFormat
        case aiAutoClean
        case aiCleanAhead
        case searchHistory
        case sync
    }

    /// Tolerant decoding so adding settings in a new build does not wipe the
    /// ones the user already has on disk.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        reading = try container.decodeIfPresent(ReadingSettings.self, forKey: .reading) ?? defaults.reading
        tts = try container.decodeIfPresent(TTSSettings.self, forKey: .tts) ?? defaults.tts
        network = try container.decodeIfPresent(NetworkSettings.self, forKey: .network) ?? defaults.network
        ai = try container.decodeIfPresent(AIConfiguration.self, forKey: .ai) ?? defaults.ai
        cache = try container.decodeIfPresent(CacheSettings.self, forKey: .cache) ?? defaults.cache
        searchAllSources = try container.decodeIfPresent(Bool.self, forKey: .searchAllSources) ?? defaults.searchAllSources
        aiOutputFormat = try container.decodeIfPresent(AIPrompt.OutputFormat.self, forKey: .aiOutputFormat)
            ?? defaults.aiOutputFormat
        // Absent means "the user never turned it on": a settings file written
        // before this option existed must not start spending API calls.
        aiAutoClean = try container.decodeIfPresent(Bool.self, forKey: .aiAutoClean) ?? defaults.aiAutoClean
        aiCleanAhead = try container.decodeIfPresent(Int.self, forKey: .aiCleanAhead) ?? defaults.aiCleanAhead
        searchHistory = try container.decodeIfPresent([String].self, forKey: .searchHistory) ?? defaults.searchHistory
        sync = (try? container.decodeIfPresent(SyncSettings.self, forKey: .sync)) ?? defaults.sync
    }

    /// A copy safe to write as plain JSON: API keys live in the Keychain, never
    /// in `settings.json`.
    ///
    /// Any code path that persists settings has to go through this, not just
    /// the explicit "save" action — a migration writing the in-memory settings
    /// would otherwise quietly spill both keys onto disk.
    public var strippingSecrets: AppSettings {
        var copy = self
        copy.ai.apiKey = ""
        copy.tts.remote.apiKey = ""
        copy.sync = sync.strippingSecrets
        return copy
    }
}
