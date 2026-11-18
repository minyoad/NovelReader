import Testing
import Foundation

@testable import NovelKit

@Suite("同步：AI 设置随文件走")
struct SyncedAISettingsTests {

    private func payload(
        device: String = "A",
        updatedAt: Date = Date(),
        ai: SyncedAISettings? = nil
    ) -> SyncPayload {
        SyncPayload(
            updatedAt: updatedAt,
            deviceID: device,
            books: [],
            sources: [],
            subscriptions: [],
            ai: ai
        )
    }

    /// - Parameter changedAt: when this block was last edited on its device.
    ///   The merge compares these, not the payload's `updatedAt` — see
    ///   `newerFileWins` for why.
    private func configured(
        key: String = "sk-abc",
        model: String = "deepseek-chat",
        changedAt: Date? = nil
    ) -> SyncedAISettings {
        SyncedAISettings(
            enabled: true,
            preset: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: model,
            apiKey: key,
            updatedAt: changedAt
        )
    }

    // MARK: - 读写

    @Test("从 AppSettings 取出的就是界面上的值")
    func roundTrip() {
        var settings = AppSettings()
        settings.ai.enabled = true
        settings.ai.baseURL = "https://wb.mybacc.com/v1"
        settings.ai.model = "auto"
        settings.ai.apiKey = "sk-xyz"
        settings.aiAutoClean = true
        settings.aiCleanAhead = 5
        settings.aiOutputFormat = .spaced

        let synced = SyncedAISettings(settings)
        #expect(synced.baseURL == "https://wb.mybacc.com/v1")
        #expect(synced.model == "auto")
        #expect(synced.apiKey == "sk-xyz")
        #expect(synced.autoClean)
        #expect(synced.cleanAhead == 5)
        #expect(synced.outputFormat == .spaced)

        var target = AppSettings()
        synced.apply(to: &target)
        #expect(target.ai.baseURL == "https://wb.mybacc.com/v1")
        #expect(target.ai.apiKey == "sk-xyz")
        #expect(target.aiAutoClean)
    }

    @Test("apply 不动阅读和 TTS 设置")
    func applyTouchesOnlyAI() {
        var settings = AppSettings()
        settings.reading.fontSize = 23
        settings.tts.rate = 0.7

        configured().apply(to: &settings)

        #expect(settings.reading.fontSize == 23)
        #expect(settings.tts.rate == 0.7)
    }

    // MARK: - 已配置判定

    @Test("什么都没填算没配置，不会去冲掉对方的")
    func blankIsNotConfigured() {
        #expect(!SyncedAISettings().isConfigured)
        // 仅开启开关、没有 key 也没有地址：仍然没配置
        #expect(!SyncedAISettings(enabled: true).isConfigured)
    }

    @Test("只有 key 也算配过：预设自带地址和模型")
    func keyAloneCounts() {
        #expect(SyncedAISettings(enabled: true, apiKey: "sk-1").isConfigured)
    }

    // MARK: - 合并

    @Test("换供应商时整套跟着换，不拼出没人配过的组合")
    func providerChangeMovesTogether() {
        let newer = SyncedAISettings(
            enabled: true,
            preset: .custom,
            baseURL: "https://wb.mybacc.com/v1",
            model: "auto",
            apiKey: "sk-new"
        )
        let older = configured()  // deepseek-chat + api.deepseek.com

        let merged = SyncedAISettings.merge(newer: newer, older: older)

        #expect(merged.baseURL == "https://wb.mybacc.com/v1")
        #expect(merged.model == "auto")
        #expect(merged.preset == .custom)
        #expect(merged.apiKey == "sk-new")
    }

    @Test("新的一方没填 key 时从旧的一方取回")
    func blankKeyIsFilled() {
        let newer = SyncedAISettings(
            enabled: true,
            preset: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: ""
        )
        let older = configured(key: "sk-保持我")

        let merged = SyncedAISettings.merge(newer: newer, older: older)

        #expect(merged.apiKey == "sk-保持我")
        #expect(merged.model == "deepseek-chat")
    }

    @Test("文件里的 AI 块更新时取文件里的")
    func newerFileWins() {
        let now = Date()
        // 关键：payload 的 updatedAt 在这里反而是「本地更新」——真实同步里
        // 它就是同步那一刻，永远比文件里的旧时间新。旧实现比的就是它，
        // 于是本地每次都赢，另一台改了参数永远传不过来。
        let local = payload(
            updatedAt: now,
            ai: configured(key: "sk-old", model: "old-model", changedAt: now.addingTimeInterval(-3600))
        )
        let remote = payload(
            device: "B",
            updatedAt: now.addingTimeInterval(-1800),
            ai: configured(key: "sk-new", model: "new-model", changedAt: now)
        )

        let outcome = SyncMerge.merge(local: local, remote: remote)

        #expect(outcome.ai?.apiKey == "sk-new")
        #expect(outcome.ai?.model == "new-model")
    }

    @Test("本机的 AI 块更新时保留本机的，即使文件刚被重写过")
    func newerLocalBlockWins() {
        let now = Date()
        let local = payload(
            updatedAt: now,
            ai: configured(key: "sk-mine", model: "mine", changedAt: now)
        )
        let remote = payload(
            device: "B",
            updatedAt: now.addingTimeInterval(60),
            ai: configured(key: "sk-theirs", model: "theirs", changedAt: now.addingTimeInterval(-3600))
        )

        let outcome = SyncMerge.merge(local: local, remote: remote)

        #expect(outcome.ai?.apiKey == "sk-mine")
        #expect(outcome.ai?.model == "mine")
    }

    @Test("本机没配、文件有配，拿到文件的")
    func freshInstallAdopts() {
        let local = payload(ai: nil)
        let remote = payload(device: "B", ai: configured())

        let outcome = SyncMerge.merge(local: local, remote: remote)

        #expect(outcome.ai?.apiKey == "sk-abc")
    }

    @Test("两边都没有就不带，不制造空字段")
    func neitherHasAI() {
        let outcome = SyncMerge.merge(local: payload(), remote: payload(device: "B"))
        #expect(outcome.ai == nil)
    }

    @Test("旧文件没有 ai 字段也能读")
    func oldFileStillDecodes() throws {
        let json = """
        {"version":1,"updatedAt":"2026-11-18T00:00:00Z","deviceID":"A","books":[],"sources":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncPayload.self, from: Data(json.utf8))
        #expect(decoded.ai == nil)
        #expect(decoded.isSupported)
    }

    @Test("文件里没有 AI 时，本机的也不会被当成内容差异")
    func missingAIDoesNotForceUpload() throws {
        // sameContent 的规则：nil 和 nil 一致，nil 和有内容不一致。
        // 这里用合并结果直接验证规则含义，避免依赖 SyncService 的私有实现。
        let local = payload(ai: configured())
        let remote = payload(device: "B", ai: nil)
        let outcome = SyncMerge.merge(local: local, remote: remote)
        // 本地有、远端没有 → 结果带着本地的，和远端不同，需要上传一次
        #expect(outcome.ai != nil)
        #expect(outcome.ai != remote.ai)
    }

    @Test("API Key 会写进文件（用户明确选择了连 key 一起同步）")
    func apiKeyTravels() throws {
        let data = try JSONEncoder().encode(configured(key: "sk-要传的"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("sk-要传的"))
    }
}
