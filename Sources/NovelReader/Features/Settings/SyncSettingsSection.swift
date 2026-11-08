#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Settings for cross-device sync.
///
/// Split out of `SettingsView` because the two backends have enough fields of
/// their own to bury the rest of the page if inlined.
struct SyncSettingsSection: View {
    @EnvironmentObject private var app: AppModel

    /// Owned by `SettingsView` so one "完成" button in the keyboard toolbar
    /// closes any field on the page, including these.
    var focus: FocusState<Bool>.Binding

    @State private var testing = false
    @State private var testResult: String?
    /// Result of the last manual sync, shown under the button. A sync failure
    /// used to go to a banner on the shelf screen, which is invisible here.
    @State private var syncMessage: (text: String, isError: Bool)?
    @State private var syncing = false
    @State private var showWebDAVPassword = false
    @State private var showS3Secret = false

    private var sync: Binding<SyncSettings> { $app.settings.sync }

    var body: some View {
        Group {
            Toggle("启用同步", isOn: sync.enabled.animation())

            if sync.wrappedValue.enabled {
                Picker("方式", selection: sync.backend) {
                    ForEach(SyncBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                switch sync.wrappedValue.backend {
                case .webdav: webdavFields
                case .s3: s3Fields
                }

                actions
            }
        }
    }

    // MARK: WebDAV

    @ViewBuilder
    private var webdavFields: some View {
        LabeledContent("目录地址") {
            TextField("https://dav.jianguoyun.com/dav/夜读", text: sync.webdav.directoryURL)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
        LabeledContent("账号") {
            TextField("邮箱或用户名", text: sync.webdav.username)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        LabeledContent("密码") {
            HStack {
                Group {
                    if showWebDAVPassword {
                        TextField("应用密码", text: sync.webdav.password)
                            .focused(focus)
                    } else {
                        SecureField("应用密码", text: sync.webdav.password)
                            .focused(focus)
                    }
                }
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)

                Button {
                    showWebDAVPassword.toggle()
                } label: {
                    Image(systemName: showWebDAVPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        LabeledContent("文件名") {
            TextField("nightread-sync.json", text: sync.webdav.fileName)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        Text("坚果云需要在「账户信息 → 安全选项」里生成第三方应用密码，不能直接用登录密码。目录不存在时会自动创建。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: S3

    @ViewBuilder
    private var s3Fields: some View {
        LabeledContent("接入点") {
            TextField("https://s3.us-east-1.amazonaws.com", text: sync.s3.endpoint)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
        LabeledContent("区域") {
            TextField("us-east-1", text: sync.s3.region)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        LabeledContent("存储桶") {
            TextField("my-bucket", text: sync.s3.bucket)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        LabeledContent("文件路径") {
            TextField("nightread-sync.json", text: sync.s3.keyPath)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        LabeledContent("Access Key") {
            TextField("AKIA...", text: sync.s3.accessKeyID)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        LabeledContent("Secret Key") {
            HStack {
                Group {
                    if showS3Secret {
                        TextField("密钥", text: sync.s3.secretKey)
                            .focused(focus)
                    } else {
                        SecureField("密钥", text: sync.s3.secretKey)
                            .focused(focus)
                    }
                }
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)

                Button {
                    showS3Secret.toggle()
                } label: {
                    Image(systemName: showS3Secret ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        LabeledContent("会话令牌") {
            TextField("可选，仅临时凭证需要", text: sync.s3.sessionToken)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus)
        }
        Text("用路径式访问（bucket 在地址里）。Cloudflare R2 的区域填 auto，接入点形如 https://<账号>.r2.cloudflarestorage.com。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        Button {
            Task {
                testing = true
                syncMessage = nil
                testResult = await app.testSyncConnection()
                testing = false
            }
        } label: {
            HStack {
                if testing {
                    ProgressView().controlSize(.small)
                }
                Text("测试连接")
            }
        }
        .disabled(testing)

        Button {
            Task {
                syncing = true
                syncMessage = nil
                let outcome = await app.runSync(reportErrors: true)
                syncMessage = (outcome.summary, !outcome.isSuccess)
                syncing = false
            }
        } label: {
            HStack {
                if syncing {
                    ProgressView().controlSize(.small)
                }
                Text("立即同步")
            }
        }
        .disabled(syncing)

        if !sync.wrappedValue.isUsable {
            Text("配置还不完整：需要打开开关，并填好地址和账号。")
                .font(.footnote)
                .foregroundStyle(.orange)
        }

        if let testResult {
            Text(testResult)
                .font(.footnote)
                .foregroundStyle(testResult.hasPrefix("连接成功") ? .green : .red)
        }

        if let syncMessage {
            Text(syncMessage.text)
                .font(.footnote)
                .foregroundStyle(syncMessage.isError ? .red : .green)
        }

        if let last = sync.wrappedValue.lastSyncedAt {
            LabeledContent("上次同步", value: last.formatted(date: .abbreviated, time: .shortened))
        }
    }
}
#endif
