#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import NovelKit

/// Horizontal page-turning reader. Text is laid out with CoreText
/// (`PageLayout`) so the drawn pages match the measured slices exactly, and the
/// character offsets map back to the chapter text for progress and TTS.
struct PagedReader: View {
    @ObservedObject var model: ReaderModel
    let theme: Theme
    /// Written on every page change so the reader header can show `3/12`
    /// alongside the chapter title. There is no page footer any more.
    @Binding var pageIndicator: String
    @EnvironmentObject private var app: AppModel

    @State private var document: PagedDocument?
    @State private var pages: [ReaderPage] = []
    @State private var pageIndex = 0
    @State private var drag: CGFloat = 0
    /// Last character offset written to the library, so repeated layout passes
    /// that land on the same page do not each rewrite the shelf.
    @State private var lastSavedOffset: Int?
    @State private var isAnimating = false
    /// Width of the page in points; captured from the gesture so the drag
    /// progress can be normalised without recomputing layout.
    @State private var pagesWidth: CGFloat = 1
    /// Styled pages around the visible one, keyed by page index.
    ///
    /// Filled when the page changes or when a turn starts — never while a frame
    /// is being drawn. Styling copies an attributed slice and walks it, so doing
    /// it inside `body` or inside the frame that has to react to the finger is
    /// what made the turn stall.
    @State private var pageText: [Int: StagedPage] = [:]
    /// What is left of the page a chapter-boundary swipe started on, so the
    /// reader keeps showing it while the next chapter loads.
    @State private var leaving: NSAttributedString?
    /// The page the turn is settling onto. `pageIndex` only moves once the
    /// animation has finished, so this is what the layer underneath shows in
    /// the meantime.
    @State private var turnTarget: Int?
    /// Direction of the turn being settled. `drag` is back at zero by then, so
    /// it can no longer say which way the page is going.
    @State private var turnForward: Bool?
    /// A distance being animated to and back, held in its own state.
    ///
    /// `drag` follows the finger with no animation (a spring on top of a gesture
    /// is a fight between the finger and the animator). The finish of a turn is
    /// animated on this separate value instead, so exactly one driver moves the
    /// page at a time and the swipe never stalls just before the page goes.
    @State private var turn: CGFloat = 0
    @State private var boundaryPreview: NSAttributedString?
    @State private var boundaryTargetURL: String?
    @State private var isVisible = false
    @State private var isLayingOut = false
    @State private var layoutRequestID = UUID()
    @State private var preparedChapters: [String: PreparedChapter] = [:]

    private struct LayoutRequest: Equatable {
        let layout: LayoutKey
        let positionRevision: Int
        let isLoading: Bool
    }
    @State private var laidOutPositionRevision = -1

    private struct PreparedChapter {
        let key: LayoutKey
        let document: PagedDocument
        let pages: [ReaderPage]
    }

    private var reading: ReadingSettings { app.settings.reading }

    var body: some View {
        GeometryReader { proxy in
            let box = contentSize(in: proxy.size)
            ZStack {
                theme.background

                if model.content == nil {
                    if model.isLoading {
                        ProgressView()
                    } else if let message = model.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(32)
                    }
                } else {
                    pageLayers(box: box)
                }

                if model.isLoading && model.content != nil && boundaryPreview == nil {
                    ProgressView()
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(turnGesture(box: box))
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.showBars.toggle()
                    }
                }
            )
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                layoutRequestID = UUID()
            }
            .task(id: LayoutRequest(layout: layoutKey(box), positionRevision: model.positionRevision, isLoading: model.isLoading)) {
                await paginate(box: box)
                guard !Task.isCancelled else { return }
                await prepareAdjacentChapters(box: box)
            }
            .onChange(of: pageIndex) { _, _ in
                refreshStaging()
                syncPageIndicator()
                // Keeps `pendingOffset` on the visible page no matter what
                // moved it: a swipe, the speech follow-along, or repagination
                // after a font change. Pressing read then starts from the page
                // on screen instead of wherever the offset happened to be.
                saveProgress()
            }
            .onChange(of: model.speech.isActive) { _, active in
                // Playback ending is a page change in every way that matters:
                // the visible page is a different one than when reading began,
                // and `pageIndex` does not change to say so. Sync here or the
                // next press reads from wherever the old session left off.
                guard !active else { return }
                saveProgress()
            }
            .onChange(of: model.currentSentenceIndex) { _, _ in
                followSpeech(box: box)
            }
        }
    }

    // MARK: - Layout inputs

    private func contentSize(in available: CGSize) -> CGSize {
        // No footer to reserve: the page number moved into the reader header, so
        // the page finally uses the whole area between the header and the home
        // indicator.
        CGSize(
            width: max(available.width - reading.horizontalPadding * 2, 0),
            height: max(available.height, 0)
        )
    }

    private struct LayoutKey: Equatable {
        var url: String
        /// AI cleanup replaces the text while keeping the same chapter URL, so
        /// the content itself has to participate in the key.
        var contentHash: Int
        var width: Int
        var height: Int
        var fontSize: Double
        var lineSpacing: Double
        var paragraphSpacing: Double
        var horizontalPadding: Double
        var theme: String
        var fontFamily: String
        var firstLineIndent: Bool
        var alignment: String
    }

    private func layoutKey(_ box: CGSize, content: ChapterContent? = nil) -> LayoutKey {
        return LayoutKey(
            url: (content ?? model.content)?.chapterURL ?? "",
            contentHash: content?.text.hashValue ?? model.contentFingerprint,
            width: Int(box.width.rounded()),
            height: Int(box.height.rounded()),
            fontSize: reading.fontSize,
            lineSpacing: reading.lineSpacing,
            paragraphSpacing: reading.paragraphSpacing,
            horizontalPadding: reading.horizontalPadding,
            theme: theme.resolved.rawValue,
            fontFamily: reading.fontFamily ?? "",
            firstLineIndent: reading.firstLineIndent,
            alignment: reading.alignment.rawValue
        )
    }

    // MARK: - Pages

    private var currentPage: ReaderPage? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
    }

    private func neighbor(forward: Bool) -> Int? {
        let candidate = forward ? pageIndex + 1 : pageIndex - 1
        return pages.indices.contains(candidate) ? candidate : nil
    }

    /// Which way the page is going.
    ///
    /// `drag` is zeroed when the finger lifts (`snapBack`), so it stops meaning
    /// anything the moment the finish animation starts; without `turnForward`
    /// the release would pick the neighbour on the wrong side and the page
    /// behind would show the previous page instead of the next one.
    private var isForward: Bool {
        if let turnForward { return turnForward }
        return drag < 0
    }

    /// Where the page is right now: under the finger while dragging, or being
    /// animated away while a turn finishes.
    private var pageOffset: CGFloat { drag + turn }

    private var dragProgress: CGFloat {
        min(abs(pageOffset) / max(pagesWidth, 1), 1)
    }

    /// The page that is revealed by the moving sheet: the turn's destination
    /// while it settles, otherwise the neighbour on the side being pulled.
    private func revealedIndex() -> Int? {
        turnTarget ?? neighbor(forward: isForward)
    }

    private func pageLayers(box: CGSize) -> some View {
        if reading.pageTurnEffect == .curl {
            return AnyView(curlLayers(box: box))
        }
        return AnyView(slideLayers(box: box))
    }

    /// The cover model, with every participant of a turn mounted for the whole
    /// chapter: the current sheet, and both neighbours parked a page-width off
    /// the side they would be revealed from.
    ///
    /// A drag then only moves offsets. The earlier version inserted the
    /// revealed page into the hierarchy on the first frame the finger moved —
    /// creating that view, and running its first CoreText draw, mid-gesture is
    /// what made every turn start with a hitch and trail the finger.
    private func slideLayers(box: CGSize) -> some View {
        let forward = isForward
        let moving = abs(pageOffset) > 0.5 || isAnimating
        // Stable identities: the sheet the finger holds and its two neighbours
        // keep their views across commits, so a turn moves offsets only — no
        // view is created or redrawn while the finger is down. The page
        // revealed underneath sits at the origin; its twin is parked a
        // page-width off the far side, and both twins swap places on the first
        // frame of a gesture while the sheet still covers the screen.
        return ZStack {
            ForEach(slots(forward: forward), id: \.self) { index in
                pageImage(text: text(at: index), paper: theme.background)
                    .offset(x: slotOffset(index, box: box, forward: forward, moving: moving))
                    .zIndex(index == pageIndex ? 2 : 1)
            }

            if moving {
                if let boundaryPreview {
                    pageImage(text: boundaryPreview, paper: theme.background)
                        .zIndex(1)
                } else if neighbor(forward: forward) == nil {
                    // End of chapter: the hint card is what comes next.
                    chapterHint(forward: forward, box: box)
                        .zIndex(1)
                }
            }
        }
        .frame(width: box.width, height: box.height)
        // The parked neighbours live a page-width off to each side. Without a
        // clip here they keep drawing in the screen's margins — the reader
        // would see the last column of the previous page and the first column
        // of the next one down either edge.
        .clipped()
    }

    /// The three pages that can take part in a turn: the sheet on the finger
    /// and the neighbours on either side.
    private func slots(forward: Bool) -> [Int] {
        var result = [pageIndex]
        if let target = turnTarget { result.append(target) }
        for candidate in [pageIndex - 1, pageIndex + 1] where pages.indices.contains(candidate) {
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    /// Where a participant of the cover model sits this frame.
    private func slotOffset(
        _ index: Int,
        box: CGSize,
        forward: Bool,
        moving: Bool
    ) -> CGFloat {
        if index == pageIndex { return pageOffset }
        let revealed = turnTarget ?? (pageIndex + (forward ? 1 : -1))
        if moving, index == revealed, pages.indices.contains(revealed) { return 0 }
        return index < pageIndex ? -box.width : box.width
    }

    /// Text for the top layer. A chapter-boundary swipe keeps drawing the page
    /// it started on while the next chapter loads, even after the content under
    /// it has been replaced.
    private var topText: NSAttributedString {
        leaving ?? text(at: pageIndex)
    }

    /// Paper-curl mode. The sheet and the page it reveals are drawn by
    /// `CurledPage` from the same page images, so the fold never disagrees with
    /// the finger and the print stays aligned with the paginator's slices.
    ///
    /// At a chapter boundary there is no neighbouring page to reveal, so the
    /// hint card takes over and the current page just slides with the finger —
    /// curling would have nothing to fold onto.
    private func curlLayers(box: CGSize) -> some View {
        let forward = isForward
        let hasNeighbor = revealedIndex() != nil || boundaryPreview != nil

        return ZStack {
            if hasNeighbor {
                CurledPage(
                    settledText: currentText,
                    neighborText: neighborText(forward: forward),
                    progress: dragProgress,
                    forward: forward,
                    paper: theme.background
                )
                .frame(width: box.width, height: box.height)
            } else {
                if abs(pageOffset) > 0.5 {
                    chapterHint(forward: forward, box: box)
                        .offset(x: forward ? box.width : -box.width)
                        .offset(x: pageOffset)
                }
                pageImage(text: currentText, paper: theme.background)
                    .offset(x: pageOffset)
            }
        }
        .frame(width: box.width, height: box.height)
    }

    /// The page on screen, from the cache; `preparePages` fills it before an
    /// index is committed, so this never styles a page inside a frame.
    private var currentText: NSAttributedString {
        leaving ?? text(at: pageIndex)
    }

    /// Styled page text for the page at `index`, from the page cache.
    ///
    /// Falls back to styling only when the cache was not prepared (first frame
    /// after a repagination); the normal paths all prefill it.
    private func text(at index: Int) -> NSAttributedString {
        guard let document, pages.indices.contains(index) else { return NSAttributedString() }
        let key = stagingKey(for: index)
        if let cached = pageText[index], cached.key == key {
            return cached.text
        }
        return styledPage(document: document, page: pages[index])
    }

    /// Identity of a styled page: everything that changes how it draws.
    private func stagingKey(for index: Int) -> StagingKey {
        let document = self.document
        return StagingKey(
            url: document?.chapterURL ?? "",
            index: index,
            pageCount: pages.count,
            highlight: model.speech.showsHighlight ? model.currentSentenceIndex : -1,
            firstLine: pages.indices.contains(index)
                ? document?.characterOffset(atAttributed: pages[index].range.location) ?? -1
                : -1,
            accent: theme.resolved.rawValue
        )
    }

    /// Styles the visible page and both of its neighbours.
    ///
    /// Called when the page changes and when a drag begins — the two moments
    /// where a CoreText pass is harmless — so the frames that must follow the
    /// finger never wait on one.
    private func preparePages(around index: Int) {
        guard let document, pages.indices.contains(index) else {
            pageText = [:]
            return
        }
        var prepared: [Int: StagedPage] = [:]
        for candidate in [index - 1, index, index + 1] where pages.indices.contains(candidate) {
            let key = stagingKey(for: candidate)
            if let cached = pageText[candidate], cached.key == key {
                prepared[candidate] = cached
            } else {
                prepared[candidate] = StagedPage(key: key, text: styledPage(document: document, page: pages[candidate]))
            }
        }
        pageText = prepared
    }

    /// Re-centres the page cache after something other than a turn moved the
    /// visible page.
    ///
    /// A turn does not use this: it installs its destination as part of the
    /// same transaction that moves `pageIndex`, so there is never a frame in
    /// which the new index is live but the cache still holds the old page.
    private func refreshStaging() {
        guard pages.indices.contains(pageIndex) else {
            pageText = [:]
            return
        }
        let needed = [pageIndex - 1, pageIndex, pageIndex + 1].filter { pages.indices.contains($0) }
        let covered = needed.allSatisfy { index in
            guard let cached = pageText[index] else { return false }
            return cached.key == stagingKey(for: index)
        }
        guard !covered else { return }
        preparePages(around: pageIndex)
    }

    /// Styles the visible page if the cache lost it, then the page on the given
    /// side. Called when a drag starts, never per frame.
    private func prepareNeighbor(forward: Bool) {
        guard let document, let current = currentPage else { return }
        let currentKey = stagingKey(for: pageIndex)
        if pageText[pageIndex]?.key != currentKey {
            pageText[pageIndex] = StagedPage(
                key: currentKey,
                text: styledPage(document: document, page: current)
            )
        }
        guard let index = neighbor(forward: forward) else { return }
        let key = stagingKey(for: index)
        if pageText[index]?.key != key {
            pageText[index] = StagedPage(
                key: key,
                text: styledPage(document: document, page: pages[index])
            )
        }
    }

    private struct StagedPage {
        var key: StagingKey
        var text: NSAttributedString
    }

    private struct StagingKey: Equatable {
        var url: String
        var index: Int
        var pageCount: Int
        var highlight: Int
        var firstLine: Int
        var accent: String
    }

    /// The page revealed by the sheet being pulled away.
    private func neighborText(forward: Bool) -> NSAttributedString {
        guard let index = revealedIndex() else { return boundaryPreview ?? NSAttributedString() }
        return text(at: index)
    }

    private func pageImage(document: PagedDocument, page: ReaderPage) -> some View {
        pageImage(text: styledPage(document: document, page: page), paper: theme.background)
    }

    private func pageImage(text: NSAttributedString, paper: Color) -> some View {
        // `paper` matters beyond the curl: in slide mode the incoming page sits
        // under the outgoing one, and a clear background would let both sets of
        // glyphs show through where they overlap.
        //
        // The paper is also drawn as a SwiftUI layer behind the canvas rather
        // than left to `PageDrawView.backgroundColor`: a `UIViewRepresentable`
        // reconfigures its view slightly after SwiftUI has already placed it,
        // and during a drag that delay shows as a blank or transparent strip
        // where the page should be.
        ZStack {
            paper
            PageImage(attributed: text, paper: nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// The page indicator lives in the reader header, not here. `nil` when the
    /// chapter has not been paginated yet, so the header shows only the title
    /// rather than a misleading `0/0`.
    private var pageIndicatorText: String? {
        guard !pages.isEmpty else { return nil }
        return "\(min(pageIndex + 1, pages.count))/\(pages.count)"
    }

    private func syncPageIndicator() {
        let text = pageIndicatorText ?? ""
        if pageIndicator != text { pageIndicator = text }
        // The bottom bar's progress bar is the chapter's, so it needs the page
        // count; it has no other way to learn how long this chapter is.
        let progress = pages.isEmpty
            ? 0
            : Double(min(pageIndex + 1, pages.count)) / Double(pages.count)
        if abs(model.chapterProgress - progress) > 0.0001 {
            model.chapterProgress = progress
        }
    }

    private func chapterHint(forward: Bool, box: CGSize) -> some View {
        VStack(spacing: 10) {
            Image(systemName: forward ? "chevron.right.2" : "chevron.left.2")
                .font(.title3)
            Text(forward ? "下一章" : "上一章")
                .font(.footnote.weight(.medium))
            if let title = adjacentChapterTitle(forward: forward) {
                Text(title)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .foregroundStyle(theme.secondaryText)
        .frame(width: box.width, height: box.height)
        .background(theme.secondaryBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func adjacentChapterTitle(forward: Bool) -> String? {
        let index = forward ? model.currentIndex + 1 : model.currentIndex - 1
        guard model.chapters.indices.contains(index) else { return nil }
        return model.chapters[index].title
    }

    // MARK: - Gesture

    /// True when a drag starting at `x` is the reader's back gesture rather than
    /// a page turn, so page turning keeps its hands off it.
    ///
    /// Only while the bars are visible: in full-screen reading an edge drag is
    /// just a page turn, and stealing it would make the first page of every
    /// chapter impossible to swipe away from.
    private func isBackSwipeOrigin(_ x: CGFloat) -> Bool {
        ReaderSwipe.claimsEdge(startX: x, barsVisible: model.showBars)
    }

    private func turnGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isAnimating, !isLayingOut, !model.isLoading, !pages.isEmpty,
                      document?.chapterURL == model.currentChapter?.url, box.width > 20 else { return }
                // An edge drag while the bars are up is leaving the book; turning
                // a page underneath it would move the reader before it vanished.
                guard !isBackSwipeOrigin(value.startLocation.x) else { return }
                pagesWidth = box.width
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                // The page that will be revealed is styled here, once, on the
                // first frame that moves: a CoreText pass at that moment is
                // affordable, one on every frame is not.
                if abs(drag) < 0.5 {
                    prepareNeighbor(forward: dx < 0)
                }
                if abs(drag) < 0.5 || (drag < 0) != (dx < 0) {
                    boundaryPreview = neighbor(forward: dx < 0) == nil
                        ? preparedBoundary(forward: dx < 0, box: box) : nil
                }
                let edge = neighbor(forward: dx < 0) == nil && boundaryPreview == nil
                // Following the finger, never animating: the finger is the
                // animator here, and an implicit animation on top of it makes
                // the page lag behind and then stall for the spring's tail.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    drag = edge ? rubberBand(dx) : dx
                }
            }
            .onEnded { value in
                guard !isAnimating, !isLayingOut, !model.isLoading,
                      document?.chapterURL == model.currentChapter?.url, box.width > 20 else { return }
                guard !isBackSwipeOrigin(value.startLocation.x) else { return }
                let width = box.width
                let dx = value.translation.width
                let progress = abs(drag) / width
                let fling = abs(value.predictedEndTranslation.width) > width * 0.7
                let shouldTurn = !pages.isEmpty && (progress > 0.2 || fling) && abs(dx) > abs(value.translation.height)
                if shouldTurn {
                    commitTurn(forward: dx < 0, box: box)
                } else if drag != 0 {
                    // A cancelled turn hands the page back to the spring: the
                    // finger's offset is released at once and only the return
                    // trip is animated, so the page does not jump backwards.
                    snapBack()
                    withAnimation(.easeOut(duration: 0.2)) { turn = 0 }
                }
            }
    }

    private func rubberBand(_ dx: CGFloat) -> CGFloat {
        let limit: CGFloat = 70
        return max(-limit, min(limit, dx * 0.3))
    }

    /// Moves the finger's offset into the animated one without a visual jump.
    private func snapBack() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            turn = drag
            drag = 0
        }
    }

    private func commitTurn(forward: Bool, box: CGSize) {
        if let target = neighbor(forward: forward) {
            // The page that will slide off is the cached page at the current
            // index, and the page it is settling onto is pinned here: `drag` is
            // about to be zeroed, so nothing downstream can work out the
            // direction or the destination from it any more.
            turnForward = forward
            turnTarget = target
            isAnimating = true
            // Underneath: the destination, which must be in hand before the
            // animation starts so the commit frame only moves an index.
            prepareNeighbor(forward: forward)
            // The animated offset starts where the finger left the page, so the
            // last stretch to the margin is one continuous movement instead of
            // the finger's position snapping to the start of the animation.
            snapBack()
            withAnimation(.easeOut(duration: 0.22)) {
                turn = forward ? -box.width : box.width
            }
            let chapterURL = document?.chapterURL
            let layoutID = layoutRequestID
            Task { @MainActor in
                // Fixed duration rather than waiting on the animation to report
                // back: a dropped frame must not leave the reader frozen.
                try? await Task.sleep(nanoseconds: 235_000_000)
                guard isVisible, document?.chapterURL == chapterURL,
                      layoutRequestID == layoutID else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    // One update: the index lands on the page that is already
                    // underneath and the offset drops to zero. Nothing here
                    // re-styles or re-renders.
                    pageIndex = target
                    turn = 0
                    turnTarget = nil
                    turnForward = nil
                    isAnimating = false
                }
            }
        } else {
            let target = model.currentIndex + (forward ? 1 : -1)
            guard model.chapters.indices.contains(target) else {
                snapBack()
                withAnimation(.easeOut(duration: 0.2)) { turn = 0 }
                return
            }
            isAnimating = true
            turnForward = forward
            boundaryTargetURL = model.chapters[target].url
            leaving = currentText
            boundaryPreview = preparedBoundary(forward: forward, box: box)
            snapBack()

            // When the next sheet is ready, finish the same gesture onto it.
            // Commit the chapter only after the animation completes so changing
            // the model cannot replace the outgoing text halfway through a fold.
            if boundaryPreview != nil {
                withAnimation(.easeOut(duration: 0.22), completionCriteria: .removed) {
                    turn = forward ? -box.width : box.width
                } completion: {
                    Task { @MainActor in await enterAdjacentChapter(forward: forward) }
                }
            } else {
                // A cold network request keeps the current sheet visible.
                withAnimation(.easeOut(duration: 0.18)) { turn = 0 }
                Task { @MainActor in await enterAdjacentChapter(forward: forward) }
            }
        }
    }

    private func enterAdjacentChapter(forward: Bool) async {
        guard isVisible, let expectedURL = boundaryTargetURL else { return }
        let target = model.currentIndex + (forward ? 1 : -1)
        guard model.chapters.indices.contains(target),
              model.chapters[target].url == expectedURL else { return }
        if forward {
            await model.goNextChapter()
        } else {
            await model.goPreviousChapterBackwards()
        }
        // Successful loads are installed by paginate, which also releases the
        // animation lock. Failure must release it here so retry remains usable.
        if model.content?.chapterURL != expectedURL {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                leaving = nil
                boundaryPreview = nil
                boundaryTargetURL = nil
                turnForward = nil
                drag = 0
                turn = 0
                isAnimating = false
            }
        }
    }

    private func preparedBoundary(forward: Bool, box: CGSize) -> NSAttributedString? {
        let index = model.currentIndex + (forward ? 1 : -1)
        guard model.chapters.indices.contains(index),
              let prepared = preparedChapters[model.chapters[index].url],
              let page = forward ? prepared.pages.first : prepared.pages.last else { return nil }
        // Settings or size may have changed while the background job ran.
        var expected = layoutKey(box)
        expected.url = prepared.key.url
        expected.contentHash = prepared.key.contentHash
        guard expected == prepared.key else { return nil }
        return page.drawable(from: prepared.document.attributed)
    }

    private func prepareAdjacentChapters(box: CGSize) async {
        guard box.width > 40, box.height > 60, !model.isLoading else { return }
        let origin = model.currentIndex
        let targets = [origin + 1, origin - 1].filter { model.chapters.indices.contains($0) }
        let keep = Set(targets.map { model.chapters[$0].url } + [model.content?.chapterURL ?? ""])
        preparedChapters = preparedChapters.filter { keep.contains($0.key) }
        for index in targets {
            guard !Task.isCancelled, model.currentIndex == origin else { return }
            guard let content = try? await model.contentForPagination(at: index) else { continue }
            guard !Task.isCancelled, model.currentIndex == origin else { return }
            let key = layoutKey(box, content: content)
            if preparedChapters[content.chapterURL]?.key == key { continue }
            let doc = PagedDocument.make(content: content, reading: reading, theme: theme)
            let ranges = await PageLayout.prepare(document: doc, in: box)
            guard !Task.isCancelled, model.currentIndex == origin,
                  layoutKey(box, content: content) == key else { return }
            preparedChapters[content.chapterURL] = PreparedChapter(key: key, document: doc, pages: ranges)
        }
    }

    // MARK: - Pagination

    private func paginate(box: CGSize) async {
        guard !model.isLoading else { return }
        guard let content = model.content,
              box.width > 40, box.height > 60 else {
            document = nil
            pages = []
            return
        }

        // While a chapter switch is in flight `currentIndex` has already moved on
        // but `content` still holds the previous chapter. Laying that text out
        // under the new chapter's URL would repaginate the old chapter and show
        // it for one frame; keep the page that is on screen instead and wait for
        // the matching content.
        if model.isLoading, let current = document, current.chapterURL != content.chapterURL {
            return
        }

        // The page on screen in raw-chapter coordinates, captured before the
        // new layout replaces it. Both branches below need it: reading aloud
        // stays on the page being spoken, and idle repagination reopens where
        // the old page started.
        let previousPageOffset: Int? = currentPage.map { old in
            document?.characterOffset(atAttributed: old.range.location) ?? 0
        }

        let requestID = UUID()
        layoutRequestID = requestID
        isLayingOut = true
        defer {
            if layoutRequestID == requestID { isLayingOut = false }
        }
        let key = layoutKey(box, content: content)
        let cached = preparedChapters[content.chapterURL]
        let doc: PagedDocument
        let layout: [ReaderPage]
        if let cached, cached.key == key {
            doc = cached.document
            layout = cached.pages
        } else {
            doc = PagedDocument.make(content: content, reading: reading, theme: theme)
            layout = await PageLayout.prepare(document: doc, in: box)
        }
        guard !Task.isCancelled, isVisible, layoutRequestID == requestID,
              model.content == content, layoutKey(box) == key else { return }
        // A different chapter starts at its own beginning; showing the old
        // chapter's position for a frame is worse than showing nothing.
        let isNewChapter = document?.chapterURL != content.chapterURL
        preparedChapters[content.chapterURL] = PreparedChapter(key: key, document: doc, pages: layout)
        document = doc
        pageText = [:]
        pages = layout
        pagesWidth = box.width
        if isNewChapter {
            model.chapterProgress = 0
        }

        // While reading, the page on screen is already the one being spoken —
        // `followSpeech` keeps it there — so repagination (a font change, say)
        // should keep it rather than hunt for the sentence's first character,
        // which for a long sentence sits on the page before.
        //
        // Idle repagination uses `pendingOffset`, which is kept on the visible
        // page. `hasContent` would not do: `stop()` keeps the sentence list, so
        // it stays true forever and every repagination snapped back to wherever
        // the last reading stopped, overriding the page the user had turned to.
        //
        // A chapter opened from its end ignores both: the swipe out of the
        // previous chapter showed the last page moving in, so that is where the
        // reader has to land.
        let opensAtEnd = isNewChapter && model.pendingEndOfChapter
        model.pendingEndOfChapter = false
        let explicitPosition = laidOutPositionRevision != model.positionRevision
        laidOutPositionRevision = model.positionRevision
        let resumeOffset = model.speech.isActive && !isNewChapter && !explicitPosition
            ? (previousPageOffset ?? model.pendingOffset)
            : model.pendingOffset
        if opensAtEnd, !layout.isEmpty {
            pageIndex = layout.count - 1
            // Fills the visible page and its neighbours before the frame that
            // turns the chapter switch off, so the page is already drawn when
            // the old one is released.
            preparePages(around: pageIndex)
            // The landing page has to be what the next session opens on, the
            // same way `saveProgress` keeps idle repagination honest.
            model.pendingOffset = offset(of: pageIndex, document: doc)
        } else {
            pageIndex = layout.isEmpty ? 0 : pageIndex(forOriginalOffset: resumeOffset, document: doc)
        }
        // Restyle with the finished layout, in the same pass that installs it,
        // so the next frame has the text ready and the turn never waits on a
        // CoreText pass at the moment the page should already be gone.
        leaving = nil
        boundaryPreview = nil
        boundaryTargetURL = nil
        turnForward = nil
        isAnimating = false
        if !opensAtEnd || layout.isEmpty {
            refreshStaging()
        }
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            drag = 0
            turn = 0
        }
        // A new chapter's offsets are relative to its own text, so a value left
        // over from the previous one would suppress the first save here.
        lastSavedOffset = nil
        syncPageIndicator()

        // Remember where the visible page starts so changing font size / line
        // spacing reopens on the same passage instead of the cached old offset.
        if let range = currentPage?.range, !opensAtEnd {
            model.pendingOffset = doc.characterOffset(atAttributed: range.location)
        }
        saveProgress()
    }

    /// Character offset of the page's first character, in raw-chapter terms.
    private func offset(of index: Int, document: PagedDocument) -> Int {
        guard pages.indices.contains(index) else { return 0 }
        return document.characterOffset(atAttributed: pages[index].range.location)
    }

    private func pageIndex(forOriginalOffset offset: Int, document: PagedDocument) -> Int {
        guard !pages.isEmpty else { return 0 }
        let location = document.attributedLocation(forOriginal: offset)
        var result = 0
        for (index, page) in pages.enumerated() {
            if page.range.location <= location { result = index } else { break }
        }
        return result
    }

    private func saveProgress() {
        guard !model.isLoading, let document,
              document.chapterURL == model.currentChapter?.url,
              let range = currentPage?.range else { return }
        let offset = document.characterOffset(atAttributed: range.location)
        model.pendingOffset = offset
        // `pageIndex` changes for reasons other than turning a page — the
        // speech follow-along and repagination both move it — and every write
        // here rewrites the whole library to disk. Skip when the page still
        // starts where it did.
        guard offset != lastSavedOffset else { return }
        lastSavedOffset = offset
        model.saveProgress(characterOffset: offset)
    }

    private func followSpeech(box: CGSize) {
        guard !isAnimating, !isLayingOut, !model.isLoading,
              let document, document.chapterURL == model.currentChapter?.url,
              !pages.isEmpty, model.speech.isActive else { return }
        let text = model.content?.text ?? ""
        let start = model.speech.characterOffset(ofSentence: model.currentSentenceIndex, in: text)
        let target = pageIndex(forOriginalOffset: start, document: document)
        let sentenceEnd = sentenceEndOffset(at: model.currentSentenceIndex, in: text) ?? start
        let visible = pageContains(originalRange: start..<sentenceEnd, pageIndex: pageIndex, document: document)
        guard target != pageIndex else { return }
        guard !visible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { pageIndex = target }
    }

    /// Where the sentence being read ends, in raw-chapter coordinates.
    private func sentenceEndOffset(at index: Int, in text: String) -> Int? {
        guard model.speech.sentences.indices.contains(index) else { return nil }
        let next = index + 1
        if model.speech.sentences.indices.contains(next) {
            return model.speech.characterOffset(ofSentence: next, in: text)
        }
        return model.speech.characterOffset(ofSentence: index, in: text)
            + model.speech.sentences[index].count
    }

    /// Whether any of `range` (raw-chapter offsets) is laid out on `pageIndex`.
    private func pageContains(
        originalRange range: Range<Int>,
        pageIndex: Int,
        document: PagedDocument
    ) -> Bool {
        guard pages.indices.contains(pageIndex) else { return false }
        let page = pages[pageIndex]
        let pageStart = document.characterOffset(atAttributed: page.range.location)
        // The end is exclusive in character terms but the page may stop short
        // of it; walking the last character is enough to know whether the
        // range reaches into this page.
        let pageEnd = pageStart + page.range.length
        return range.lowerBound < pageEnd && range.upperBound > pageStart
    }

    // MARK: - Styling

    /// Applies the TTS highlight to one page slice. Background colour does not
    /// affect layout, so pages never need to be re-measured for it.
    private func styledPage(document: PagedDocument, page: ReaderPage) -> NSAttributedString {
        let slice = page.drawable(from: document.attributed)
        let range = page.range
        guard let highlight = highlightRange(in: document) else { return slice }
        let overlap = NSIntersectionRange(range, highlight)
        guard overlap.length > 0 else { return slice }
        let local = NSRange(location: overlap.location - range.location, length: overlap.length)
        guard local.location >= 0, local.location + local.length <= slice.length else { return slice }
        let result = NSMutableAttributedString(attributedString: slice)
        result.addAttribute(
            .backgroundColor,
            value: UIColor(theme.accent).withAlphaComponent(0.24),
            range: local
        )
        return result
    }

    /// Range of the sentence being spoken, in `document.attributed`'s
    /// coordinates.
    ///
    /// Taken from the controller's own position table rather than searched for
    /// in the text. Searching for the sentence's opening characters matched the
    /// *first* occurrence in the chapter every time, so a line the author
    /// repeated ("他说。", "她笑了笑。") highlighted somewhere above the passage
    /// actually being read.
    private func highlightRange(in document: PagedDocument) -> NSRange? {
        guard model.speech.showsHighlight,
              model.speech.sentences.indices.contains(model.currentSentenceIndex) else { return nil }
        let text = model.content?.text ?? ""
        guard !text.isEmpty else { return nil }

        let start = model.speech.characterOffset(ofSentence: model.currentSentenceIndex, in: text)
        // The next sentence's start bounds this one exactly, whatever the
        // whitespace differences between the normalized and raw text.
        let next = model.currentSentenceIndex + 1
        let sentenceEnd: Int
        if model.speech.sentences.indices.contains(next) {
            sentenceEnd = model.speech.characterOffset(ofSentence: next, in: text)
        } else {
            sentenceEnd = start + model.speech.sentences[model.currentSentenceIndex].count
        }

        let location = document.attributedLocation(forOriginal: start)
        let endLocation = document.attributedLocation(forOriginal: sentenceEnd)
        let full = document.attributed.string as NSString
        guard full.length > 0 else { return nil }

        // `attributed` carries a leading body prefix and may add paragraph
        // breaks, so clamp rather than trust the arithmetic to stay in range.
        let location0 = min(max(location, 0), full.length)
        let length = max(min(endLocation, full.length) - location0, 0)
        guard length > 0 else { return nil }
        return NSRange(location: location0, length: length)
    }
}
#endif
