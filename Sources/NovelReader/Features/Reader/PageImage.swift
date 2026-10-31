#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Draws one attributed page with CoreText on an opaque sheet.
///
/// Used by the rolling reader and by the slide/fade page effects. The paper
/// background is not cosmetic: in slide mode the incoming page sits under the
/// outgoing one, and a clear background lets both sets of glyphs show through
/// each other, which looks like the same text printed twice.
struct PageImage: UIViewRepresentable {
    let attributed: NSAttributedString
    var paper: Color?

    func makeUIView(context: Context) -> PageDrawView {
        let view = PageDrawView()
        view.paper = paper
        view.text = attributed
        return view
    }

    func updateUIView(_ view: PageDrawView, context: Context) {
        view.paper = paper
        view.text = attributed
    }

    final class PageDrawView: UIView {
        var text: NSAttributedString? {
            didSet {
                // `updateUIView` runs on every frame of a drag, but the page
                // content does not change then. Re-assigning the same string
                // queued a full CoreText re-layout per frame, which made long
                // chapters stutter.
                guard !PageDrawView.sameText(text, oldValue) else { return }
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

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentMode = .redraw
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            contentMode = .redraw
        }

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
