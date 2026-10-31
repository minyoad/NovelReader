#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// A page turning with a paper curl, drawn in 2D.
///
/// Direction comes only from the gesture: `progress` is `abs(drag) / width` and
/// `forward` is the sign of the drag. A leftward swipe peels the current sheet
/// leftward; a rightward swipe lays the previous sheet back down.
///
/// **Both directions use one renderer.** A backward turn is the forward turn
/// mirrored horizontally about the page centre, with the two page roles set so
/// the content still makes sense: the settled page is always the sheet being
/// folded, and the neighbour is always the page uncovered underneath
/// (next page when swiping left, previous page when swiping right).
///
/// The scene flip mirrors every glyph, so each page image carries the *opposite*
/// mirror state to cancel it and land upright; the turned-over strip is the one
/// exception, since it shows the reverse of the sheet and really is printed
/// mirror-image. Omitting the per-image cancellation is what turned the page
/// underneath backwards on a rightward swipe.
///
/// The underside of the sheet is real paper: opaque body, print at reduced but
/// readable strength, a cylindrical light ramp across the curl, a bowed free
/// edge, and a dark hairline for thickness.
struct CurledPage: View {
    /// The page the reader is on when the gesture starts.
    let settledText: NSAttributedString
    /// The page being turned to, when there is one.
    let neighborText: NSAttributedString?
    /// 0 = untouched, 1 = fully turned.
    let progress: CGFloat
    let forward: Bool
    /// Paper colour of the current reading theme, so the underside matches the
    /// page rather than the system chrome.
    let paper: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = max(size.width, 1)
            let t = min(max(progress, 0), 1)

            // The sheet being turned is always the page the reader is on; only
            // the page *underneath* differs by direction. A forward swipe
            // reveals the next page from the right, a backward swipe reveals the
            // previous page from the left.
            //
            // Backward is the forward picture mirrored, which keeps the two
            // directions identical in weight, shade and arc. The scene flip also
            // mirrors every glyph, so each page image asks for the *opposite*
            // mirror state to cancel it out — that detail is what keeps type
            // upright, and leaving it out is what turned the underlying page
            // backwards on a rightward swipe.
            peelScene(
                size: size,
                width: width,
                t: t,
                text: settledText,
                under: neighborText,
                mirrored: !forward
            )
            // Flip the whole scene about its centre — which is also the centre
            // of every full-width page image, so the per-image counter-flip
            // inside is an exact identity and the type lands upright.
            .scaleEffect(x: forward ? 1 : -1, y: 1, anchor: .center)
            .frame(width: width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    // MARK: - One turn, peeling toward the left (or its mirror)

    /// The canonical leftward peel. `t` runs 0 → 1 as the sheet is lifted off.
    ///
    /// Drawn at every value of `t`, including 0 and 1: `t == 0` is a sheet lying
    /// flat and `t == 1` is the page underneath filling the screen. Gating this
    /// on `t > 0` left the reader blank the moment a turn finished and the drag
    /// reset to zero.
    @ViewBuilder
    private func peelScene(
        size: CGSize,
        width: CGFloat,
        t: CGFloat,
        text sheetText: NSAttributedString?,
        under underText: NSAttributedString?,
        mirrored: Bool
    ) -> some View {
        // The crease starts at the right edge and walks left.
        let c = width * (1 - t)
        let stripWidth = width - c
        // Screen span of the turned-over strip: [2c - W, c].
        let stripLeft = 2 * c - width
        // The flat sheet stops where the turned-over strip begins, so the two
        // never overlap and no glyph is drawn twice.
        let flatWidth = max(min(c, stripWidth > 0.5 ? stripLeft : c), 0)

        // Inside the flipped scene the pages must be flipped back so they read
        // normally; the strip is the exception — it shows the back of the sheet,
        // which really is printed mirror-image.
        let pageMirror = mirrored
        let stripMirror = !mirrored

        ZStack(alignment: .topLeading) {
            // Page underneath, revealed as the sheet lifts. Skipped while the
            // sheet still covers it completely — at rest the sheet is opaque and
            // full width, so drawing the page beneath would be a second CoreText
            // layout per frame for nothing.
            if let underText, stripWidth > 0.5 {
                PageImage(attributed: underText, mirror: pageMirror, paper: paper)
                    .frame(width: width, height: size.height)
            }

            // Still-glued part of the sheet, flat on the book.
            if let sheetText {
                PageImage(attributed: sheetText, mirror: pageMirror, paper: paper)
                    .frame(width: width, height: size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: flatWidth)
                    }
            }

            // The turned-over part, mirrored about the crease.
            if let sheetText, c > 0.5, stripWidth > 0.5 {
                turnedOverStrip(
                    size: size,
                    width: width,
                    stripWidth: stripWidth,
                    text: sheetText,
                    t: t,
                    mirrorText: stripMirror
                )
                .offset(x: stripLeft)
            }

            // The lift throws a shadow on the page it has uncovered.
            if c > 0 && c < width - 1 {
                LinearGradient(
                    colors: [.black.opacity(0.28), .black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(width * 0.20, 44), height: size.height)
                .offset(x: c)
                .allowsHitTesting(false)
            }

            // The curled strip shades the flat part it rests on. Gated on the
            // strip actually existing: at rest `stripLeft` is still non-zero even
            // though the strip has no width, which used to leave a dark band down
            // the right edge of an untouched page.
            if stripWidth > 2 && stripLeft > 2 {
                LinearGradient(
                    colors: [.black.opacity(0.28), .black.opacity(0)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: min(stripLeft, 32), height: size.height)
                .offset(x: max(stripLeft - min(stripLeft, 32), 0))
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Underside of the turning sheet

    @ViewBuilder
    private func turnedOverStrip(
        size: CGSize,
        width: CGFloat,
        stripWidth: CGFloat,
        text: NSAttributedString,
        t: CGFloat,
        mirrorText: Bool
    ) -> some View {
        // The free edge bows in as the sheet lifts. Grows with the turn.
        let bulge = min(stripWidth * 0.10, 16) * (0.35 + 0.65 * t)

        ZStack(alignment: .topLeading) {
            // Opaque paper body: the page below must never show through.
            paper

            // Back of the print. Sustained at full opacity and dimmed by the
            // veil below, rather than made translucent — a translucent back let
            // the flat page's own text bleed through as a second layer.
            PageImage(attributed: text, mirror: mirrorText, paper: paper)
                .frame(width: width, height: size.height)
                .frame(width: stripWidth, height: size.height, alignment: .leading)
                .clipped()

            // Backs carry the print dimmer than fronts.
            Color.black.opacity(0.18)

            // Cylindrical ramp: brightest just off the crease, falling into
            // shadow at the fold.
            LinearGradient(
                colors: [
                    .white.opacity(0.18),
                    .black.opacity(0.06),
                    .black.opacity(0.32),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .blendMode(.multiply)

            // Specular crown of the curl.
            LinearGradient(
                colors: [.clear, .white.opacity(0.28), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(stripWidth * 0.55, 1))
            .blendMode(.screen)

            // Paper has thickness: a dark inner edge with a lit lip outside it.
            Rectangle()
                .fill(Color.black.opacity(0.30))
                .frame(width: 2)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Rectangle()
                .fill(Color.white.opacity(0.50))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: -2)

            // Free edge, turning away from the reader.
            Rectangle()
                .fill(Color.black.opacity(0.16))
                .frame(width: 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: stripWidth, height: size.height)
        .clipShape(CurlEdge(bulge: bulge))
    }
}

/// Silhouette of the turned-over strip: the free (left) edge bows inward, as a
/// lifted sheet of paper does, while the crease stays dead straight.
private struct CurlEdge: Shape {
    /// Horizontal bow of the free edge, in points.
    var bulge: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + bulge
        let right = rect.maxX

        path.move(to: CGPoint(x: left, y: rect.minY))
        // Free edge bows toward the crease in the middle.
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.maxY),
            control: CGPoint(x: left + bulge, y: rect.midY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Draws one attributed page with CoreText, optionally horizontally mirrored so
/// it reads as the back of the same sheet.
///
/// When `paper` is given the view paints an opaque sheet background first. That
/// matters for the curl, where two pages are stacked: with a clear background
/// both sets of glyphs would show through each other, which looks like the same
/// text printed twice.
struct PageImage: UIViewRepresentable {
    let attributed: NSAttributedString
    var mirror: Bool = false
    var paper: Color?

    func makeUIView(context: Context) -> PageDrawView {
        let view = PageDrawView()
        view.isOpaque = paper != nil
        view.contentMode = .redraw
        view.mirror = mirror
        view.paper = paper
        view.text = attributed
        return view
    }

    func updateUIView(_ view: PageDrawView, context: Context) {
        view.mirror = mirror
        view.paper = paper
        view.text = attributed
    }

    final class PageDrawView: UIView {
        var text: NSAttributedString? {
            didSet {
                // `updateUIView` runs on every frame of a drag, but the page
                // content does not change then — only the fold does. Re-assigning
                // the same string kept queuing a full CoreText re-layout per
                // frame, which made the curl stutter on long chapters.
                guard !PageDrawView.sameText(text, oldValue) else { return }
                setNeedsDisplay()
            }
        }
        var mirror = false {
            didSet {
                guard mirror != oldValue else { return }
                setNeedsDisplay()
            }
        }
        var paper: Color? {
            didSet {
                backgroundColor = paper.map { UIColor($0) } ?? .clear
                isOpaque = paper != nil
                setNeedsDisplay()
            }
        }

        /// Cheap identity check: the paginator hands the same attributed string
        /// back on every frame until the page itself changes.
        private static func sameText(_ a: NSAttributedString?, _ b: NSAttributedString?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return a === b || a.isEqual(to: b)
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(),
                  let text,
                  text.length > 0,
                  bounds.width > 0,
                  bounds.height > 0 else { return }

            if mirror {
                context.translateBy(x: bounds.width, y: 0)
                context.scaleBy(x: -1, y: 1)
            }

            context.textMatrix = .identity
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)

            let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
        }
    }
}
#endif
