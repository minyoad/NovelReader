#if canImport(SwiftUI)
import SwiftUI
import NovelKit

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Only consulted when "follow system" is on; when it is off the reader
    /// owns its appearance and this is ignored.
    @Environment(\.colorScheme) private var systemScheme
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var showCacheSheet = false

    init(book: Book, app: AppModel, startIndex: Int? = nil) {
        _model = StateObject(wrappedValue: ReaderModel(book: book, app: app, startIndex: startIndex))
    }

    private var theme: Theme {
        Theme.of(app.settings.reading, systemIsDark: systemScheme == .dark)
    }

    /// The appearance the reader is *displaying*, which is what sheets and the
    /// status bar have to follow — not the phone's setting.
    ///
    /// While "follow system" is on these are the same thing, but when it is off
    /// the phone may be in light mode while the reader is on 纯黑.
    private var isDark: Bool { theme.resolved.isDark }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // The chapter title is the only chrome in full-screen reading.
                // It sits in the layout rather than floating over the text, so
                // pagination reserves the same height whether or not the bars
                // are showing — otherwise a tap would re-flow the page.
                ChapterHeaderTitle(
                    title: model.currentChapter?.title,
                    visible: !model.showBars,
                    theme: theme
                )

                if app.settings.reading.pageTurnMode == .page {
                    PagedReader(model: model, theme: theme)
                } else {
                    ReaderContent(model: model, theme: theme)
                }
            }

            if model.showBars {
                VStack {
                    ReaderTopBar(
                        model: model,
                        theme: theme,
                        onClose: { dismiss() },
                        onShowTOC: { showTOC = true },
                        onShowSettings: { showSettings = true },
                        onShowCache: { showCacheSheet = true }
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
        // The reader paints its own paper, so the system appearance has to be
        // driven by the chosen theme rather than by the phone's setting. Without
        // this, picking 深灰/纯黑 left a light status bar, light sheets and
        // light toolbar material on a dark page.
        .preferredColorScheme(isDark ? .dark : .light)
        .task { await model.start() }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.medium, .large])
                // Sheets are hosted apart from the presenting view, so
                // `preferredColorScheme` above does not reach them.
                .preferredColorScheme(isDark ? .dark : .light)
        }
        .sheet(isPresented: $showCacheSheet) {
            CacheSheet(model: model)
                .presentationDetents([.medium, .large])
                .preferredColorScheme(isDark ? .dark : .light)
        }
        .sheet(isPresented: $model.showSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
                .preferredColorScheme(isDark ? .dark : .light)
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
            .preferredColorScheme(isDark ? .dark : .light)
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
            Button("重试") { Task { await model.retry() } }
            Button("换源") {
                model.errorMessage = nil
                model.showSourcePicker = true
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear {
            model.stopBackgroundWork()
            app.saveSettings()
        }
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

    /// Body font mirroring `PagedDocument.bodyFont`, so both page-turn modes
    /// look the same. SwiftUI cannot indent only the first line, so the indent
    /// is applied with a leading ideographic space in scroll mode.
    private var bodyFont: Font {
        let size = reading.fontSize
        if let family = reading.fontFamily {
            if family == "-apple-system" {
                return .system(size: size, weight: .regular)
            }
            if UIFont(name: family, size: size) != nil {
                return .custom(family, size: size)
            }
        }
        return .system(size: size, weight: .regular, design: .serif)
    }

    private func displayed(_ paragraph: String) -> String {
        reading.firstLineIndent ? "　　" + paragraph : paragraph
    }

    private var currentSentence: String? {
        guard model.speech.showsHighlight,
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

                    // Chapter title: drawn in the reader's header slot, not
                    // here. Repeating it would print the heading twice at the
                    // top of a chapter and cost a paragraph of screen space.
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(attributed(displayed(paragraph), highlighted: index == highlightIndex))
                            .font(bodyFont)
                            .lineSpacing(reading.lineSpacing)
                            .multilineTextAlignment(.leading)
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

/// The single line of chrome shown while reading full screen.
///
/// Full-screen reading means the page and, at most, where you are in the book:
/// the chapter title. Everything else — book name, TOC, AI, source, cache,
/// settings, playback — appears only after a tap. It is a separate view from
/// `ReaderTopBar` so the full-screen state cannot drift back into a toolbar as
/// buttons get added there.
private struct ChapterHeaderTitle: View {
    let title: String?
    /// Hidden while `ReaderTopBar` is showing, since that bar already names the
    /// chapter directly below this slot.
    let visible: Bool
    let theme: Theme

    var body: some View {
        Text(title ?? "")
            .font(.footnote)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            // The slot keeps its height when hidden so that tapping the page
            // does not shift the text under the finger.
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: visible)
            .accessibilityHidden(!visible)
    }
}

private struct ReaderTopBar: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    var onClose: () -> Void
    var onShowTOC: () -> Void
    var onShowSettings: () -> Void
    var onShowCache: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
            }
            Spacer()
            Button {
                onShowTOC()
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(model.currentChapter?.title ?? model.book.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    // The chapter is what changes as you read; the book name is
                    // the context you need once, so it sits underneath in the
                    // quieter style rather than competing for the same line.
                    if !model.book.name.isEmpty {
                        Text(model.book.name)
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("目录 · \(model.currentChapter?.title ?? model.book.name)")
            Spacer()

            Menu {
                SwiftUI.Section("AI 整理") {
                    ForEach(AIPrompt.ChapterTask.allCases) { task in
                        Button {
                            Task { await model.runAI(task: task) }
                        } label: {
                            Text("\(task.title) — \(task.detail)")
                        }
                    }
                }

                SwiftUI.Section("格式") {
                    ForEach(AIPrompt.OutputFormat.allCases) { format in
                        Button {
                            app.settings.aiOutputFormat = format
                            app.saveSettings()
                        } label: {
                            if app.settings.aiOutputFormat == format {
                                Label(format.displayName, systemImage: "checkmark")
                            } else {
                                Text(format.displayName)
                            }
                        }
                    }
                }

                if model.content?.originalText != nil {
                    SwiftUI.Section {
                        Button {
                            Task { await model.restoreOriginalText() }
                        } label: {
                            Label("还原为站点原文", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            } label: {
                Image(systemName: model.content?.cleaned == true ? "sparkles" : "wand.and.stars")
            }
            .disabled(model.content == nil || (!app.settings.ai.isUsable && model.content?.originalText == nil))

            Button {
                model.showSourcePicker = true
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }

            Button(action: onShowCache) {
                Image(systemName: model.cachedChapterCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
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
    @State private var showSpeechSettings = false

    /// Chapter title and position live in one view for both modes.
    ///
    /// While speaking this bar is the speech remote; otherwise it is the plain
    /// reader bar. Keeping one bar instead of stacking two means the page never
    /// changes height when playback starts, which used to re-flow the
    /// pagination mid-chapter.
    private var isSpeaking: Bool { model.speech.showsHighlight }

    var body: some View {
        VStack(spacing: 10) {
            // Progress and position share a row: with the chapter title moved to
            // the top bar there is no longer a line's worth of text to hold the
            // bar open, and an empty-looking row made the bar taller than it is
            // useful.
            HStack(spacing: 10) {
                ProgressView(value: model.progressFraction)
                    .tint(theme.accent)
                Text("\(model.currentIndex + 1)/\(model.chapters.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                if isSpeaking {
                    // Exit sits here rather than in the transport row: an
                    // overlay above those buttons would steal their taps, and
                    // the row itself needs its full width.
                    Button { model.stopSpeaking() } label: {
                        Label("退出", systemImage: "xmark.circle")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                    }
                    .foregroundStyle(theme.secondaryText)
                }
            }

            if isSpeaking {
                speechControls
            } else {
                readingControls
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showSpeechSettings) {
            SpeechSettingsSheet(speech: model.speech)
                .presentationDetents([.medium, .large])
                // The sheet is hosted apart from the reader, so the reader's
                // own color scheme does not reach it.
                .preferredColorScheme(theme.resolved.isDark ? .dark : .light)
        }
    }

    // MARK: - Idle controls

    private var readingControls: some View {
        HStack(spacing: 20) {
            // Big hit areas on purpose: this bar is the one a driver uses, and
            // the stock toolbar size is unusable at arm's length.
            Button {
                Task { await model.goPreviousChapter() }
            } label: {
                Image(systemName: "backward.end")
                    .font(.system(size: 22))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .disabled(model.currentIndex == 0)
            .opacity(model.currentIndex == 0 ? 0.4 : 1)

            Button {
                model.toggleSpeech()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(theme.accent)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }

            Button {
                Task { await model.goNextChapter() }
            } label: {
                Image(systemName: "forward.end")
                    .font(.system(size: 22))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .disabled(model.currentIndex + 1 >= model.chapters.count)
            .opacity(model.currentIndex + 1 >= model.chapters.count ? 0.4 : 1)
        }
        .foregroundStyle(theme.text)
    }

    // MARK: - Speaking controls

    /// Same bar, now driving the speech.
    ///
    /// Four buttons, not five: sentence-level nudging now lives where the system
    /// puts it (headphone double-click, Lock Screen skip), and the space it freed
    /// goes to the settings entry — changing voice or speed is the thing you
    /// actually reach for while listening, and it used to require leaving the
    /// book and stopping the reading.
    private var speechControls: some View {
        HStack(spacing: 0) {
            Button {
                Task { await model.goPreviousChapter(autoPlaySpeech: true) }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 56))
            .disabled(model.currentIndex == 0)
            .opacity(model.currentIndex == 0 ? 0.4 : 1)

            Spacer(minLength: 8)

            Button { model.speech.toggle() } label: {
                if model.speech.isPreparing {
                    // Remote engines need a moment before the first sound; a
                    // spinner explains the silence instead of looking like the
                    // button did nothing.
                    ProgressView()
                        .tint(theme.accent)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: model.speech.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                }
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 68, filled: true))

            Spacer(minLength: 8)

            Button {
                Task { await model.goNextChapter(autoPlaySpeech: true) }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 56))
            .disabled(model.currentIndex + 1 >= model.chapters.count)
            .opacity(model.currentIndex + 1 >= model.chapters.count ? 0.4 : 1)

            Spacer(minLength: 8)

            Button { showSpeechSettings = true } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 19))
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 48))
            .accessibilityLabel("朗读设置")
        }
        .foregroundStyle(theme.text)
    }
}

/// Round, high-contrast button used by the speech bar.
///
/// A custom style rather than the stock ones because the stock hit area follows
/// the glyph: at 56pt the tap target has to come from the background, not from
/// a larger symbol.
private struct SpeechButtonStyle: ButtonStyle {
    let theme: Theme
    let diameter: CGFloat
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? theme.background : theme.text)
            .frame(width: diameter, height: diameter)
            .background {
                if filled {
                    Circle().fill(theme.accent)
                } else {
                    Circle().fill(theme.text.opacity(0.08))
                }
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
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
