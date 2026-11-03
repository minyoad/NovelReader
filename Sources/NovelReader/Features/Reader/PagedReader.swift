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

                if model.isLoading && model.content != nil {
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
            .task(id: layoutKey(box)) {
                paginate(box: box)
            }
            .onChange(of: pageIndex) { _, _ in
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

    private func layoutKey(_ box: CGSize) -> LayoutKey {
        LayoutKey(
            url: model.content?.chapterURL ?? "",
            contentHash: model.content?.text.hashValue ?? 0,
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

    private var isForward: Bool { drag < 0 }

    private var dragProgress: CGFloat {
        min(abs(drag) / max(pagesWidth, 1), 1)
    }

    @ViewBuilder
    private func pageLayers(box: CGSize) -> some View {
        if reading.pageTurnEffect == .curl {
            curlLayers(box: box)
        } else {
            ZStack {
                // Revealed page (or chapter hint) behind the page being dragged.
                if abs(drag) > 0.5, let document {
                    let forward = isForward
                    if let index = neighbor(forward: forward) {
                        pageImage(document: document, page: pages[index])
                    } else {
                        chapterHint(forward: forward, box: box)
                            .offset(x: forward ? box.width : -box.width)
                            .offset(x: drag)
                    }
                }

                // Page under the finger (or the settled page when no drag).
                if let document, let currentPage {
                    pageImage(document: document, page: currentPage)
                        .offset(x: reading.pageTurnEffect == .slide ? drag : 0)
                        .opacity(reading.pageTurnEffect == .fade ? Double(1 - dragProgress) : 1)
                }
            }
            .frame(width: box.width, height: box.height)
        }
    }

    /// Paper-curl mode. The sheet and the page it reveals are drawn by
    /// `CurledPage` from the same page images, so the fold never disagrees with
    /// the finger and the print stays aligned with the paginator's slices.
    ///
    /// At a chapter boundary there is no neighbouring page to reveal, so the
    /// hint card takes over and the current page just slides with the finger —
    /// curling would have nothing to fold onto.
    @ViewBuilder
    private func curlLayers(box: CGSize) -> some View {
        let forward = isForward
        let hasNeighbor = neighbor(forward: forward) != nil

        ZStack {
            if hasNeighbor {
                if let document, let currentPage {
                    CurledPage(
                        settledText: styledPage(document: document, page: currentPage),
                        neighborText: neighborPageText(document: document, forward: forward),
                        progress: dragProgress,
                        forward: forward,
                        paper: theme.background
                    )
                    .frame(width: box.width, height: box.height)
                }
            } else {
                if abs(drag) > 0.5 {
                    chapterHint(forward: forward, box: box)
                        .offset(x: forward ? box.width : -box.width)
                        .offset(x: drag)
                }
                if let document, let currentPage {
                    pageImage(document: document, page: currentPage)
                        .offset(x: drag)
                }
            }
        }
        .frame(width: box.width, height: box.height)
    }

    private func neighborPageText(document: PagedDocument, forward: Bool) -> NSAttributedString? {
        guard let index = neighbor(forward: forward) else { return nil }
        return styledPage(document: document, page: pages[index])
    }

    private func pageImage(document: PagedDocument, page: ReaderPage) -> some View {
        // `paper` matters beyond the curl: in slide mode the incoming page sits
        // under the outgoing one, and a clear background would let both sets of
        // glyphs show through where they overlap.
        PageImage(attributed: styledPage(document: document, page: page), paper: theme.background)
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
                guard !isAnimating, !pages.isEmpty, box.width > 20 else { return }
                // An edge drag while the bars are up is leaving the book; turning
                // a page underneath it would move the reader before it vanished.
                guard !isBackSwipeOrigin(value.startLocation.x) else { return }
                pagesWidth = box.width
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                let edge = neighbor(forward: dx < 0) == nil
                drag = edge ? rubberBand(dx) : dx
            }
            .onEnded { value in
                guard !isAnimating, box.width > 20 else { return }
                guard !isBackSwipeOrigin(value.startLocation.x) else { return }
                let width = box.width
                let dx = value.translation.width
                let progress = abs(drag) / width
                let fling = abs(value.predictedEndTranslation.width) > width * 0.7
                let shouldTurn = !pages.isEmpty && (progress > 0.2 || fling) && abs(dx) > abs(value.translation.height)
                if shouldTurn {
                    commitTurn(forward: dx < 0, box: box)
                } else if drag != 0 {
                    withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                }
            }
    }

    private func rubberBand(_ dx: CGFloat) -> CGFloat {
        let limit: CGFloat = 70
        return max(-limit, min(limit, dx * 0.3))
    }

    private func commitTurn(forward: Bool, box: CGSize) {
        if let target = neighbor(forward: forward) {
            isAnimating = true
            withAnimation(.easeOut(duration: 0.22)) {
                drag = forward ? -box.width : box.width
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 230_000_000)
                pageIndex = target
                drag = 0
                isAnimating = false
            }
        } else {
            // End of chapter: no page to turn to, so hand the swipe straight to
            // the chapter switch. The page never springs back on its own — the
            // new chapter's content replaces this one and pagination resets
            // `drag`, which reads as the page sliding away rather than bouncing.
            guard !isAnimating else { return }
            isAnimating = true
            // Keep the rubber-band offset as the leaving edge, then fade the
            // current page out while the next chapter loads.
            withAnimation(.easeOut(duration: 0.12)) {
                drag = forward ? -box.width * 0.12 : box.width * 0.12
            }
            Task { @MainActor in
                if forward {
                    await model.goNextChapter()
                } else {
                    await model.goPreviousChapter()
                }
                drag = 0
                isAnimating = false
            }
        }
    }

    // MARK: - Pagination

    private func paginate(box: CGSize) {
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

        let doc = PagedDocument.make(content: content, reading: reading, theme: theme)
        let layout = PageLayout.ranges(of: doc.attributed, text: doc.text, in: box)
        document = doc
        pages = layout
        pagesWidth = box.width

        // While reading, the page on screen is already the one being spoken —
        // `followSpeech` keeps it there — so repagination (a font change, say)
        // should keep it rather than hunt for the sentence's first character,
        // which for a long sentence sits on the page before.
        //
        // Idle repagination uses `pendingOffset`, which is kept on the visible
        // page. `hasContent` would not do: `stop()` keeps the sentence list, so
        // it stays true forever and every repagination snapped back to wherever
        // the last reading stopped, overriding the page the user had turned to.
        let offset = model.speech.isActive
            ? (previousPageOffset ?? model.pendingOffset)
            : model.pendingOffset
        pageIndex = layout.isEmpty ? 0 : pageIndex(forOriginalOffset: offset, document: doc)
        drag = 0
        // A new chapter's offsets are relative to its own text, so a value left
        // over from the previous one would suppress the first save here.
        lastSavedOffset = nil
        syncPageIndicator()

        // Remember where the visible page starts so changing font size / line
        // spacing reopens on the same passage instead of the cached old offset.
        if let range = currentPage?.range {
            model.pendingOffset = doc.characterOffset(atAttributed: range.location)
        }
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
        guard let document, let range = currentPage?.range else { return }
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
        guard let document, !pages.isEmpty, model.speech.isActive else { return }
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
