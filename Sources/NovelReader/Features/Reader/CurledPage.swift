#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// A page turning with a paper curl, drawn in 2D.
///
/// Direction comes only from the gesture: `progress` is `abs(drag) / width` and
/// `forward` is the sign of the drag. A leftward swipe peels the current sheet
/// leftward; a rightward swipe lays the previous sheet back down.
///
/// **Both directions use one renderer.** A backward turn is literally the
/// forward turn mirrored horizontally: the whole scene is flipped, and each page
/// image is flipped a second time so its type still reads normally. That is what
/// guarantees the two directions look alike — earlier versions hand-rolled a
/// separate animation for the backward turn and it never matched, ending up with
/// a wide grey band, backwards glyphs, or a curl attached to the wrong edge.
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

            // Nothing has turned: draw nothing at all, so an untouched page has
            // no stray shadow along either edge.
            if t > 0.001 {
                // The forward turn is the canonical one. Backward is the same
                // picture mirrored, with the two pages swapped.
                let sheet = forward ? settledText : (neighborText ?? settledText)
                let under = forward ? neighborText : settledText

                peelScene(
                    size: size,
                    width: width,
                    t: t,
                    sheet: sheet,
                    under: under
                )
                // Mirror for the backward turn. Each image is un-mirrored again
                // inside, so text stays readable.
                .scaleEffect(x: forward ? 1 : -1, y: 1, anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - One turn, always peeling toward the left

    /// The canonical leftward peel. `t` runs 0 → 1 as the sheet is lifted off.
    @ViewBuilder
    private func peelScene(
        size: CGSize,
        width: CGFloat,
        t: CGFloat,
        sheet sheetText: NSAttributedString?,
        under underText: NSAttributedString?
    ) -> some View {
        // The crease starts at the right edge and walks left.
        let c = width * (1 - t)
        let stripWidth = width - c
        // Screen span of the turned-over strip: [2c - W, c].
        let stripLeft = 2 * c - width
        // The flat sheet stops where the turned-over strip begins, so the two
        // never overlap and no glyph is drawn twice.
        let flatWidth = max(min(c, stripWidth > 0.5 ? stripLeft : c), 0)

        ZStack(alignment: .topLeading) {
            // Page underneath, revealed as the sheet lifts.
            if let underText {
                PageImage(attributed: underText, paper: paper)
                    .frame(width: width, height: size.height)
            }

            // Still-glued part of the sheet, flat on the book.
            if let sheetText {
                PageImage(attributed: sheetText, paper: paper)
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
                    t: t
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

            // The curled strip shades the flat part it rests on.
            if c > 4 && stripLeft > 2 {
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
        t: CGFloat
    ) -> some View {
        // The free edge bows in as the sheet lifts. Grows with the turn.
        let bulge = min(stripWidth * 0.10, 16) * (0.35 + 0.65 * t)

        ZStack(alignment: .topLeading) {
            // Opaque paper body: the page below must never show through.
            paper

            // Back of the print, mirrored. Sustained at full opacity and dimmed
            // by the veil below, rather than made translucent — a translucent
            // back let the flat page's own text bleed through as a second layer.
            PageImage(attributed: text, mirror: true, paper: paper)
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
            didSet { setNeedsDisplay() }
        }
        var mirror = false {
            didSet { setNeedsDisplay() }
        }
        var paper: Color? {
            didSet {
                backgroundColor = paper.map { UIColor($0) } ?? .clear
                isOpaque = paper != nil
                setNeedsDisplay()
            }
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
