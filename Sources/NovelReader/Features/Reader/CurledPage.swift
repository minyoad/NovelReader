#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// A page turning with a paper curl, drawn in 2D.
///
/// Direction comes only from the gesture: `progress` is `abs(drag) / width`,
/// `forward` is the sign of the drag, and the crease is a plain linear function
/// of both. A leftward swipe always peels the current sheet leftward; a
/// rightward swipe always pulls the previous sheet back in from the left.
///
/// Both directions share one renderer. The only difference is which page is the
/// *sheet* being folded and which is the *page underneath*:
///
/// - forward: fold the current page, reveal the next one
/// - backward: fold the previous page, reveal the current one
///
/// The underside is drawn as real paper: an opaque body, print at reduced but
/// still readable strength, a cylindrical light ramp across the curl, a bowed
/// free edge and a dark inner edge for thickness. An earlier version let the
/// page below show through the strip, which read as a glass panel rather than a
/// sheet of paper.
struct CurledPage: View {
    /// The page the reader is on when the gesture starts.
    let settledText: NSAttributedString
    /// The page being turned to, when there is one.
    let neighborText: NSAttributedString?
    /// 0 = untouched, 1 = fully turned. Never negative, never above 1.
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

            // Forward: the crease walks right → left as the sheet is peeled.
            // Backward: it walks left → right as the sheet is laid back down.
            let crease = forward ? width * (1 - t) : width * t

            let sheetText = forward ? settledText : (neighborText ?? settledText)
            let underText = forward ? neighborText : settledText

            ZStack(alignment: .topLeading) {
                // Page underneath: visible wherever the sheet has moved away.
                if let underText {
                    PageImage(attributed: underText)
                        .frame(width: width, height: size.height)
                }

                foldedSheet(
                    size: size,
                    width: width,
                    crease: crease,
                    text: sheetText,
                    forward: forward,
                    t: t
                )
            }
            .frame(width: width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    // MARK: - The folded sheet

    @ViewBuilder
    private func foldedSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString,
        forward: Bool,
        t: CGFloat
    ) -> some View {
        let c = min(max(crease, 0), width)
        let stripWidth = width - c
        // Screen span of the turned-over strip: [2c - W, c].
        let stripLeft = 2 * c - width
        // The flat sheet only draws up to where the folded strip begins, so the
        // two never overlap. Previously both covered [stripLeft, c], and any
        // translucency in the strip let the flat page's text show through as a
        // second layer of glyphs.
        let flatWidth = max(min(c, stripWidth > 0.5 ? stripLeft : c), 0)

        ZStack(alignment: .topLeading) {
            // Flat part: the paper still lying on the book.
            PageImage(attributed: text)
                .frame(width: width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: flatWidth)
                }

            // Turned-over part, mirrored about the crease. Mirrored about the
            // crease it occupies [2c - W, c] on screen.
            if c > 0.5 && stripWidth > 0.5 {
                turnedOverStrip(
                    size: size,
                    width: width,
                    stripWidth: stripWidth,
                    text: text,
                    progress: t
                )
                .offset(x: stripLeft)
            }

            // The fold lifts the paper off the page, so the page below darkens
            // right where the sheet has just left.
            if c > 0 {
                LinearGradient(
                    colors: [.black.opacity(0.30), .black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(width * 0.26, 52), height: size.height)
                .offset(x: c)
                .allowsHitTesting(false)
            }

            // Shadow the turned-over strip casts back onto the flat part.
            if c > 4 && stripWidth > 4 && stripLeft > 2 {
                LinearGradient(
                    colors: [.black.opacity(0.30), .black.opacity(0)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: min(stripLeft, 34), height: size.height)
                .offset(x: max(stripLeft - min(stripLeft, 34), 0))
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func turnedOverStrip(
        size: CGSize,
        width: CGFloat,
        stripWidth: CGFloat,
        text: NSAttributedString,
        progress t: CGFloat
    ) -> some View {
        // How much the free edge bows inward. Grows with the turn so a slightly
        // peeled corner already looks curved, and relaxes as the sheet lies flat
        // again at the end of the animation.
        let bulge = min(stripWidth * 0.10, 16) * (0.35 + 0.65 * t)

        ZStack(alignment: .topLeading) {
            // Opaque paper body: nothing from the page below may show through.
            paper

            // Back of the print. Drawn fully opaque onto the paper body — the
            // dimming comes from the veil below, not from letting the page
            // underneath bleed through.
            PageImage(attributed: text, mirror: true)
                .frame(width: width, height: size.height)
                .frame(width: stripWidth, height: size.height, alignment: .leading)
                .clipped()

            // Uniform veil: the back of a sheet carries the print dimmer than
            // the front does, and never at full contrast.
            Color.black.opacity(0.18)

            // Cylindrical ramp: the strip curves away from the light, so it is
            // brightest just off the crease and falls into shadow at the fold.
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

            // Specular sheen on the crown of the curl.
            LinearGradient(
                colors: [.clear, .white.opacity(0.30), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(stripWidth * 0.55, 1))
            .blendMode(.screen)

            // Inner edge: the paper has thickness, so the fold itself reads as
            // a dark line with a lit lip on the far side.
            Rectangle()
                .fill(Color.black.opacity(0.30))
                .frame(width: 2)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: -2)

            // Free edge: a darker hairline where the sheet turns away.
            Rectangle()
                .fill(Color.black.opacity(0.18))
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
        let left = rect.minX
        let right = rect.maxX
        let midY = rect.midY

        path.move(to: CGPoint(x: left + bulge, y: rect.minY))
        // Free edge bows toward the crease in the middle.
        path.addQuadCurve(
            to: CGPoint(x: left + bulge, y: rect.maxY),
            control: CGPoint(x: left + bulge * 2, y: midY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Draws one attributed page with CoreText, optionally horizontally mirrored so
/// it reads as the back of the same sheet.
struct PageImage: UIViewRepresentable {
    let attributed: NSAttributedString
    var mirror: Bool = false

    func makeUIView(context: Context) -> PageDrawView {
        let view = PageDrawView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.contentMode = .redraw
        view.mirror = mirror
        view.text = attributed
        return view
    }

    func updateUIView(_ view: PageDrawView, context: Context) {
        view.mirror = mirror
        view.text = attributed
    }

    final class PageDrawView: UIView {
        var text: NSAttributedString? {
            didSet { setNeedsDisplay() }
        }
        var mirror = false {
            didSet { setNeedsDisplay() }
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
