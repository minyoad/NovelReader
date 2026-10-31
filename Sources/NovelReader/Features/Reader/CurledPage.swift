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

    /// The previous page arriving from the left, with its trailing edge curled.
    ///
    /// It lands **face up**, so the front is what covers the page — but the last
    /// few dozen points of the sheet are still bent up off the book, so that
    /// strip shows the back of the paper, not the front. Drawing front-only made
    /// the edge read as a hard wipe with a fixed 14pt smear; the curl now grows
    /// with the drag and travels with the crease.
    @ViewBuilder
    private func incomingSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString,
        t: CGFloat
    ) -> some View {
        let c = min(max(crease, 0), width)

        // Depth of the bend. Grows with the turn and is capped relative to the
        // page, so a small drag already shows a sliver of underside and a long
        // drag shows a proper curl instead of a hairline.
        let curlDepth = min(width * 0.30, 54) * (0.45 + 0.55 * t)
        // How much the free edge bows back toward the crease.
        let bulge = min(curlDepth * 0.35, 18) * (0.4 + 0.6 * t)

        // Front of the sheet, stopping where the bend begins.
        let frontWidth = max(c - curlDepth, 0)
        // Where the curled strip sits on screen.
        let curlLeft = frontWidth

        ZStack(alignment: .topLeading) {
            // Solid front of the previous page.
            PageImage(attributed: text, paper: paper)
                .frame(width: width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: frontWidth)
                }

            // The bent strip: back of the same sheet, mirrored, with a cylindrical
            // ramp and a curved free edge so it reads as paper lifting off.
            if frontWidth > 0.5 && curlDepth > 0.5 {
                curledEdgeStrip(
                    size: size,
                    width: width,
                    depth: curlDepth,
                    bulge: bulge,
                    text: text,
                    progress: t
                )
                .offset(x: curlLeft)
            }

            // Contact shadow where the lifted edge leaves the page.
            if frontWidth > 1 {
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.22)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(frontWidth, 26), height: size.height)
                .offset(x: max(frontWidth - min(frontWidth, 26), 0))
                .allowsHitTesting(false)
            }

            // Shadow the curled strip throws onto the page still uncovered.
            if frontWidth + curlDepth < width - 1 {
                LinearGradient(
                    colors: [.black.opacity(0.28), .black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(width * 0.14, 34), height: size.height)
                .offset(x: frontWidth + curlDepth)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func curledEdgeStrip(
        size: CGSize,
        width: CGFloat,
        depth: CGFloat,
        bulge: CGFloat,
        text: NSAttributedString,
        progress t: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            paper

            // Back of the print. Only the part of the page under the strip is
            // needed, and it is mirrored because we are looking at the reverse.
            PageImage(attributed: text, mirror: true, paper: paper)
                .frame(width: width, height: size.height)
                .frame(width: depth, height: size.height, alignment: .leading)
                .clipped()

            Color.black.opacity(0.16)

            // Cylindrical ramp: bright where the sheet turns up, dark into the
            // crease against the flat part.
            LinearGradient(
                colors: [
                    .white.opacity(0.22),
                    .black.opacity(0.08),
                    .black.opacity(0.30),
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
            .frame(width: max(depth * 0.6, 1))
            .blendMode(.screen)

            // Paper thickness at the free edge.
            Rectangle()
                .fill(Color.black.opacity(0.26))
                .frame(width: 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: depth, height: size.height)
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

        ZStack(alignment: .topLeading) {
            // Flat part: the paper still lying on the book.
            PageImage(attributed: text, paper: paper)
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
