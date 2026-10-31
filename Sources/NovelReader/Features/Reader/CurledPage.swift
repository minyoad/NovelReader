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
                    PageImage(attributed: underText, paper: paper)
                        .frame(width: width, height: size.height)
                }

                if forward {
                    foldedSheet(
                        size: size,
                        width: width,
                        crease: crease,
                        text: sheetText,
                        t: t
                    )
                } else {
                    incomingSheet(
                        size: size,
                        width: width,
                        crease: crease,
                        text: sheetText,
                        t: t
                    )
                }
            }
            .frame(width: width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Backward: lay the previous page back down

    /// The previous page arriving from the left, its trailing edge still lifted.
    ///
    /// Geometry, in order from the spine outward:
    ///
    /// - `[0, c)` is the sheet already lying on the book: plain front, no curl.
    /// - `[c, c + curlDepth)` is the part of the sheet still bent up off the
    ///   page. We are looking at its **underside**, so it holds no readable
    ///   print — just paper, a cylindrical ramp, and its bent silhouette.
    /// - beyond that, the current page, with the sheet's shadow on it.
    ///
    /// An earlier version placed the curl *inside* the landed area and filled it
    /// with mirrored text, which put backwards glyphs on the left of the screen
    /// and made the edge look like a smear rather than a lifted sheet.
    @ViewBuilder
    private func incomingSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString,
        t: CGFloat
    ) -> some View {
        let c = min(max(crease, 0), width)

        // Depth of the bend, in points. Grows with the drag; kept modest so the
        // edge reads as paper rather than a wide grey band.
        let curlDepth = min(width * 0.13, 26) * (0.30 + 0.70 * t)
        // The free edge bows back toward the land as it curls up.
        let bulge = min(curlDepth * 0.55, 14) * (0.35 + 0.65 * t)

        // Nothing has turned yet: draw nothing at all, so an untouched page has
        // no stray shadow down its left edge.
        let hasTurned = t > 0.001 && c > 0.5

        ZStack(alignment: .topLeading) {
            if hasTurned {
                // Landed part: front of the previous page, flat on the book.
                PageImage(attributed: text, paper: paper)
                    .frame(width: width, height: size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: c)
                    }

                // Lifted edge: the underside of the same sheet, blank.
                curledEdgeStrip(
                    size: size,
                    depth: curlDepth,
                    bulge: bulge,
                    progress: t
                )
                .offset(x: c)

                // Shadow the lifted edge throws onto the page it has uncovered.
                if c + curlDepth < width - 1 {
                    LinearGradient(
                        colors: [.black.opacity(0.30), .black.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: min(width * 0.10, 26), height: size.height)
                    .offset(x: c + curlDepth)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// The underside of a lifted sheet: blank paper, cylindrical shading, and a
    /// bent free edge. No print — we are looking at the back of the page.
    @ViewBuilder
    private func curledEdgeStrip(
        size: CGSize,
        depth: CGFloat,
        bulge: CGFloat,
        progress t: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            paper

            // Paper turned away from the light: brighter where it lifts off the
            // page (near the crease) and falling off toward the free edge.
            LinearGradient(
                colors: [
                    .white.opacity(0.10),
                    .black.opacity(0.10),
                    .black.opacity(0.34),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // Specular band along the crown of the bend.
            LinearGradient(
                colors: [.clear, .white.opacity(0.24), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(depth * 0.7, 1))
            .blendMode(.screen)

            // Trailing edge: a hairline that separates the sheet from the page
            // behind it, plus a sliver of thickness.
            Rectangle()
                .fill(Color.black.opacity(0.30))
                .frame(width: 1.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: max(depth, 1), height: size.height)
        .clipShape(CurlEdge(bulge: bulge, freeEdgeOnLeft: false))
    }

    // MARK: - Forward: peel the current sheet away

    @ViewBuilder
    private func foldedSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString,
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
        // At rest nothing is lifted, so no curl decoration should be drawn at
        // all — otherwise a shadow sliver lingers on an untouched page.
        let hasTurned = t > 0.001

        ZStack(alignment: .topLeading) {
            // Flat part: the paper still lying on the book.
            PageImage(attributed: text, paper: paper)
                .frame(width: width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: flatWidth)
                }

            if hasTurned {
                // Turned-over part, mirrored about the crease. Mirrored about
                // the crease it occupies [2c - W, c] on screen.
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

                // The fold lifts the paper off the page, so the page below
                // darkens right where the sheet has just left.
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
            PageImage(attributed: text, mirror: true, paper: paper)
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

/// Silhouette of a lifted strip of paper: the free edge bows in as a lifted
/// sheet does, while the crease stays dead straight.
private struct CurlEdge: Shape {
    /// Horizontal bow of the free edge, in points.
    var bulge: CGFloat
    /// Forward turns lift the right edge; backward turns lift the left one.
    var freeEdgeOnLeft: Bool = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + (freeEdgeOnLeft ? bulge : 0)
        let right = rect.maxX - (freeEdgeOnLeft ? 0 : bulge)
        let midY = rect.midY
        // The free edge bows toward the crease; the crease itself is straight.
        let controlX = freeEdgeOnLeft ? left + bulge : right - bulge

        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.maxY),
            control: CGPoint(x: controlX, y: midY)
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
