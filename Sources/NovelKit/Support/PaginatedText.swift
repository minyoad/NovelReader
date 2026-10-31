import Foundation

/// Paragraph segmentation plus the character-offset arithmetic a paginated
/// reader needs.
///
/// Chapter text arrives with messy whitespace and the cached reading progress
/// stores an offset into that raw text, while pagination works on the cleaned,
/// paragraph-joined body. This type owns the translation between the two so the
/// mapping can be unit tested without UIKit.
public struct PaginatedText: Hashable, Sendable {
    /// One rendered paragraph and where it starts in the original text.
    public struct Paragraph: Hashable, Sendable {
        public let text: String
        public let originalStart: Int

        public init(text: String, originalStart: Int) {
            self.text = text
            self.originalStart = originalStart
        }
    }

    public let paragraphs: [Paragraph]
    /// Paragraphs joined with a single newline; what actually gets laid out.
    public let body: String

    public init(rawText: String) {
        var paragraphs: [Paragraph] = []
        var cursor = 0
        for line in rawText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                // Count the stripped prefix in Characters (not bytes) and treat
                // full-width ideographic spaces as indentation too.
                let leading = line.prefix { $0.isWhitespace }.count
                paragraphs.append(Paragraph(text: trimmed, originalStart: cursor + leading))
            }
            cursor += line.count + 1
        }
        self.paragraphs = paragraphs
        self.body = paragraphs.map(\.text).joined(separator: "\n")
    }

    /// Maps a character offset in the raw chapter text to an offset in `body`.
    public func bodyOffset(forOriginal offset: Int) -> Int {
        guard let first = paragraphs.first else { return 0 }
        if offset <= first.originalStart { return 0 }

        var bodyCursor = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let end = paragraph.originalStart + paragraph.text.count
            if offset <= end {
                let local = max(offset - paragraph.originalStart, 0)
                return bodyCursor + min(local, paragraph.text.count)
            }
            bodyCursor += paragraph.text.count + 1
            if index == paragraphs.count - 1 { break }
        }
        return body.count
    }

    /// Inverse of `bodyOffset(forOriginal:)`.
    public func originalOffset(forBody offset: Int) -> Int {
        guard !paragraphs.isEmpty else { return 0 }
        var bodyCursor = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let end = bodyCursor + paragraph.text.count
            if offset <= end {
                let local = max(offset - bodyCursor, 0)
                return paragraph.originalStart + min(local, paragraph.text.count)
            }
            bodyCursor = end + 1
            if index == paragraphs.count - 1 { break }
        }
        guard let last = paragraphs.last else { return 0 }
        return last.originalStart + last.text.count
    }

    /// UTF-16 offset inside `body` for a character offset in `body`, which is
    /// what CoreText ranges use.
    public func utf16Offset(forBodyCharacter offset: Int) -> Int {
        let clamped = min(max(offset, 0), body.count)
        let index = body.index(body.startIndex, offsetBy: clamped)
        return body[..<index].utf16.count
    }

    /// Character offset in `body` for a UTF-16 offset (rounds down to a
    /// grapheme boundary so it is always safe to index).
    public func bodyCharacterOffset(forUTF16 offset: Int) -> Int {
        let clamped = min(max(offset, 0), body.utf16.count)
        guard clamped > 0 else { return 0 }
        if let utf16Index = body.utf16.index(
            body.utf16.startIndex,
            offsetBy: clamped,
            limitedBy: body.utf16.endIndex
        ), let index = String.Index(utf16Index, within: body) {
            return body.distance(from: body.startIndex, to: index)
        }
        // Landed inside a surrogate pair or a combining sequence: back up until
        // the position is a real character boundary.
        var candidate = clamped - 1
        while candidate > 0 {
            if let utf16Index = body.utf16.index(
                body.utf16.startIndex,
                offsetBy: candidate,
                limitedBy: body.utf16.endIndex
            ), let index = String.Index(utf16Index, within: body) {
                return body.distance(from: body.startIndex, to: index)
            }
            candidate -= 1
        }
        return 0
    }

    /// Convenience: raw chapter offset → UTF-16 offset inside `body`.
    public func bodyUTF16Offset(forOriginal offset: Int) -> Int {
        utf16Offset(forBodyCharacter: bodyOffset(forOriginal: offset))
    }

    /// Convenience: UTF-16 offset inside `body` → raw chapter offset.
    public func originalOffset(forBodyUTF16 offset: Int) -> Int {
        originalOffset(forBody: bodyCharacterOffset(forUTF16: offset))
    }
}
