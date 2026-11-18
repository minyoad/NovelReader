import Foundation

/// Where the sync server is, and who to sign in as — carried between devices.
///
/// Re-entering the WebDAV address and username on every new phone is pure
/// transcription: the values are the same on every device, and a typo in a URL
/// looks exactly like a server being down. So they travel with the sync file.
///
/// What deliberately does *not* travel is the password: a sync file sits on a
/// third-party server, and putting the credentials for that server inside the
/// file stored on it is one bad permission away from handing them out. The
/// password stays in the Keychain, entered once per device.
///
/// `deviceID` and `lastSyncedAt` also stay local: they describe *this*
/// install, and copying them would make one device mistake another's upload
/// for its own.
public struct SyncEndpoint: Codable, Sendable, Equatable {
    public var backend: SyncBackend
    /// WebDAV folder URL.
    public var directoryURL: String
    public var username: String
    public var s3Endpoint: String
    public var s3Region: String
    public var s3Bucket: String
    public var s3KeyPath: String
    public var s3AccessKeyID: String

    public init(
        backend: SyncBackend = .webdav,
        directoryURL: String = "",
        username: String = "",
        s3Endpoint: String = "",
        s3Region: String = "us-east-1",
        s3Bucket: String = "",
        s3KeyPath: String = "nightread-sync.json",
        s3AccessKeyID: String = ""
    ) {
        self.backend = backend
        self.directoryURL = directoryURL
        self.username = username
        self.s3Endpoint = s3Endpoint
        self.s3Region = s3Region
        self.s3Bucket = s3Bucket
        self.s3KeyPath = s3KeyPath
        self.s3AccessKeyID = s3AccessKeyID
    }

    public init(_ settings: SyncSettings) {
        self.init(
            backend: settings.backend,
            directoryURL: settings.webdav.directoryURL,
            username: settings.webdav.username,
            s3Endpoint: settings.s3.endpoint,
            s3Region: settings.s3.region,
            s3Bucket: settings.s3.bucket,
            s3KeyPath: settings.s3.keyPath,
            s3AccessKeyID: settings.s3.accessKeyID
        )
    }

    /// Whether there is anything worth sending.
    ///
    /// `backend` and `s3Region` have defaults and are therefore never empty, so
    /// counting them would make an unconfigured device publish an endpoint that
    /// overwrites a configured one with blanks. Only the fields a person types
    /// are considered.
    public var isEmpty: Bool {
        directoryURL.trimmingCharacters(in: .whitespaces).isEmpty
            && username.trimmingCharacters(in: .whitespaces).isEmpty
            && s3Endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && s3Bucket.trimmingCharacters(in: .whitespaces).isEmpty
            && s3AccessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Applies this endpoint to `settings`, keeping every local-only value.
    ///
    /// Secrets are left untouched: the Keychain values belong to this device
    /// and are loaded separately (`AppModel.load` overlays them). Only the
    /// fields that were actually carried are written, so a file from a device
    /// that only configured WebDAV does not blank out a local S3 setup.
    public func apply(to settings: inout SyncSettings) {
        if !directoryURL.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.webdav.directoryURL = directoryURL
        }
        if !username.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.webdav.username = username
        }
        if !s3Endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.s3.endpoint = s3Endpoint
        }
        if !s3Bucket.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.s3.bucket = s3Bucket
        }
        if !s3KeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.s3.keyPath = s3KeyPath
        }
        if !s3AccessKeyID.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.s3.accessKeyID = s3AccessKeyID
        }
        settings.backend = backend
    }

    /// Merges two endpoints, newest wins per field.
    ///
    /// There is no timestamp per field — the payload has one for the file —
    /// so `newer` is whichever side the caller decided is newer, and the older
    /// one only fills in what the newer one left blank. That way a device that
    /// has never been configured cannot erase a working setup, and a genuine
    /// move to a new server still takes effect.
    public static func merge(newer: SyncEndpoint, older: SyncEndpoint) -> SyncEndpoint {
        var result = newer
        if result.directoryURL.trimmingCharacters(in: .whitespaces).isEmpty { result.directoryURL = older.directoryURL }
        if result.username.trimmingCharacters(in: .whitespaces).isEmpty { result.username = older.username }
        if result.s3Endpoint.trimmingCharacters(in: .whitespaces).isEmpty { result.s3Endpoint = older.s3Endpoint }
        if result.s3Bucket.trimmingCharacters(in: .whitespaces).isEmpty { result.s3Bucket = older.s3Bucket }
        if result.s3AccessKeyID.trimmingCharacters(in: .whitespaces).isEmpty { result.s3AccessKeyID = older.s3AccessKeyID }
        return result
    }

    /// Whether the connection details match, ignoring the backend choice.
    ///
    /// The backend is a per-device preference — a phone can use WebDAV while a
    /// tablet uses S3 against the same account — so a disagreement there is
    /// not a change worth re-uploading for.
    public func hasSameServerSettings(as other: SyncEndpoint) -> Bool {
        directoryURL.trimmingCharacters(in: .whitespaces) == other.directoryURL.trimmingCharacters(in: .whitespaces)
            && username == other.username
            && s3Endpoint.trimmingCharacters(in: .whitespaces) == other.s3Endpoint.trimmingCharacters(in: .whitespaces)
            && s3Bucket == other.s3Bucket
            && s3KeyPath == other.s3KeyPath
            && s3AccessKeyID == other.s3AccessKeyID
    }
}
