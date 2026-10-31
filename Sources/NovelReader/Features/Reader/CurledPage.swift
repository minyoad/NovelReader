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
/// Describing it as "fold a sheet over a page" instead of two separate
/// animations is what keeps the two directions feeling identical — the earlier
/// version drew the backward turn as a flat wipe plus a white wash, which is why
/// it looked weak and washed-out.
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

            // Forward: the crease walks right → left as the sheet is peeled.
            // Backward: it walks left → right as the sheet is laid back down,
            // so the sheet's leading edge tracks the finger from the far side.
            let crease = forward ? width * (1 - t) : width * t

            // Which page is the paper being bent, and which is underneath.
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
                    forward: forward
                )
            }
            .frame(width: width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    // MARK: - The folded sheet

    /// One sheet, hinged at the crease.
    ///
    /// Left of the crease the paper is still flat against the book. Right of it
    /// the paper has been turned over, so the visible surface there is the back
    /// of the same page: mirrored print, dimmed, with the crease catching light
    /// and the free edge shading off.
    @ViewBuilder
    private func foldedSheet(
        size: CGSize,
        width: CGFloat,
        crease: CGFloat,
        text: NSAttributedString,
        forward: Bool
    ) -> some View {
        let c = min(max(crease, 0), width)
        let stripWidth = width - c

        ZStack(alignment: .topLeading) {
            // Flat part: the paper still lying on the book.
            PageImage(attributed: text)
                .frame(width: width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: c)
                }

            // Turned-over part, mirrored about the crease.
            if c > 0.5 && stripWidth > 0.5 {
                turnedOverStrip(
                    size: size,
                    width: width,
                    stripWidth: stripWidth,
                    text: text
                )
                // Mirrored about the crease: the sheet occupies
                // [2c - W, c] on screen.
                .offset(x: 2 * c - width)
            }

            // Shadow the lifted sheet throws onto the page underneath, on the
            // side the paper has already left.
            if c > 0 {
                LinearGradient(
                    colors: [.black.opacity(0.22), .black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(width * 0.22, 44), height: size.height)
                .offset(x: max(c - min(width * 0.22, 44), 0))
                .opacity(forward ? 1 : 0.85)
            }

            // Shadow under the turned-over strip itself, cast down onto the
            // flat part just left of the crease.
            if c > 4 && stripWidth > 4 {
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.18)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(stripWidth, 30), height: size.height)
                .offset(x: max(c - min(stripWidth, 30), 0))
            }
        }
    }

    @ViewBuilder
    private func turnedOverStrip(
        size: CGSize,
        width: CGFloat,
        stripWidth: CGFloat,
        text: NSAttributedString
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Paper body of the underside.
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))

            // Back of the print. Kept fairly strong so the strip reads as paper
            // rather than a glass panel — the previous version was far too
            // transparent here.
            PageImage(attributed: text, mirror: true)
                .frame(width: width, height: size.height)
                .frame(width: stripWidth, height: size.height, alignment: .leading)
                .clipped()
                .opacity(0.62)

            // Curl shading: deepest at the crease, lifting toward the free edge.
            LinearGradient(
                colors: [.black.opacity(0.26), .black.opacity(0.02)],
                startPoint: .trailing,
                endPoint: .leading
            )
            .blendMode(.multiply)

            // A softer sheen where the paper bends away from the light.
            LinearGradient(
                colors: [.white.opacity(0.14), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: .infinity)
            .blendMode(.softLight)

            // The crease itself.
            Rectangle()
                .fill(Color.white.opacity(0.42))
                .frame(width: 1.2)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: stripWidth, height: size.height)
        .clipped()
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
