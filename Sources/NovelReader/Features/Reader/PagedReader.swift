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
    @EnvironmentObject private var app: AppModel

    @State private var document: PagedDocument?
    @State private var pages: [NSRange] = []
    @State private var pageIndex = 0
    @State private var drag: CGFloat = 0
    @State private var isAnimating = false
    /// Width of the page in points; captured from the gesture so the drag
    /// progress can be normalised without recomputing layout.
    @State private var pagesWidth: CGFloat = 1

    private var reading: ReadingSettings { app.settings.reading }

    /// Height reserved for the page footer (page number + chapter title).
    private let footerHeight: CGFloat = 30

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

                footer
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
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
            .onChange(of: model.currentSentenceIndex) { _, _ in
                followSpeech(box: box)
            }
        }
    }

    // MARK: - Layout inputs

    private func contentSize(in available: CGSize) -> CGSize {
        CGSize(
            width: max(available.width - reading.horizontalPadding * 2, 0),
            height: max(available.height - footerHeight, 0)
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
        var showChapterTitle: Bool
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
            alignment: reading.alignment.rawValue,
            showChapterTitle: reading.showChapterTitle
        )
    }

    // MARK: - Pages

    private var currentRange: NSRange? {
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
                        pageImage(document: document, range: pages[index])
                    } else {
                        chapterHint(forward: forward, box: box)
                            .offset(x: forward ? box.width : -box.width)
                            .offset(x: drag)
                    }
                }

                // Page under the finger (or the settled page when no drag).
                if let document, let currentRange {
                    pageImage(document: document, range: currentRange)
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
                if let document, let currentRange {
                    CurledPage(
                        settledText: styledPage(document: document, range: currentRange),
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
                if let document, let currentRange {
                    pageImage(document: document, range: currentRange)
                        .offset(x: drag)
                }
            }
        }
        .frame(width: box.width, height: box.height)
    }

    private func neighborPageText(document: PagedDocument, forward: Bool) -> NSAttributedString? {
        guard let index = neighbor(forward: forward) else { return nil }
        return styledPage(document: document, range: pages[index])
    }

    private func pageImage(document: PagedDocument, range: NSRange) -> some View {
        // `paper` matters beyond the curl: in slide mode the incoming page sits
        // under the outgoing one, and a clear background would let both sets of
        // glyphs show through where they overlap.
        PageImage(attributed: styledPage(document: document, range: range), paper: theme.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(min(pageIndex + 1, max(pages.count, 1))) / \(max(pages.count, 1))")
                .monospacedDigit()
            if let title = model.currentChapter?.title, !title.isEmpty {
                Text("·")
                Text(title).lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(theme.secondaryText.opacity(0.8))
        .padding(.horizontal, 20)
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

    private func turnGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isAnimating, !pages.isEmpty, box.width > 20 else { return }
                pagesWidth = box.width
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                let edge = neighbor(forward: dx < 0) == nil
                drag = edge ? rubberBand(dx) : dx
            }
            .onEnded { value in
                guard !isAnimating, box.width > 20 else { return }
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
                saveProgress()
            }
        } else {
            // End of chapter: spring back, then load the neighbouring chapter.
            isAnimating = true
            withAnimation(.easeOut(duration: 0.18)) { drag = 0 }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 190_000_000)
                isAnimating = false
                if forward {
                    await model.goNextChapter()
                } else {
                    await model.goPreviousChapter()
                }
            }
        }
    }

    // MARK: - Pagination

    private func paginate(box: CGSize) {
        guard let chapter = model.currentChapter,
              let content = model.content,
              box.width > 40, box.height > 60 else {
            document = nil
            pages = []
            return
        }

        let doc = PagedDocument.make(chapter: chapter, content: content, reading: reading, theme: theme)
        let ranges = PageLayout.ranges(of: doc.attributed, in: box)
        document = doc
        pages = ranges
        pagesWidth = box.width

        let offset = model.speech.hasContent
            ? model.speech.characterOffset(ofSentence: model.currentSentenceIndex, in: content.text)
            : model.pendingOffset
        pageIndex = ranges.isEmpty ? 0 : pageIndex(forOriginalOffset: offset, document: doc)
        drag = 0

        // Remember where the visible page starts so changing font size / line
        // spacing reopens on the same passage instead of the cached old offset.
        if let range = currentRange {
            model.pendingOffset = doc.characterOffset(atAttributed: range.location)
        }
    }

    private func pageIndex(forOriginalOffset offset: Int, document: PagedDocument) -> Int {
        guard !pages.isEmpty else { return 0 }
        let location = document.attributedLocation(forOriginal: offset)
        var result = 0
        for (index, range) in pages.enumerated() {
            if range.location <= location { result = index } else { break }
        }
        return result
    }

    private func saveProgress() {
        guard let document, let range = currentRange else { return }
        let offset = document.characterOffset(atAttributed: range.location)
        model.pendingOffset = offset
        model.saveProgress(characterOffset: offset)
    }

    private func followSpeech(box: CGSize) {
        guard let document, !pages.isEmpty, model.speech.hasContent else { return }
        let text = model.content?.text ?? ""
        let offset = model.speech.characterOffset(ofSentence: model.currentSentenceIndex, in: text)
        let target = pageIndex(forOriginalOffset: offset, document: document)
        guard target != pageIndex else { return }
        withAnimation(.easeInOut(duration: 0.2)) { pageIndex = target }
    }

    // MARK: - Styling

    /// Applies the TTS highlight to the current page slice. Background colour
    /// does not affect layout, so pages never need to be re-measured for it.
    private func styledPage(document: PagedDocument, range: NSRange) -> NSAttributedString {
        let slice = document.attributed.attributedSubstring(from: range)
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

    private func highlightRange(in document: PagedDocument) -> NSRange? {
        guard model.speech.hasContent,
              model.speech.sentences.indices.contains(model.currentSentenceIndex) else { return nil }
        let sentence = model.speech.sentences[model.currentSentenceIndex]
        let probe = String(sentence.prefix(14))
        guard !probe.isEmpty else { return nil }

        let text = document.attributed.string as NSString
        let bodyStart = min(document.bodyPrefix, text.length)
        let bodyRange = NSRange(location: bodyStart, length: max(text.length - bodyStart, 0))
        guard bodyRange.length > 0 else { return nil }

        let found = text.range(of: probe, options: [], range: bodyRange)
        guard found.location != NSNotFound else { return nil }
        let length = min(max(sentence.utf16.count, found.length), bodyRange.length - (found.location - bodyRange.location))
        guard length > 0 else { return nil }
        return NSRange(location: found.location, length: length)
    }
}
#endif
