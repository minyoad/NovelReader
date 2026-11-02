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
    /// Returns the slices of `attributed` that fit into `size`.
    ///
    /// `firstLineIndent` is applied per page rather than baked into the whole
    /// string. A page that starts mid-paragraph holds the tail of a wrapped
    /// paragraph, and CoreText treats the first line of a frame as a paragraph
    /// first line — so a single `firstLineHeadIndent` on the body would indent
    /// the top of every page, even when it is a continuation. Here only slices
    /// that begin at a real paragraph start keep the indent.
    ///
    /// `text` is the source `attributed` was built from; it answers whether a
    /// slice starts a paragraph (see `PaginatedText.startsParagraph(atBody:)`).
    static func ranges(
        of attributed: NSAttributedString,
        text: PaginatedText,
        in size: CGSize
    ) -> [ReaderPage] {
        let length = attributed.length
        guard length > 0, size.width > 16, size.height > 16 else { return [] }

        var pages: [ReaderPage] = []
        var location = 0
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)

        // Newlines are paragraph boundaries, never page content.
        let body = attributed.string as NSString
        let newlineCode = unichar(("\n" as Unicode.Scalar).value)

        // Measure the whole body once, with the indent always applied. Pages are
        // then cut on that basis and the first-line indent of a page that
        // continues a paragraph is removed only at draw time (`ReaderPage.
        // drawable`), which is safe: dropping an indent frees space, it never
        // asks for more.
        //
        // Measuring with a variant that already lacked the indent would be the
        // dangerous direction — a page would fit more characters there and then
        // overflow once drawn — and building that variant per page meant
        // remeasuring a substring whose offsets no longer lined up with the body.
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        while location < length {
            // A slice starting at 0 or right after a newline is a real paragraph
            // start and keeps the indent; anything else is a wrapped tail whose
            // first line is drawn flush.
            let startsParagraph = text.startsParagraph(
                atBody: text.bodyCharacterOffset(forUTF16: location)
            )

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
                pages.append(ReaderPage(
                    range: NSRange(location: location, length: length - location),
                    startsParagraph: startsParagraph
                ))
                break
            }
            let lineRange = CTLineGetStringRange(last)
            // Absolute: the frame was built over the whole body.
            var end = lineRange.location + lineRange.length
            if end <= location { end = min(location + 1, length) }
            end = min(end, length)

            // The line range includes the trailing newline. Keeping it would make
            // CoreText lay out a blank line at the bottom of the page, and its
            // height depends on the next paragraph's spacing — the page then
            // ends with a variable gap. A newline is a paragraph boundary, not
            // content, so it is skipped rather than handed to the next page (a
            // string starting with a break lays out an empty first line).
            while end > location, body.character(at: end - 1) == newlineCode {
                end -= 1
            }
            if end <= location { end = min(location + 1, length) }
            pages.append(ReaderPage(
                range: NSRange(location: location, length: end - location),
                startsParagraph: startsParagraph
            ))

            // Step over the break so the next page opens on real text.
            var next = end
            while next < length, body.character(at: next) == newlineCode {
                next += 1
            }
            location = next
        }

        // Drop pages that are pure whitespace (a trailing newline often produces
        // one) so the book does not end on an empty page.
        let meaningful = pages.filter { page in
            let piece = (attributed.string as NSString).substring(with: page.range)
            return !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return meaningful.isEmpty ? pages : meaningful
    }
}

/// One page of a paginated chapter: which characters it shows, and whether
/// they open a paragraph.
///
/// The flag has to travel with the range. `PageImage` draws each page by
/// building its own framesetter over the slice, and CoreText indents the first
/// line of any frame — so a page that merely continues a paragraph looks
/// indented when drawn unless the slice's paragraph style is flattened first.
struct ReaderPage: Equatable {
    let range: NSRange
    /// True when `range.location` is the start of a paragraph and the page
    /// should keep the first-line indent.
    let startsParagraph: Bool

    /// The slice to hand to CoreText, ready to draw.
    ///
    /// Only the page's own first line may lose the indent. Paragraph style is
    /// a run attribute, so clearing it across the whole slice would also strip
    /// the indent from every paragraph that starts inside this page. Instead
    /// the slice is cut at newlines: the head gets the flush style when the page
    /// continues a paragraph, and each later paragraph keeps the original style.
    func drawable(from attributed: NSAttributedString) -> NSAttributedString {
        let slice = NSMutableAttributedString(attributedString: attributed.attributedSubstring(from: range))
        guard slice.length > 0 else { return slice }

        let original = slice.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        guard let original, original.firstLineHeadIndent > 0,
              let flushStyle = Self.flushCopy(of: original) else {
            return slice
        }

        // Cut points: 0, then one run per paragraph after each newline.
        let ns = slice.string as NSString
        var starts: [Int] = [0]
        var searchFrom = 0
        while searchFrom < ns.length {
            let found = ns.range(
                of: "\n",
                options: [],
                range: NSRange(location: searchFrom, length: ns.length - searchFrom)
            )
            if found.location == NSNotFound { break }
            searchFrom = found.location + 1
            // A newline at the very end opens no paragraph inside this slice.
            if searchFrom < ns.length { starts.append(searchFrom) }
        }

        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : slice.length
            // The first run is this page's opening line; later runs each begin a
            // paragraph, so they keep the indent.
            let style = index == 0 && !startsParagraph ? flushStyle : original
            slice.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: start, length: end - start)
            )
        }
        return slice
    }

    private static func flushCopy(of style: NSParagraphStyle) -> NSParagraphStyle? {
        guard let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return nil }
        copy.firstLineHeadIndent = 0
        return copy
    }
}
#endif
