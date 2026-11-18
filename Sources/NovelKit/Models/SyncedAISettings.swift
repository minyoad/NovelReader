import Foundation

/// AI configuration and cleanup choices, as they travel between devices.
///
/// Why these are synced at all: getting AI cleanup working means picking a
/// provider, an endpoint, a model and typing a key. Told to do that again on a
/// second phone, nobody does — they just stop using the feature there. The
/// address and username of the sync server are already carried for the same
/// reason (see `SyncEndpoint`).
///
/// Why the API key *is* here, unlike the sync password: the two secrets are
/// not alike. The sync password guards the very file this struct is stored in
/// — putting it here would hand out the key to the box. The AI key only opens
/// an unrelated third-party service, and the alternative is every device
/// needing it typed by hand. The trade is made explicit rather than implied:
/// the key is in the file the user already controls, on their own server.
///
/// Everything a device keeps for itself — nothing, in this case — would go in a
/// field that only the writer reads. There is none: this is all shared.
public struct SyncedAISettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var preset: AIProviderPreset
    public var baseURL: String
    public var model: String
    public var temperature: Double
    public var maxTokens: Int
    public var apiKey: String
    public var chunkSize: Int
    public var timeout: Double
    public var customInstruction: String

    /// Cleanup behaviour that follows the provider around: which output layout
    /// to apply, and whether to clean every chapter automatically.
    ///
    /// These live on `AppSettings` next to the AI block rather than inside it,
    /// but they only make sense with a configured provider, so they travel
    /// together. Leaving them behind would produce the odd state of a second
    /// device that has the key but has never been told to use it.
    public var outputFormat: AIPrompt.OutputFormat
    public var autoClean: Bool
    public var cleanAhead: Int

    /// When this block last changed on the device that published it.
    ///
    /// The payload already has an `updatedAt`, but that is the time of the
    /// *sync* — the file is rewritten on every sync even when nothing about AI
    /// changed. Using it to decide "whose settings are newer" made the local
    /// side win every time, because the local payload is built with `Date()`
    /// at the moment of syncing. This is the timestamp the merge actually
    /// needs, and it only moves when one of the fields above really changes.
    ///
    /// Settings written before this field existed decode with `nil`, which the
    /// merge reads as "never changed". `LibraryStore.loadSettings` backfills it
    /// once from the settings file's modification time, so an upgraded device
    /// keeps a place in the ordering instead of always losing to a file that
    /// carries a timestamp.
    public var updatedAt: Date?

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
        customInstruction: String = "",
        outputFormat: AIPrompt.OutputFormat = .paragraphs,
        autoClean: Bool = false,
        cleanAhead: Int = 3,
        updatedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.preset = preset
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.apiKey = apiKey
        self.chunkSize = chunkSize
        self.timeout = timeout
        self.customInstruction = customInstruction
        self.outputFormat = outputFormat
        self.autoClean = autoClean
        self.cleanAhead = cleanAhead
        self.updatedAt = updatedAt
    }

    public init(_ settings: AppSettings) {
        let ai = settings.ai
        self.init(
            enabled: ai.enabled,
            preset: ai.preset,
            baseURL: ai.baseURL,
            model: ai.model,
            temperature: ai.temperature,
            maxTokens: ai.maxTokens,
            apiKey: ai.apiKey,
            chunkSize: ai.chunkSize,
            timeout: ai.timeout,
            customInstruction: ai.customInstruction,
            outputFormat: settings.aiOutputFormat,
            autoClean: settings.aiAutoClean,
            cleanAhead: settings.aiCleanAhead,
            updatedAt: settings.aiUpdatedAt
        )
    }

    /// Whether this device has configured a provider at all.
    ///
    /// Used to decide whether it has anything worth publishing: a device that
    /// has never opened AI settings would otherwise upload a default block
    /// that erases the other device's real one the moment its file is newer.
    ///
    /// `enabled` alone does not count. Turning the switch on without a key is
    /// a half-finished setup that cannot make a single request, and publishing
    /// it would replace a working configuration on the other device with one
    /// that fails on every chapter.
    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            || !model.trimmingCharacters(in: .whitespaces).isEmpty
            || !customInstruction.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Applies these settings locally, leaving everything else alone.
    ///
    /// The timestamp is carried along, so the local copy keeps the identity of
    /// the change it came from. Overwriting it with "now" would make this
    /// device look like the author of a change it merely received, and the next
    /// merge would then prefer it over the device that actually made it.
    public func apply(to settings: inout AppSettings) {
        settings.ai.enabled = enabled
        settings.ai.preset = preset
        settings.ai.baseURL = baseURL
        settings.ai.model = model
        settings.ai.temperature = temperature
        settings.ai.maxTokens = maxTokens
        settings.ai.apiKey = apiKey
        settings.ai.chunkSize = chunkSize
        settings.ai.timeout = timeout
        settings.ai.customInstruction = customInstruction
        settings.aiOutputFormat = outputFormat
        settings.aiAutoClean = autoClean
        settings.aiCleanAhead = cleanAhead
        settings.aiUpdatedAt = updatedAt
    }

    /// Merges two blocks, newest wins whole, older fills blanks only.
    ///
    /// "Fills blanks" rather than "keeps fields": the provider choice is one
    /// coherent set, so a device that changed from DeepSeek to a self-hosted
    /// endpoint must have its model and preset come along too — mixing them
    /// produces a configuration nobody wrote. The only thing carried over from
    /// the older side is a field the newer side left empty, which is what
    /// makes a half-configured device safe to sync with.
    public static func merge(newer: SyncedAISettings, older: SyncedAISettings) -> SyncedAISettings {
        var result = newer
        if result.apiKey.trimmingCharacters(in: .whitespaces).isEmpty { result.apiKey = older.apiKey }
        if result.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { result.baseURL = older.baseURL }
        if result.model.trimmingCharacters(in: .whitespaces).isEmpty { result.model = older.model }
        if result.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty {
            result.customInstruction = older.customInstruction
        }
        return result
    }
}
