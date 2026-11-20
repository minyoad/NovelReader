#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct TextPurificationView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var draft = TextPurificationSettings()
    @State private var loaded = false
    @State private var baseline = TextPurificationSettings()
    @State private var showingDiscard = false
    @State private var showOriginal = true
    private var isDirty: Bool { loaded && draft != baseline }
    @State private var sample = "在这里粘贴一段正文，检查规则效果。"
    @State private var preview: TextPurificationResult?
    @State private var previewing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Toggle("启用本书文本净化", isOn: $draft.enabled)
            } footer: {
                Text("仅对《\(book.name)》生效，本机保存。按列表顺序替换，替换为空即删除。保留缓存原文，关闭后恢复；阅读中修改规则会停止朗读并回到本章开头。")
            }
            Section {
                ForEach($draft.rules) { $rule in
                    NavigationLink {
                        PurificationRuleEditor(rule: $rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.pattern.isEmpty ? "新规则（待填写）" : rule.pattern).lineLimit(2)
                            Text("\(rule.isRegex ? "正则" : "文本") · \(rule.enabled ? "启用" : "停用") · 替换为：\(rule.replacement.isEmpty ? "删除" : rule.replacement)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let validation = rule.validationError {
                                Text(validation).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .onDelete { draft.rules.remove(atOffsets: $0) }
                .onMove { draft.rules.move(fromOffsets: $0, toOffset: $1) }
                Button("添加规则", systemImage: "plus") { draft.rules.append(TextPurificationRule()) }
                    .disabled(draft.rules.count >= 50)
            } header: { Text("本书规则 · \(draft.rules.count)/50") }
            Section {
                Picker("预览内容", selection: $showOriginal) {
                    Text("原文").tag(true)
                    Text("净化后").tag(false)
                }.pickerStyle(.segmented)
                if showOriginal {
                    TextEditor(text: $sample).frame(minHeight: 130)
                } else if let preview {
                    Text(preview.text.isEmpty ? "（净化后为空）" : preview.text).textSelection(.enabled)
                } else {
                    Text("点击预览，查看净化后的正文。")
                        .foregroundStyle(.secondary).frame(minHeight: 100)
                }
                Button(previewing ? "正在预览…" : "预览净化效果") {
                    let input = sample
                    let settings = draft
                    previewing = true
                    Task {
                        let result = await Task.detached(priority: .userInitiated) {
                            TextPurification.apply(input, settings: settings)
                        }.value
                        if draft == settings, sample == input { preview = result; showOriginal = false }
                        previewing = false
                    }
                }
                .disabled(previewing)
                if let preview {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                    }
                }
            } header: { Text("正文预览") } footer: {
                Text("优先载入当前章节的本地缓存，也可粘贴测试文本。预览不会修改正文。")
            }
        }
        .navigationTitle("文本净化")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDirty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    if isDirty { showingDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) { EditButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { saveAndClose() }.disabled(!loaded)
            }
        }
        .confirmationDialog("保存本书净化规则的修改？", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("保存修改") { saveAndClose() }
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("规则无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("继续编辑", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .task {
            guard !loaded else { return }
            draft = app.purificationSettings(for: book.id)
            baseline = draft
            loaded = true
            if let chapters = await app.store.loadChapters(bookID: book.id),
               chapters.indices.contains(book.progress.chapterIndex),
               let content = await app.store.loadContent(bookID: book.id, chapterURL: chapters[book.progress.chapterIndex].url) {
                sample = String(content.text.prefix(20000))
            }
        }
        .onChange(of: draft) { _, _ in preview = nil; error = nil }
        .onChange(of: sample) { _, _ in preview = nil }
    }

    private func saveAndClose() {
        if draft.enabled, let invalid = draft.rules.first(where: { $0.enabled && $0.validationError != nil }) {
            error = invalid.validationError
            return
        }
        app.savePurification(draft, bookID: book.id)
        baseline = draft
        dismiss()
    }
}

private struct PurificationRuleEditor: View {
    @Binding var rule: TextPurificationRule
    var body: some View {
        Form {
            Section {
                Toggle("启用规则", isOn: $rule.enabled)
                Toggle("使用正则表达式", isOn: $rule.isRegex)
            }
            Section("匹配内容") { TextEditor(text: $rule.pattern).frame(minHeight: 100).autocorrectionDisabled().textInputAutocapitalization(.never) }
            Section {
                TextEditor(text: $rule.replacement).frame(minHeight: 80).autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: { Text("替换内容（留空即删除）") } footer: {
                Text(rule.isRegex ? "支持 $1、$2 等捕获组；使用 (?m) 按行匹配、(?s) 跨行匹配。例如 (?m)^广告.*$ 可删除广告行。" : "按原样匹配和替换，标点和 $ 等符号没有特殊含义。")
            }
            if let error = rule.validationError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("净化规则")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
