#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showTOC = false

    init(book: Book, app: AppModel, startIndex: Int? = nil) {
        _model = StateObject(wrappedValue: ReaderModel(book: book, app: app, startIndex: startIndex))
    }

    private var theme: Theme { Theme.of(app.settings.reading.theme) }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if app.settings.reading.pageTurnMode == .page {
                    PagedReader(model: model, theme: theme)
                } else {
                    ReaderContent(model: model, theme: theme)
                }
                if model.speech.hasContent && (model.speech.isSpeaking || model.speech.isPaused) {
                    TTSBar(model: model, theme: theme)
                }
            }

            if model.showBars {
                VStack {
                    ReaderTopBar(
                        model: model,
                        theme: theme,
                        onClose: { dismiss() },
                        onShowTOC: { showTOC = true },
                        onShowSettings: { showSettings = true }
                    )
                    Spacer()
                    ReaderBottomBar(model: model, theme: theme)
                }
                .transition(.opacity)
            }

            if let task = model.aiTask {
                AIOverlay(task: task, progress: model.aiProgress ?? 0)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Banner(text: toast, isError: false)
                        .padding(.bottom, 120)
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(!model.showBars)
        .task { await model.start() }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTOC) {
            ChapterListView(
                book: model.book,
                chapters: model.chapters,
                currentIndex: model.currentIndex
            ) { index in
                Task { await model.loadChapter(at: index) }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
            Button("重试") { Task { await model.retry() } }
            Button("换源") {
                model.errorMessage = nil
                Task {
                    if let replacement = await model.findBetterSource() {
                        await model.applySourceSwitch(replacement)
                    }
                }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear { model.stopSpeaking() }
    }
}

// MARK: - Content

private struct ReaderContent: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    @EnvironmentObject private var app: AppModel

    private var reading: ReadingSettings { app.settings.reading }

    private var paragraphs: [String] {
        guard let text = model.content?.text else { return [] }
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var currentSentence: String? {
        guard model.speech.hasContent,
              model.speech.sentences.indices.contains(model.currentSentenceIndex) else { return nil }
        return model.speech.sentences[model.currentSentenceIndex]
    }

    private var highlightIndex: Int? {
        guard let sentence = currentSentence else { return nil }
        let probe = String(sentence.prefix(12))
        return paragraphs.firstIndex { $0.contains(probe) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isLoading && model.content == nil {
                        HStack {
                            Spacer()
                            ProgressView().padding(.top, 120)
                            Spacer()
                        }
                    }

                    if let chapter = model.currentChapter {
                        Text(chapter.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .padding(.bottom, 22)
                    }

                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(attributed(paragraph, highlighted: index == highlightIndex))
                            .font(.system(size: reading.fontSize, weight: .regular, design: .serif))
                            .lineSpacing(reading.lineSpacing)
                            .foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, reading.paragraphSpacing)
                            .id(index)
                    }

                    if model.isLoading && model.content != nil {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }

                    chapterFooter
                }
                .padding(.horizontal, reading.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.showBars.toggle()
                    }
                }
            }
            .onChange(of: model.currentIndex) { _, _ in
                proxy.scrollTo(0, anchor: .top)
            }
            .onChange(of: model.currentSentenceIndex) { _, _ in
                guard let index = highlightIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: model.content) { _, newValue in
                guard let text = newValue?.text else { return }
                restoreScroll(proxy: proxy, text: text)
            }
            .onAppear {
                if let text = model.content?.text {
                    restoreScroll(proxy: proxy, text: text)
                }
            }
        }
    }

    /// Approximate restore by character offset: the cached progress stores a
    /// character index, and the reader scrolls to the paragraph at that ratio.
    private func restoreScroll(proxy: ScrollViewProxy, text: String) {
        guard model.pendingOffset > 0, !text.isEmpty else { return }
        let lineCount = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        guard lineCount > 0 else { return }
        let fraction = min(max(Double(model.pendingOffset) / Double(max(text.count, 1)), 0), 1)
        let target = min(Int(fraction * Double(lineCount)), lineCount - 1)
        proxy.scrollTo(target, anchor: .center)
    }

    private var chapterFooter: some View {
        VStack(spacing: 12) {
            Divider().padding(.vertical, 18)
            HStack(spacing: 12) {
                Button {
                    Task { await model.goPreviousChapter() }
                } label: {
                    Label("上一章", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.currentIndex == 0)

                Button {
                    Task { await model.goNextChapter() }
                } label: {
                    Label("下一章", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.currentIndex + 1 >= model.chapters.count)
            }
            Text("\(model.currentIndex + 1) / \(model.chapters.count)")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 4)
        }
        .padding(.top, 24)
    }

    private func attributed(_ paragraph: String, highlighted: Bool) -> AttributedString {
        var attributed = AttributedString(paragraph)
        guard highlighted, let sentence = currentSentence else { return attributed }
        let probe = String(sentence.prefix(12))
        if let range = attributed.range(of: probe) {
            attributed[range].backgroundColor = theme.accent.opacity(0.22)
        }
        return attributed
    }
}

// MARK: - Bars

private struct ReaderTopBar: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    var onClose: () -> Void
    var onShowTOC: () -> Void
    var onShowSettings: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
            }
            Spacer()
            Text(model.book.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()

            Menu {
                ForEach(AIPrompt.ChapterTask.allCases) { task in
                    Button {
                        Task { await model.runAI(task: task) }
                    } label: {
                        Text("\(task.title) — \(task.detail)")
                    }
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .disabled(!app.settings.ai.isUsable || model.content == nil)

            Button(action: onShowTOC) {
                Image(systemName: "list.bullet")
            }
            Button(action: onShowSettings) {
                Image(systemName: "textformat.size")
            }
        }
        .font(.title3)
        .foregroundStyle(theme.text)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

private struct ReaderBottomBar: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: model.progressFraction)
                .tint(theme.accent)
            HStack {
                Text(model.currentChapter?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Spacer()
                Text("\(model.currentIndex + 1)/\(model.chapters.count)")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
            }
            HStack(spacing: 24) {
                Button {
                    Task { await model.goPreviousChapter() }
                } label: {
                    Image(systemName: "backward.end")
                }
                .disabled(model.currentIndex == 0)

                Button {
                    model.toggleSpeech()
                } label: {
                    Image(systemName: model.speech.isSpeaking ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(theme.accent)
                }

                Button {
                    Task { await model.goNextChapter() }
                } label: {
                    Image(systemName: "forward.end")
                }
                .disabled(model.currentIndex + 1 >= model.chapters.count)
            }
            .font(.title3)
            .foregroundStyle(theme.text)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct TTSBar: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    @EnvironmentObject private var app: AppModel

    private var sentence: String? {
        guard model.speech.sentences.indices.contains(model.currentSentenceIndex) else { return nil }
        return model.speech.sentences[model.currentSentenceIndex]
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(sentence ?? "")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 28) {
                Button { model.speech.previous() } label: {
                    Image(systemName: "backward.frame")
                }
                Button { model.speech.toggle() } label: {
                    Image(systemName: model.speech.isSpeaking ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                }
                Button { model.speech.next() } label: {
                    Image(systemName: "forward.frame")
                }

                Menu {
                    ForEach([0.35, 0.45, 0.5, 0.6, 0.75], id: \.self) { rate in
                        Button(String(format: "%.2fx", rate)) {
                            app.settings.tts.rate = rate
                            app.saveSettings()
                            model.speech.configure(app.settings.tts)
                        }
                    }
                } label: {
                    Text(String(format: "%.2fx", app.settings.tts.rate))
                        .font(.caption.monospacedDigit())
                }

                Button { model.stopSpeaking() } label: {
                    Image(systemName: "xmark")
                }
            }
            .foregroundStyle(theme.text)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct AIOverlay: View {
    let task: AIPrompt.ChapterTask
    let progress: Double

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .frame(width: 180)
            Text("AI \(task.title)中…")
                .font(.footnote)
            Text("\(Int(progress * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 12)
    }
}
#endif
