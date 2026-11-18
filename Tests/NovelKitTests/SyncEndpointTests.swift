import Testing
import Foundation

@testable import NovelKit

@Suite("同步：服务器地址随文件走")
struct SyncEndpointTests {

    private func payload(
        device: String = "A",
        updatedAt: Date = Date(),
        books: [Book] = [],
        endpoint: SyncEndpoint? = nil
    ) -> SyncPayload {
        SyncPayload(
            updatedAt: updatedAt,
            deviceID: device,
            books: books,
            sources: [],
            subscriptions: [],
            endpoint: endpoint
        )
    }

    // MARK: - 编码

    @Test("密码永远不进同步文件")
    func secretsNeverTravel() throws {
        var sync = SyncSettings(
            enabled: true,
            webdav: WebDAVConfiguration(
                directoryURL: "https://pan.aabite.com/dav",
                username: "minyoad@gmail.com",
                password: "别传出去"
            )
        )
        sync.s3.secretKey = "也别传"
        sync.s3.sessionToken = "更别传"

        let endpoint = SyncEndpoint(sync)
        let data = try JSONEncoder().encode(endpoint)
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("别传出去"))
        #expect(!text.contains("也别传"))
        #expect(!text.contains("更别传"))
        #expect(text.contains("pan.aabite.com"))
    }

    @Test("deviceID 和上次同步时间不随文件走")
    func perDeviceFieldsStayLocal() {
        // 两台设备的 deviceID 必须不同，否则会把对方的上传当成自己的，
        // 从而跳过下载。
        let endpoint = SyncEndpoint(SyncSettings())
        let data = try? JSONEncoder().encode(endpoint)
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!text.contains("deviceID"))
        #expect(!text.contains("lastSyncedAt"))
    }

    // MARK: - 空值与合并

    @Test("没配过的设备不上传地址，免得把对方配置冲掉")
    func unconfiguredIsEmpty() {
        #expect(SyncEndpoint(SyncSettings()).isEmpty)
        // backend 和 region 有默认值，不该让「空」判成「有」
        var configured = SyncSettings()
        configured.webdav.directoryURL = "https://example.com/dav"
        #expect(!SyncEndpoint(configured).isEmpty)
    }

    @Test("新文件赢，旧文件只补空白字段")
    func mergesFieldByField() {
        let newer = SyncEndpoint(directoryURL: "https://new.example.com/dav", username: "")
        let older = SyncEndpoint(directoryURL: "https://old.example.com/dav", username: "yang")

        let merged = SyncEndpoint.merge(newer: newer, older: older)

        #expect(merged.directoryURL == "https://new.example.com/dav")
        // 新文件没填的用户名从旧文件取回，不然换服务器会把账号弄丢
        #expect(merged.username == "yang")
    }

    @Test("地址相同时互不覆盖")
    func sameServerNeedsNoWork() {
        let a = SyncEndpoint(directoryURL: "https://pan.aabite.com/dav", username: "minyoad@gmail.com")
        let b = SyncEndpoint(directoryURL: "https://pan.aabite.com/dav", username: "minyoad@gmail.com")
        #expect(a.hasSameServerSettings(as: b))
    }

    @Test("只有后端不同不算换了服务器")
    func backendDifferenceIsNotAServerChange() {
        let phone = SyncEndpoint(backend: .webdav, directoryURL: "https://pan.aabite.com/dav")
        let pad = SyncEndpoint(backend: .s3, directoryURL: "https://pan.aabite.com/dav")
        #expect(phone.hasSameServerSettings(as: pad))
    }

    @Test("apply 不动密码")
    func applyKeepsSecrets() {
        var settings = SyncSettings()
        settings.webdav.password = "本机钥匙串里的"
        settings.s3.secretKey = "本机 S3 密钥"

        SyncEndpoint(directoryURL: "https://pan.aabite.com/dav", username: "minyoad@gmail.com")
            .apply(to: &settings)

        #expect(settings.webdav.directoryURL == "https://pan.aabite.com/dav")
        #expect(settings.webdav.username == "minyoad@gmail.com")
        #expect(settings.webdav.password == "本机钥匙串里的")
        #expect(settings.s3.secretKey == "本机 S3 密钥")
    }

    @Test("apply 不覆盖本机已有的值")
    func applyDoesNotBlankLocalValues() {
        var settings = SyncSettings(
            webdav: WebDAVConfiguration(directoryURL: "https://mine.example.com/dav", username: "me")
        )
        // 对方只配了 S3，WebDAV 是空的
        SyncEndpoint(s3Endpoint: "https://s3.example.com", s3Bucket: "b").apply(to: &settings)
        #expect(settings.webdav.directoryURL == "https://mine.example.com/dav")
        #expect(settings.webdav.username == "me")
        #expect(settings.s3.bucket == "b")
    }

    // MARK: - 合并进同步结果

    @Test("本地没配过，从文件里拿到地址")
    func adoptsRemoteEndpoint() {
        let local = payload(updatedAt: Date().addingTimeInterval(-60))
        let remote = payload(
            device: "B",
            endpoint: SyncEndpoint(directoryURL: "https://pan.aabite.com/dav", username: "minyoad@gmail.com")
        )

        let outcome = SyncMerge.merge(local: local, remote: remote)

        #expect(outcome.endpoint?.directoryURL == "https://pan.aabite.com/dav")
        #expect(outcome.endpoint?.username == "minyoad@gmail.com")
    }

    @Test("本机配过、文件没配，本机的保留")
    func keepsLocalEndpoint() {
        let local = payload(
            endpoint: SyncEndpoint(directoryURL: "https://mine.example.com/dav", username: "me")
        )
        let remote = payload(device: "B", updatedAt: Date().addingTimeInterval(60))

        let outcome = SyncMerge.merge(local: local, remote: remote)

        #expect(outcome.endpoint?.directoryURL == "https://mine.example.com/dav")
    }

    @Test("文件更新时取文件的地址")
    func newerFileWins() {
        let now = Date()
        let local = payload(
            updatedAt: now.addingTimeInterval(-3600),
            endpoint: SyncEndpoint(directoryURL: "https://old.example.com/dav")
        )
        let remote = payload(
            device: "B",
            updatedAt: now,
            endpoint: SyncEndpoint(directoryURL: "https://new.example.com/dav")
        )

        let outcome = SyncMerge.merge(local: local, remote: remote)

        #expect(outcome.endpoint?.directoryURL == "https://new.example.com/dav")
    }

    @Test("两边都没配就不带地址，不制造空字段")
    func neitherConfigured() {
        let outcome = SyncMerge.merge(local: payload(), remote: payload(device: "B"))
        #expect(outcome.endpoint == nil)
    }

    @Test("旧文件没有这个字段也能读")
    func oldFileStillDecodes() throws {
        // 模拟这个功能上线前写出的文件
        let json = """
        {"version":1,"updatedAt":"2026-11-18T00:00:00Z","deviceID":"A","books":[],"sources":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncPayload.self, from: Data(json.utf8))
        #expect(decoded.endpoint == nil)
        #expect(decoded.isSupported)
    }

    @Test("地址不会让每次同步都重新上传")
    func endpointDoesNotForceUpload() {
        // sameContent 不比较 endpoint：本机地址与文件里不同时，
        // 不应为了重申同样的值而每次都上传。
        let local = payload(endpoint: SyncEndpoint(directoryURL: "https://a.example.com/dav"))
        let remote = payload(device: "B", endpoint: SyncEndpoint(directoryURL: "https://b.example.com/dav"))
        let outcome = SyncMerge.merge(local: local, remote: remote)
        // 内容一致（都是空书架），localChanged 为 false
        #expect(!outcome.localChanged)
    }
}
