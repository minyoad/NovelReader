import Foundation

/// WebDAV endpoint settings.
public struct WebDAVConfiguration: Codable, Hashable, Sendable {
    /// Folder URL, e.g. `https://dav.jianguoyun.com/dav/夜读`.
    public var directoryURL: String
    public var username: String
    /// Stored in the Keychain, never in `settings.json` (see
    /// `AppSettings.strippingSecrets`).
    public var password: String
    /// File name inside the folder.
    public var fileName: String
    public var timeout: Double

    public init(
        directoryURL: String = "",
        username: String = "",
        password: String = "",
        fileName: String = "nightread-sync.json",
        timeout: Double = 30
    ) {
        self.directoryURL = directoryURL
        self.username = username
        self.password = password
        self.fileName = fileName
        self.timeout = timeout
    }

    public var isUsable: Bool {
        !directoryURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !fileName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// S3-compatible endpoint settings.
public struct S3Configuration: Codable, Hashable, Sendable {
    /// Endpoint origin, no bucket path, e.g. `https://s3.us-east-1.amazonaws.com`
    /// or `https://<account>.r2.cloudflarestorage.com`.
    public var endpoint: String
    public var region: String
    public var bucket: String
    /// Path inside the bucket, e.g. `novelreader/nightread-sync.json`.
    public var keyPath: String
    public var accessKeyID: String
    /// Stored in the Keychain.
    public var secretKey: String
    /// Temporary credentials only; empty for long-lived keys.
    public var sessionToken: String
    public var timeout: Double

    public init(
        endpoint: String = "",
        region: String = "us-east-1",
        bucket: String = "",
        keyPath: String = "nightread-sync.json",
        accessKeyID: String = "",
        secretKey: String = "",
        sessionToken: String = "",
        timeout: Double = 30
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.keyPath = keyPath
        self.accessKeyID = accessKeyID
        self.secretKey = secretKey
        self.sessionToken = sessionToken
        self.timeout = timeout
    }

    public var isUsable: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !bucket.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessKeyID.isEmpty
            && !secretKey.isEmpty
    }

    /// R2 and MinIO often expect `auto` or a specific region; AWS rejects an
    /// empty one, so a blank field falls back to the AWS default.
    public var effectiveRegion: String {
        let trimmed = region.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "us-east-1" : trimmed
    }
}

/// Sync settings as a whole.
public struct SyncSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var backend: SyncBackend
    public var webdav: WebDAVConfiguration
    public var s3: S3Configuration
    /// Stable per-install id, generated once. Tells a device whether the file
    /// it just read is its own upload.
    public var deviceID: String
    /// Last successful sync, for the settings screen.
    public var lastSyncedAt: Date?

    public init(
        enabled: Bool = false,
        backend: SyncBackend = .webdav,
        webdav: WebDAVConfiguration = WebDAVConfiguration(),
        s3: S3Configuration = S3Configuration(),
        deviceID: String = UUID().uuidString,
        lastSyncedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.backend = backend
        self.webdav = webdav
        self.s3 = s3
        self.deviceID = deviceID
        self.lastSyncedAt = lastSyncedAt
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case backend
        case webdav
        case s3
        case deviceID
        case lastSyncedAt
    }

    /// Tolerant decoding, like the rest of `AppSettings`: a new key must not
    /// wipe the user's existing configuration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SyncSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        backend = try container.decodeIfPresent(SyncBackend.self, forKey: .backend) ?? defaults.backend
        webdav = (try? container.decodeIfPresent(WebDAVConfiguration.self, forKey: .webdav)) ?? defaults.webdav
        s3 = (try? container.decodeIfPresent(S3Configuration.self, forKey: .s3)) ?? defaults.s3
        deviceID = (try? container.decodeIfPresent(String.self, forKey: .deviceID)) ?? defaults.deviceID
        lastSyncedAt = try? container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    /// Whether the selected backend has enough filled in to attempt a sync.
    public var isUsable: Bool {
        guard enabled else { return false }
        switch backend {
        case .webdav: return webdav.isUsable
        case .s3: return s3.isUsable
        }
    }

    /// A copy safe to write as plain JSON.
    public var strippingSecrets: SyncSettings {
        var copy = self
        copy.webdav.password = ""
        copy.s3.secretKey = ""
        copy.s3.sessionToken = ""
        return copy
    }
}
