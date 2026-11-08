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
    /// The book's detail page, opened from the top menu. Shown as a sheet so
    /// the reader underneath keeps its place; closing it returns to the page.
    @State private var showBookInfo = false
    /// Fixed height of the top slot, shared by the chapter title and the
    /// toolbar so a tap swaps them without moving the text underneath.
    ///
    /// One value rather than each view padding itself: a mismatch of a few
    /// points re-paginates the chapter every time the bars appear, which looks
    /// like the page jumping.
    private static let headerSlotHeight: CGFloat = 44

    /// `3/12` for the current page, pushed up by `PagedReader`. Full-screen
    /// reading has no bottom chrome, so the page position joins the chapter
    /// title on the single line at the top.
    @State private var pageIndicator = ""

    /// - Parameter previewChapters: the table of contents a preview already
    ///   fetched. Passing it turns this into a trial read of a book that is not
    ///   on the shelf: see `ReadingMode`.
    init(
        book: Book,
        app: AppModel,
        startIndex: Int? = nil,
        previewChapters: [Chapter]? = nil
    ) {
        _model = StateObject(wrappedValue: ReaderModel(
            book: book,
            app: app,
            startIndex: startIndex,
            previewChapters: previewChapters
        ))
    }

    private var theme: Theme {
        Theme.of(resolvedTheme)
    }

    /// The paper actually on screen, after "follow system" is resolved.
    private var resolvedTheme: ReaderTheme {
        app.settings.reading.resolvedTheme(systemIsDark: systemScheme == .dark)
    }

    /// The appearance the reader is *displaying*, which is what sheets and the
    /// status bar have to follow — not the phone's setting.
    ///
    /// While "follow system" is on these are the same thing, but when it is off
    /// the phone may be in light mode while the reader is on 纯黑.
    private var isDark: Bool { resolvedTheme.isDark }

    /// The scheme to pin the reader to, or `nil` to leave it to the system.
    ///
    /// Forcing a scheme is only needed when the theme is independent of the
    /// phone. Applying it while following the system would pin the whole
    /// presentation to one appearance — `systemScheme` would then never see the
    /// phone's sunset switch, and the reader would stay white all night.
    private var forcedScheme: ColorScheme? {
        app.settings.reading.followSystemAppearance ? nil : (isDark ? .dark : .light)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // One slot, two tenants: the chapter title in full-screen
                // reading, the toolbar after a tap. Both are pinned to the same
                // height so switching between them never re-flows the page —
                // reserving space for both would leave an empty band above the
                // toolbar, which is exactly the "cramped top" this fixes.
                Group {
                    if model.showBars {
                        ReaderTopBar(
                            model: model,
                            theme: theme,
                            onClose: leaveBook,
                            onShowSettings: { showSettings = true },
                            onShowCache: { showCacheSheet = true },
                            onShowTOC: { showTOC = true },
                            onShowBookInfo: { showBookInfo = true }
                        )
                    } else {
                        ChapterHeaderTitle(
                            title: model.currentChapter?.title,
                            pageIndicator: pageIndicator,
                            isPreview: model.mode == .preview,
                            theme: theme,
                            horizontalPadding: app.settings.reading.horizontalPadding
                        )
                    }
                }
                .frame(height: Self.headerSlotHeight)
                .clipped()
                .animation(.easeInOut(duration: 0.18), value: model.showBars)

                if app.settings.reading.pageTurnMode == .page {
                    PagedReader(model: model, theme: theme, pageIndicator: $pageIndicator)
                } else {
                    // Scroll mode has no pages; a stale `3/12` left over from
                    // paged mode would be lying about the position.
                    ReaderContent(model: model, theme: theme)
                        .onAppear { pageIndicator = "" }
                }
            }

            if model.showBars {
                VStack {
                    Spacer()
                    ReaderBottomBar(
                        model: model,
                        theme: theme,
                        forcedScheme: forcedScheme,
                        onShowCache: { showCacheSheet = true }
                    )
                }
                .transition(.opacity)
            }

            if let task = model.aiTask {
                AIOverlay(task: task, progress: model.aiProgress ?? 0)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Banner(text: toast.text, isError: toast.isError)
                        .padding(.bottom, 120)
                        .transition(.opacity)
                        // A tap dismisses it: the timer below is a convenience,
                        // not the only way out.
                        .onTapGesture { model.dismissToast() }
                }
            }

            // The back gesture lives in its own strip rather than on the whole
            // view: a drag gesture laid over the content competes with the
            // scroll view and the page-turn gesture underneath it, and losing
            // that competition fails silently. A narrow strip on the left edge
            // exists only while the bars are up, which is exactly when the
            // gesture is meant to work — and it cannot steal a page turn,
            // because `PagedReader` already ignores edge drags in that state.
            if model.showBars {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: ReaderSwipe.edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(swipeBackGesture)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .statusBarHidden(!model.showBars)
        // The reader paints its own paper, so when the theme is independent of
        // the phone the system appearance has to follow it: otherwise picking
        // 深灰/纯黑 leaves a light status bar, light sheets and a light toolbar
        // material on a dark page. `forcedScheme` is nil while following the
        // system, so that mode keeps reacting to the phone.
        .preferredColorScheme(forcedScheme)
        .task { await model.start() }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .presentationDetents([.medium, .large])
                // Sheets are hosted apart from the presenting view, so
                // `preferredColorScheme` above does not reach them.
                .preferredColorScheme(forcedScheme)
        }
        .sheet(isPresented: $showCacheSheet) {
            CacheSheet(model: model)
                .presentationDetents([.medium, .large])
                .preferredColorScheme(forcedScheme)
        }
        .sheet(isPresented: $model.showSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
                .preferredColorScheme(forcedScheme)
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
            .preferredColorScheme(forcedScheme)
        }
        .sheet(isPresented: $showBookInfo) {
            // `BookDetailView` expects a surrounding navigation stack (it sets
            // a navigation title and pushes from its own rows), so the sheet
            // supplies one and a way out — without the close button the sheet
            // would have no exit of its own.
            NavigationStack {
                BookDetailView(book: model.book, allowsReading: false)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showBookInfo = false }
                        }
                    }
            }
            .preferredColorScheme(forcedScheme)
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

    /// Reading leaves through the same door as the close button, including when
    /// playback is running: dismissing the reader without stopping the audio
    /// would keep talking over the shelf.
    private func leaveBook() {
        model.stopBackgroundWork()
        dismiss()
    }

    private var swipeBackGesture: some Gesture {
        DragGesture(minimumDistance: ReaderSwipe.minimumDistance, coordinateSpace: .local)
            .onEnded { value in
                guard ReaderSwipe.isBackSwipe(
                    startX: value.startLocation.x,
                    translation: value.translation,
                    barsVisible: model.showBars
                ) else { return }
                leaveBook()
            }
    }
}

// MARK: - Content

private struct ReaderContent: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    @EnvironmentObject private var app: AppModel

    /// How far the scroll view has moved, and how tall its content is.
    ///
    /// Scroll mode has no pages, so this is the only way the bottom bar can
    /// report a chapter position: `PagedReader` publishes it in page mode, and
    /// without a counterpart here the bar sat at zero for the whole chapter.
    private struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    private struct ScrollMetricsKey: PreferenceKey {
        static var defaultValue = ScrollMetrics()

        static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
            let next = nextValue()
            if next.contentHeight > 0 { value = next }
        }
    }

    private struct ViewportKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            let next = nextValue()
            if next > 0 { value = next }
        }
    }

    private static let scrollSpace = "reader.scroll"

    @State private var viewportHeight: CGFloat = 0

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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollMetricsKey.self,
                            value: ScrollMetrics(
                                offset: -geo.frame(in: .named(Self.scrollSpace)).minY,
                                contentHeight: geo.size.height
                            )
                        )
                    }
                )
            }
            .coordinateSpace(name: Self.scrollSpace)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ViewportKey.self) { height in
                if abs(viewportHeight - height) > 0.5 { viewportHeight = height }
            }
            .onPreferenceChange(ScrollMetricsKey.self) { metrics in
                publishScrollProgress(metrics)
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

    /// Feeds the bottom bar when scrolling rather than turning pages.
    ///
    /// Clamped, and only written when it moves by a visible amount: the
    /// preference fires on every scroll tick, and pushing a new value into the
    /// observed model re-renders the whole reader.
    private func publishScrollProgress(_ metrics: ScrollMetrics) {
        guard let text = model.content?.text, !text.isEmpty,
              metrics.contentHeight > 0, viewportHeight > 0 else { return }
        let scrollable = max(metrics.contentHeight - viewportHeight, 1)
        let progress = min(max(Double(metrics.offset / scrollable), 0), 1)
        if abs(model.chapterProgress - progress) > 0.005 {
            model.chapterProgress = progress
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
/// chapter title on the left, page position on the right. Everything else —
/// book name, TOC, AI, source, cache, settings, playback — appears only after a
/// tap. It is a separate view from `ReaderTopBar` so the full-screen state
/// cannot drift back into a toolbar as buttons get added there.
private struct ChapterHeaderTitle: View {
    let title: String?
    /// `3/12` within the chapter, empty in scroll mode where there are no pages.
    let pageIndicator: String
    /// Trial reads are labelled here: the page is otherwise identical to a
    /// shelf book's, and "was this saved?" is the one thing a reader needs to
    /// know while deciding.
    var isPreview: Bool = false
    let theme: Theme
    /// Lines the title up with the body text instead of centring it: a centred
    /// line above a left-aligned page reads as a label, not as part of the page.
    let horizontalPadding: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Text(title ?? "")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if isPreview {
                Text("试读")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .fixedSize()
            }

            if !pageIndicator.isEmpty {
                Text(pageIndicator)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }
        }
        .padding(.horizontal, horizontalPadding)
    }
}

/// The tap-to-reveal toolbar.
///
/// One compact row: dismiss, the chapter title, and a menu. The title used to be
/// squeezed between a centred title/book-name stack and four icon buttons, so it
/// truncated exactly when you wanted it (long Chinese chapter titles). Secondary
/// actions — source, cache, AI, settings — do not need to be one tap away while
/// reading, so they moved into the menu, and the width they freed goes to the
/// title.
private struct ReaderTopBar: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    var onClose: () -> Void
    var onShowSettings: () -> Void
    var onShowCache: () -> Void
    /// Opens the chapter list. Shown here rather than in the bottom bar: that
    /// bar is what tips the page over, this one is where you go to move.
    var onShowTOC: () -> Void
    /// The overflow menu keeps the entry points that have no button of their
    /// own: book info, cache, AI cleanup and the output format.
    var onShowBookInfo: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            // Back to the shelf, with a chevron rather than the old down arrow:
            // this bar is a way out of the book, and the arrow now points the
            // way the gesture and every other app's back button point.
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("返回书架")

            // The chapter title stays, small, right after the chevron.
            //
            // With the bars up this is the only place it appears at all: the
            // page draws the chapter name nowhere else, because printing it both
            // in the header and above the first paragraph used to show it twice.
            // Dropping it here instead would leave no way to tell which chapter
            // is open.
            Text(model.currentChapter?.title ?? model.book.name)
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 72, alignment: .leading)
                // Gives way before the buttons do: the words are a reminder,
                // the buttons are how the reader moves.
                .layoutPriority(-1)

            topActions

            Spacer(minLength: 4)

            if model.mode == .preview {
                Text("试读")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .fixedSize()
                    .padding(.trailing, 4)
            }

            overflowMenu
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial)
    }

    /// The few actions worth a tap from the reading screen.
    ///
    /// Ordered by how often they are wanted mid-chapter: the chapter list and
    /// the chapter's own settings first, then switching sources — the one move
    /// that fixes a page that loaded wrong.
    private var topActions: some View {
        HStack(spacing: 2) {
            TopBarButton(title: "目录", systemImage: "list.bullet", theme: theme) {
                onShowTOC()
            }

            TopBarButton(title: "设置", systemImage: "textformat.size", theme: theme) {
                onShowSettings()
            }

            TopBarButton(title: "换源", systemImage: "arrow.left.arrow.right", theme: theme) {
                model.showSourcePicker = true
            }
            .disabled(model.mode != .shelf)
            .opacity(model.mode == .shelf ? 1 : 0.35)
        }
    }

    /// What is left once the common actions have their own buttons.
    private var overflowMenu: some View {
        Menu {
            Button {
                onShowBookInfo()
            } label: {
                Label("书籍信息", systemImage: "info.circle")
            }

            Button {
                onShowCache()
            } label: {
                Label(
                    model.cachedChapterCount > 0 ? "缓存（已存 \(model.cachedChapterCount) 章）" : "缓存本章",
                    systemImage: "arrow.down.circle"
                )
            }
            .disabled(model.mode != .shelf)

            SwiftUI.Section("AI 整理") {
                ForEach(AIPrompt.ChapterTask.manualTasks) { task in
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
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多操作")
    }
}

/// An icon plus its name, sized to fit the 44 pt header slot.
///
/// Smaller and tighter than `ReaderBarButton`: five of these share a strip that
/// is one row tall, so the label has to sit directly under a 20 pt icon rather
/// than under a 40 pt tap target.
private struct TopBarButton: View {
    let title: String
    let systemImage: String
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(minWidth: 44)
            .padding(.horizontal, 4)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ReaderBottomBar: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    /// Pinned appearance for this bar's own sheet; see `ReaderView.forcedScheme`.
    let forcedScheme: ColorScheme?
    /// The TOC moved to the top bar, which now carries the actions reached
    /// mid-chapter; only the cache sheet is still launched from here.
    var onShowCache: () -> Void
    @State private var showSpeechSettings = false

    /// Chapter title and position live in one view for both modes.
    ///
    /// While speaking this bar is the speech remote; otherwise it is the plain
    /// reader bar. Keeping one bar instead of stacking two means the page never
    /// changes height when playback starts, which used to re-flow the
    /// pagination mid-chapter.
    private var isSpeaking: Bool { model.speech.showsHighlight }

    var body: some View {
        VStack(spacing: 6) {
            // Progress row: the bar reads as a status line first, controls second.
            HStack(spacing: 10) {
                // The bar follows the chapter, because that is the span a reader
                // can still judge by eye — how much of *this* chapter is left.
                // Whole-book position goes beside it as a number, where an
                // approximation is all it needs to be.
                ProgressView(value: model.chapterProgress)
                    .tint(theme.accent)
                    .layoutPriority(-1)
                // The percentage sits where "12/345" used to: a chapter number
                // over the book's total described a different thing from the bar
                // next to it, and read as if the bar were the whole book.
                Text("本章 \(Int((model.chapterProgress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                Text("全书 \(model.bookProgressPercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }

            if isSpeaking {
                speechControls
            } else {
                readingControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showSpeechSettings) {
            SpeechSettingsSheet(speech: model.speech)
                .presentationDetents([.medium, .large])
                // The sheet is hosted apart from the reader, so the reader's
                // own color scheme does not reach it.
                .preferredColorScheme(forcedScheme)
        }
    }

    // MARK: - Idle controls

    /// Five cells, one per thing you reach for while reading.
    ///
    /// Three big buttons left the bar mostly empty and put the two chapter
    /// arrows at the edges, where a thumb has the worst reach. Filling the row
    /// with labelled cells also makes the icons self-explanatory: an unlabelled
    /// `backward.end` is not obviously "previous chapter".
    private var readingControls: some View {
        HStack(spacing: 0) {
            ReaderBarButton(title: "上一章", systemImage: "backward.end", theme: theme) {
                Task { await model.goPreviousChapter() }
            }
            .disabled(model.currentIndex == 0)
            .opacity(model.currentIndex == 0 ? 0.35 : 1)

            Button {
                model.toggleSpeech()
            } label: {
                VStack(spacing: ReaderBarButton.labelGap) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.background)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(theme.accent))
                        .frame(height: ReaderBarButton.iconHeight)
                        .contentShape(Circle())
                    Text("朗读")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("开始朗读")

            ReaderBarButton(
                title: model.cachedChapterCount > 0 ? "已缓存" : "缓存",
                systemImage: model.cachedChapterCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                theme: theme
            ) {
                onShowCache()
            }
            .disabled(model.mode != .shelf)
            .opacity(model.mode == .preview ? 0.35 : 1)

            ReaderBarButton(title: "下一章", systemImage: "forward.end", theme: theme) {
                Task { await model.goNextChapter() }
            }
            .disabled(model.currentIndex + 1 >= model.chapters.count)
            .opacity(model.currentIndex + 1 >= model.chapters.count ? 0.35 : 1)
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
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 52))
            .disabled(model.currentIndex == 0)
            .opacity(model.currentIndex == 0 ? 0.4 : 1)

            Spacer(minLength: 6)

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

            Spacer(minLength: 6)

            Button {
                Task { await model.goNextChapter(autoPlaySpeech: true) }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 52))
            .disabled(model.currentIndex + 1 >= model.chapters.count)
            .opacity(model.currentIndex + 1 >= model.chapters.count ? 0.4 : 1)

            Spacer(minLength: 6)

            Button { showSpeechSettings = true } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 18))
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 44))
            .accessibilityLabel("朗读设置")

            Spacer(minLength: 6)

            // Leaving playback is a transport action, so it belongs with the
            // other controls. It used to share the status row with the
            // progress bar, where it read as a label and squeezed the numbers.
            Button { model.stopSpeaking() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18))
            }
            .buttonStyle(SpeechButtonStyle(theme: theme, diameter: 44))
            .accessibilityLabel("退出朗读")
        }
        .foregroundStyle(theme.text)
    }
}

/// One labelled cell of the reading bar: icon, then the word for it.
///
/// Equal-width cells with the icon centred over its label; using `maxWidth:
/// .infinity` rather than fixed frames lets five of them share the row evenly on
/// every phone width without hand-tuned spacing. The icon box and gap are shared
/// constants so the centre play button — which is a filled circle rather than a
/// glyph — still sits on the same baseline as its neighbours.
private struct ReaderBarButton: View {
    static let iconHeight: CGFloat = 40
    static let labelGap: CGFloat = 3

    let title: String
    let systemImage: String
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Self.labelGap) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .frame(height: Self.iconHeight)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
