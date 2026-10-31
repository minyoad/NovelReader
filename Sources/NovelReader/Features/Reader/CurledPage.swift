#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// A page turning with a paper curl, drawn in 2D.
///
/// The previous implementation used `rotation3DEffect`, which gave the turn its
/// direction from an `anchor` + sign pair that was easy to get backwards and
/// impossible to verify without a device. Here nothing is inferred: `progress`
/// is `abs(drag) / width` and `forward` is the sign of the drag, and the crease
/// position is a plain linear function of both. A leftward swipe always peels
/// the sheet leftward; a rightward swipe always lays the previous page down
/// from the left.
///
/// Forward — the settled page is attached at the left spine and its free edge
/// is pulled left. The sheet folds back on itself, so the part still touching
/// the page stays flat and the turned-over part shows the *back* of the paper
/// (mirrored, dimmed print) lying on top of the fold.
///
/// Backward — the previous sheet comes back in from the left and is laid down
/// over the current page, so only its leading edge and the shadow it casts need
/// to be drawn.
struct CurledPage: View {
    /// The page the reader is on when the gesture starts.
    let settledText: NSAttributedString
    /// The page being turned to, when there is one.
    let neighborText: NSAttributedString?
    /// 0 = untouched, 1 = fully turned. Never negative, never above 1.
    let progress: CGFloat
    let forward: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = max(size.width, 1)
            let t = min(max(progress, 0), 1)
            // Forward the crease walks right → left as the sheet is peeled;
            // backward it walks left → right as the sheet is laid down.
            let crease = forward ? width * (1 - t) : width * t

            ZStack(alignment: .topLeading) {
                if forward {
                    // Next page shows through wherever the sheet has left.
                    if let neighborText {
                        PageImage(attributed: neighborText)
                            .frame(width: width, height: size.height)
                    }
                    peeledSheet(size: size, width: width, crease: crease, text: settledText)
                } else {
                    PageImage(attributed: settledText)
                        .frame(width: width, height: size.height)
                    incomingSheet(
                        size: size,
                        width: width,
                        crease: crease,
                        text: neighborText ?? settledText
                    )
                }
            }
            .frame(width: width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Forward: peel the current sheet away

    @ViewBuilder
    private func peeledSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString
    ) -> some View {
        let c = min(max(crease, 0), width)

        // Still glued to the spine: everything left of the crease.
        PageImage(attributed: text)
            .frame(width: width, height: size.height)
            .mask(alignment: .leading) {
                Rectangle().frame(width: c)
            }

        // Turned-over part. Mirroring the sheet about the crease means the
        // folded strip is the whole page flipped horizontally, cropped at the
        // crease and parked at the crease itself.
        if c > 0.5 && width - c > 0.5 {
            foldedStrip(size: size, width: width, crease: c, text: text)
        }

        // Shadow the lifted sheet throws onto the page underneath.
        if c > 0 {
            LinearGradient(
                colors: [.black.opacity(0.20), .black.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: min(width * 0.22, 40), height: size.height)
            .offset(x: c)
        }
    }

    @ViewBuilder
    private func foldedStrip(
        size: CGSize,
        width: CGFloat,
        crease c: CGFloat,
        text: NSAttributedString
    ) -> some View {
        let stripWidth = width - c

        ZStack(alignment: .topLeading) {
            // Paper body, slightly paler than the printed side.
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))

            // Back of the print showing through, then dimmed.
            PageImage(attributed: text, mirror: true)
                .frame(width: width, height: size.height)
                .frame(width: stripWidth, height: size.height, alignment: .leading)
                .clipped()
                .opacity(0.38)

            // Curl shading: darkest at the crease, fading to the free edge.
            LinearGradient(
                colors: [.black.opacity(0.28), .white.opacity(0.06)],
                startPoint: .trailing,
                endPoint: .leading
            )

            // The crease itself catches the light.
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 1.2)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: stripWidth, height: size.height)
        .clipped()
        .offset(x: 2 * c - width)
    }

    // MARK: - Backward: lay the previous sheet down

    @ViewBuilder
    private func incomingSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString
    ) -> some View {
        let c = min(max(crease, 0), width)

        // The part that has already come to rest on the book.
        PageImage(attributed: text)
            .frame(width: width, height: size.height)
            .mask(alignment: .leading) {
                Rectangle().frame(width: c)
            }

        // Shadow this sheet casts on the page still visible to its right.
        LinearGradient(
            colors: [.black.opacity(0.22), .black.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 26, height: size.height)
        .offset(x: c)
        .opacity(c > 0.5 ? 1 : 0)

        // Leading edge: still bent upward, so it catches light and shades off.
        if c > 0.5 {
            LinearGradient(
                colors: [.white.opacity(0.30), .clear],
                startPoint: .trailing,
                endPoint: .leading
            )
            .frame(width: min(c, 18), height: size.height)
            .offset(x: max(c - 18, 0))

            Rectangle()
                .fill(Color.white.opacity(0.45))
                .frame(width: 1.2, height: size.height)
                .offset(x: max(c - 1.2, 0))
        }
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
