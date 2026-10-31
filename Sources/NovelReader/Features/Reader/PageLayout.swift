#if canImport(SwiftUI) && canImport(UIKit)
import CoreText
import Foundation
import SwiftUI
import UIKit
import NovelKit

/// A chapter prepared for paginated layout, plus the offset mapping needed to
/// turn CoreText UTF-16 positions back into chapter character offsets.
///
/// The chapter title is deliberately not part of this: it is drawn in the
/// reader's header slot, so the page holds body text only and offsets map
/// one-to-one to the chapter text.
struct PagedDocument {
    let attributed: NSAttributedString
    let text: PaginatedText
    let chapterURL: String

    /// UTF-16 offset inside `attributed` for a character offset in the raw
    /// chapter text.
    func attributedLocation(forOriginal offset: Int) -> Int {
        text.bodyUTF16Offset(forOriginal: offset)
    }

    /// Raw chapter character offset for a UTF-16 location in `attributed`.
    func characterOffset(atAttributed location: Int) -> Int {
        text.originalOffset(forBodyUTF16: max(location, 0))
    }

    static func make(
        content: ChapterContent,
        reading: ReadingSettings,
        theme: Theme
    ) -> PagedDocument {
        let textColor = UIColor(theme.text)
        let paginated = PaginatedText(rawText: content.text)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = reading.lineSpacing
        bodyStyle.paragraphSpacing = reading.paragraphSpacing
        bodyStyle.lineBreakMode = .byWordWrapping
        bodyStyle.alignment = reading.alignment == .justify ? .justified : .left
        if reading.firstLineIndent {
            // Indent without touching the string: inserting full-width spaces
            // would shift every character offset and corrupt saved progress.
            let indent = bodyFont(size: reading.fontSize, family: reading.fontFamily).pointSize * 2
            bodyStyle.firstLineHeadIndent = indent
            bodyStyle.headIndent = 0
        }
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont(size: reading.fontSize, family: reading.fontFamily),
            .paragraphStyle: bodyStyle,
            .foregroundColor: textColor,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor.cgColor,
        ]

        // No chapter title inside the page: the reader shows it in a fixed
        // header slot, so repeating it here would print the same line twice at
        // the top of a chapter's first page.
        let result = NSMutableAttributedString(
            string: paginated.body,
            attributes: bodyAttributes
        )

        return PagedDocument(
            attributed: result,
            text: paginated,
            chapterURL: content.chapterURL
        )
    }

    /// Body font for the reader.
    ///
    /// `family` carries a PostScript name from the settings sheet. The special
    /// value `-apple-system` means "system sans" and anything unknown falls back
    /// to the system serif, which keeps CJK glyph coverage complete.
    static func bodyFont(size: CGFloat, weight: UIFont.Weight = .regular, family: String? = nil) -> UIFont {
        if let family {
            if family == "-apple-system" {
                return UIFont.systemFont(ofSize: size, weight: weight)
            }
            if let named = UIFont(name: family, size: size) {
                if weight == .regular { return named }
                let descriptor = named.fontDescriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: weight]
                ])
                return UIFont(descriptor: descriptor, size: size)
            }
        }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Splits an attributed string into page-sized slices using CoreText. The very
/// same framesetter output is what `PageImage` draws, so the computed slices
/// never overflow or leave gaps.
enum PageLayout {
    static func ranges(of attributed: NSAttributedString, in size: CGSize) -> [NSRange] {
        let length = attributed.length
        guard length > 0, size.width > 16, size.height > 16 else { return [] }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var ranges: [NSRange] = []
        var location = 0

        while location < length {
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            guard let last = lines.last else {
                // Not even one line fits: keep the remainder as a single page so
                // no text is silently dropped.
                ranges.append(NSRange(location: location, length: length - location))
                break
            }
            let lineRange = CTLineGetStringRange(last)
            var end = lineRange.location + lineRange.length
            if end <= location { end = min(location + 1, length) }
            end = min(end, length)
            ranges.append(NSRange(location: location, length: end - location))
            location = end
        }

        // Drop slices that are pure whitespace (a trailing newline often
        // produces one) so the book does not end on an empty page.
        let meaningful = ranges.filter { range in
            let piece = (attributed.string as NSString).substring(with: range)
            return !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return meaningful.isEmpty ? ranges : meaningful
    }
}
#endif
