#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct TextPurificationView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var draft = TextPurificationSettings()
    @State private var loaded = false
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
                TextEditor(text: $sample).frame(minHeight: 130)
                Button(previewing ? "正在预览…" : "预览净化效果") {
                    let input = sample
                    let settings = draft
                    previewing = true
                    Task {
                        let result = await Task.detached(priority: .userInitiated) {
                            TextPurification.apply(input, settings: settings)
                        }.value
                        if draft == settings, sample == input { preview = result }
                        previewing = false
                    }
                }
                .disabled(previewing)
                if let preview {
                    Text(preview.text.isEmpty ? "（净化后为空）" : preview.text).textSelection(.enabled)
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                    }
                }
            } header: { Text("正文预览") } footer: {
                Text("优先载入当前章节的本地缓存，也可粘贴测试文本。预览不会修改正文。")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("文本净化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { EditButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    if draft.enabled, let invalid = draft.rules.first(where: { $0.enabled && $0.validationError != nil }) {
                        error = invalid.validationError
                        return
                    }
                    app.savePurification(draft, bookID: book.id)
                    dismiss()
                }.disabled(!loaded)
            }
        }
        .task {
            guard !loaded else { return }
            draft = app.purificationSettings(for: book.id)
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
