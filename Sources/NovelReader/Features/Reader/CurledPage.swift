#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Geometry for one corner-lift page turn, in 2D.
///
/// A sheet of paper grabbed at one corner creases along a *diagonal* line, and
/// only a band next to that crease is actually turned over — beyond the band you
/// see the page underneath. A fold about a vertical line can at best approximate
/// that, which is why an earlier version read as a grey strip sliding sideways
/// rather than paper bending.
///
/// The corner that lifts is a **top** one — top-right when turning forward,
/// top-left when turning back — because that is where a thumb actually grabs a
/// page. The fold then sweeps downward across the sheet.
///
/// Everything is expressed as a signed distance `d` from the crease line, with
/// positive on the side that has been lifted off the book:
///
///     d <= 0        front of the current page, still flat
///     0 < d < band  the curl: back of the sheet
///     d >= band     the page underneath, now uncovered
///
/// The crease is parameterised *directly* by the turn progress. Solving it from
/// a touch point instead (crease = perpendicular bisector of corner and touch)
/// degenerates whenever the touch point shares a scanline with the corner: the
/// midpoint lands on that line, the divisor in the control point goes to zero,
/// and half the flap silently flies off-screen. That is the failure mode behind
/// the missing lower half of earlier attempts.
///
/// UIKit and CoreGraphics both start with y pointing down, so no flip is needed
/// except inside CoreText itself.
struct CurlGeometry {
    let size: CGSize
    /// 0 = flat, 1 = fully turned.
    let progress: CGFloat
    /// True when peeling toward the next page.
    let forward: Bool

    init(size: CGSize, progress: CGFloat, forward: Bool) {
        self.size = size
        self.progress = max(min(progress, 1), 0)
        self.forward = forward
    }

    private var w: CGFloat { max(size.width, 1) }
    private var h: CGFloat { max(size.height, 1) }

    // MARK: Crease

    /// A point the crease passes through.
    ///
    /// The sheet is lifted at a **top** corner (top-right when turning forward,
    /// top-left when turning back) and the fold sweeps down toward the opposite
    /// corner. Peeling from the top is how a thumb actually lifts a page; a fold
    /// that starts at the bottom edge reads as the sheet hinging on its base
    /// instead of being picked up.
    ///
    /// Mirrored horizontally for a backward turn so the two directions stay exact
    /// reflections of each other.
    var creasePoint: CGPoint {
        let t = progress
        let x = w * (1 - 0.92 * t)
        // Starts at the top edge and travels down; y grows with progress.
        let y = h * 0.94 * t
        return forward ? CGPoint(x: x, y: y) : CGPoint(x: w - x, y: y)
    }

    /// Unit tangent along the crease.
    var tangent: CGPoint {
        // Expressed as the tilt *away from vertical*, which is what the eye
        // reads: 5° next to the lifted top corner, opening to 36° as the fold
        // sweeps down. It used to open to 72°, which made the crease look like a
        // diagonal slash across the page instead of a fold; the sweep is now
        // half of that.
        let tilt = 5 + 31 * progress
        let radians = (90 - tilt) * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)
        return forward ? CGPoint(x: dx, y: dy) : CGPoint(x: -dx, y: dy)
    }

    /// Unit normal pointing toward the lifted side.
    var normal: CGPoint {
        let t = tangent
        var n = CGPoint(x: -t.y, y: t.x)
        // Keep it pointing up and inwards, so the lifted region is the one that
        // grows down from the top corner, in both directions.
        let reference = forward ? CGPoint(x: 1, y: -0.35) : CGPoint(x: -1, y: -0.35)
        if n.x * reference.x + n.y * reference.y < 0 {
            n = CGPoint(x: -n.x, y: -n.y)
        }
        return n
    }

    /// Width of the curl band, in points.
    ///
    /// Opens as the corner lifts and closes again as the sheet lands flat, so
    /// the last frame is a clean page with no residual curl.
    var band: CGFloat {
        let grow = 0.18 + 0.82 * min(progress / 0.62, 1)
        let shrink = 1 - Self.smoothstep(0.78, 1.0, progress)
        return w * 0.42 * grow * shrink
    }

    // MARK: Regions

    /// Signed distance from the crease.
    func distance(_ point: CGPoint) -> CGFloat {
        let n = normal
        let p = creasePoint
        return (point.x - p.x) * n.x + (point.y - p.y) * n.y
    }

    /// Builds the polygon for a half-plane or a slab by clipping the page.
    ///
    /// Sutherland-Hodgman: clip the page rectangle against each boundary in
    /// turn. The earlier version collected edge intersections and filtered them
    /// with the same predicate used for the corners, which silently discarded
    /// every boundary point of the band — the slab has no corner inside it in
    /// the common case, so the band polygon came back empty and the curl was
    /// never drawn at all.
    ///
    /// Computed exactly rather than via a mask bitmap, which also avoids the
    /// jagged edge that a mask left along the crease.
    private func regionPath(_ halfPlanes: [(CGPoint) -> CGFloat]) -> CGPath {
        var poly: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: w, y: 0),
            CGPoint(x: w, y: h),
            CGPoint(x: 0, y: h),
        ]

        for signedIn in halfPlanes {
            var output: [CGPoint] = []
            let count = poly.count
            var index = 0
            while index < count {
                let a = poly[index]
                let b = poly[(index + 1) % count]
                let sa = signedIn(a)
                let sb = signedIn(b)
                if sa >= 0 { output.append(a) }
                if (sa >= 0) != (sb >= 0) {
                    let denominator = sa - sb
                    if abs(denominator) > 1e-9 {
                        let k = sa / denominator
                        output.append(
                            CGPoint(x: a.x + (b.x - a.x) * k,
                                    y: a.y + (b.y - a.y) * k)
                        )
                    }
                }
                index += 1
            }
            poly = output
            if poly.isEmpty { return CGMutablePath() }
        }

        guard poly.count >= 3 else { return CGMutablePath() }
        let path = CGMutablePath()
        path.addLines(between: poly)
        path.closeSubpath()
        return path
    }

    /// Signed value of the crease distance, relative to an offset.
    private func signed(_ point: CGPoint, offset: CGFloat) -> CGFloat {
        distance(point) - offset
    }

    /// The sheet still lying flat: `d <= 0`.
    func flatRegionPath() -> CGPath {
        regionPath([{ -signed($0, offset: 0) }])
    }

    /// The page underneath: `d >= band`.
    func revealedRegionPath() -> CGPath {
        let band = self.band
        return regionPath([{ signed($0, offset: band) }])
    }

    /// The curl itself: `0 < d < band`.
    func bandRegionPath() -> CGPath {
        let band = self.band
        return regionPath([
            { signed($0, offset: 0) },
            { -signed($0, offset: band) },
        ])
    }

    /// A point `offset` points from the crease along the normal.
    func pointOnNormal(_ offset: CGFloat) -> CGPoint {
        let n = normal
        let p = creasePoint
        return CGPoint(x: p.x + n.x * offset, y: p.y + n.y * offset)
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A page turning with a paper curl.
///
/// One CoreGraphics pass draws all three regions. The curl band is produced by
/// reflecting the front page about the crease and sampling it, so the back
/// carries real mirrored print; composing masked SwiftUI images instead only
/// ever produced a stretched, streaky band and cost a CoreText re-layout per
/// layer per frame.
struct CurledPage: View {
    let settledText: NSAttributedString
    let neighborText: NSAttributedString?
    let progress: CGFloat
    let forward: Bool
    let paper: Color

    var body: some View {
        CurlView(
            settled: settledText,
            neighbor: neighborText,
            progress: progress,
            forward: forward,
            paper: UIColor(paper)
        )
        .allowsHitTesting(false)
    }
}

private struct CurlView: UIViewRepresentable {
    let settled: NSAttributedString
    let neighbor: NSAttributedString?
    let progress: CGFloat
    let forward: Bool
    let paper: UIColor

    func makeUIView(context: Context) -> CurlDrawView {
        let view = CurlDrawView()
        view.backgroundColor = paper
        view.isOpaque = true
        view.contentMode = .redraw
        view.settled = settled
        view.neighbor = neighbor
        view.progress = progress
        view.forward = forward
        view.paper = paper
        return view
    }

    func updateUIView(_ view: CurlDrawView, context: Context) {
        view.paper = paper
        view.forward = forward
        view.progress = progress
        view.neighbor = neighbor
        view.settled = settled
    }
}

final class CurlDrawView: UIView {
    var settled: NSAttributedString? {
        didSet {
            guard !Self.sameText(settled, oldValue) else { return }
            frontImage = nil
            setNeedsDisplay()
        }
    }
    var neighbor: NSAttributedString? {
        didSet {
            guard !Self.sameText(neighbor, oldValue) else { return }
            underImage = nil
            setNeedsDisplay()
        }
    }
    var progress: CGFloat = 0 {
        didSet {
            guard progress != oldValue else { return }
            setNeedsDisplay()
        }
    }
    var forward = true {
        didSet {
            guard forward != oldValue else { return }
            setNeedsDisplay()
        }
    }
    var paper: UIColor = .white {
        didSet {
            backgroundColor = paper
            frontImage = nil
            underImage = nil
            setNeedsDisplay()
        }
    }

    /// Bitmaps of the two pages, rebuilt only when their text or size changes.
    /// Drawing text with CoreText on every frame of a drag was the main source of
    /// stutter on long chapters.
    private var frontImage: UIImage?
    private var underImage: UIImage?
    private var imageSize: CGSize = .zero

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              bounds.width > 1, bounds.height > 1 else { return }

        let t = min(max(progress, 0), 1)

        // At rest and at the end, draw one plain page: no curl, no shadow, and
        // nothing that could leave a residual band on an untouched page.
        if t <= 0.001 {
            pageImage(settled, cache: &frontImage).draw(in: bounds)
            return
        }
        if t >= 0.999 {
            pageImage(neighbor ?? settled, cache: &underImage).draw(in: bounds)
            return
        }

        let geometry = CurlGeometry(size: bounds.size, progress: t, forward: forward)

        // 1. Current page, on the side that has not lifted.
        context.saveGState()
        context.addPath(geometry.flatRegionPath())
        context.clip()
        pageImage(settled, cache: &frontImage).draw(in: bounds)
        context.restoreGState()

        // 2. Page underneath, beyond the curl band.
        context.saveGState()
        context.addPath(geometry.revealedRegionPath())
        context.clip()
        pageImage(neighbor ?? settled, cache: &underImage).draw(in: bounds)
        context.restoreGState()

        // 3. The curl band.
        drawBand(in: context, geometry: geometry)

        // 4. Shadow and fold line.
        drawCrease(in: context, geometry: geometry)
    }

    private func drawBand(in context: CGContext, geometry: CurlGeometry) {
        let band = geometry.band
        guard band > 0.5 else { return }

        context.saveGState()
        context.addPath(geometry.bandRegionPath())
        context.clip()

        // Reflect about the crease, then draw the front page through that
        // transform. The result is the back of the sheet with real print.
        let n = geometry.normal
        let o = geometry.creasePoint
        let a = 1 - 2 * n.x * n.x
        let b = -2 * n.x * n.y
        let d = 1 - 2 * n.y * n.y
        let tx = o.x - (a * o.x + b * o.y)
        let ty = o.y - (b * o.x + d * o.y)
        context.concatenate(CGAffineTransform(a: a, b: b, c: b, d: d, tx: tx, ty: ty))

        // Backs read a little dimmer than fronts.
        context.setAlpha(0.9)
        pageImage(settled, cache: &frontImage).draw(in: bounds)
        context.setAlpha(1)
        context.restoreGState()

        // Cylindrical ramp across the band: lit just off the crease, shadowed at
        // the free edge. This is what makes it read as paper rolled over an edge
        // rather than a strip pasted on top.
        context.saveGState()
        context.addPath(geometry.bandRegionPath())
        context.clip()
        let colors = [
            UIColor.white.withAlphaComponent(0.18).cgColor,
            UIColor.black.withAlphaComponent(0.03).cgColor,
            UIColor.black.withAlphaComponent(0.32).cgColor,
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 0.4, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: geometry.pointOnNormal(0),
                end: geometry.pointOnNormal(band),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    private func drawCrease(in context: CGContext, geometry: CurlGeometry) {
        let p = geometry.creasePoint
        let reach = max(bounds.width, bounds.height) * 2

        // Contact shadow on the freshly uncovered page.
        context.saveGState()
        context.addPath(geometry.revealedRegionPath())
        context.clip()
        let colors = [
            UIColor.black.withAlphaComponent(0.24).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: geometry.pointOnNormal(geometry.band),
                end: geometry.pointOnNormal(geometry.band + 28),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()

        // The fold itself.
        let tangent = geometry.tangent
        context.saveGState()
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: p.x - tangent.x * reach, y: p.y - tangent.y * reach))
        context.addLine(to: CGPoint(x: p.x + tangent.x * reach, y: p.y + tangent.y * reach))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Bitmaps

    private func pageImage(_ text: NSAttributedString?, cache: inout UIImage?) -> UIImage {
        guard bounds.width > 1, bounds.height > 1 else { return UIImage() }
        if let cache, imageSize == bounds.size { return cache }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let image = renderer.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(paper.cgColor)
            c.fill(CGRect(origin: .zero, size: bounds.size))
            guard let text, text.length > 0 else { return }
            c.saveGState()
            c.textMatrix = .identity
            c.translateBy(x: 0, y: bounds.height)
            c.scaleBy(x: 1, y: -1)
            let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, c)
            c.restoreGState()
        }
        cache = image
        imageSize = bounds.size
        return image
    }

    private static func sameText(_ a: NSAttributedString?, _ b: NSAttributedString?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a === b || a.isEqual(to: b)
    }
}
#endif
