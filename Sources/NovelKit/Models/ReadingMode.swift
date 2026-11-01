import Foundation

/// How a reader session is allowed to touch the library.
///
/// A book opened from the shelf is read normally: progress is recorded and
/// chapters are cached. A **trial read** is opened from a search result that is
/// not on the shelf yet — the user is deciding whether to keep it — and must
/// leave no trace: recording progress would make a book nobody added the app's
/// "resume reading" target, and cached bodies would be files keyed by an id the
/// library never learns about, which nothing would ever expire.
///
/// The rule lives here, rather than as `!isPreview` sprinkled through the
/// reader, because "which writes are allowed" is exactly the kind of thing that
/// gets forgotten on one of the five call sites.
public enum ReadingMode: Equatable, Sendable {
    case shelf
    case preview

    /// Whether the reader may write `books.json` progress for this session.
    public var recordsProgress: Bool { self == .shelf }

    /// Whether chapter bodies and the table of contents may be written to disk.
    public var cachesChapters: Bool { self == .shelf }

    /// Whether source switching is offered. It rewrites the shelf entry, which
    /// a book that is not on the shelf does not have.
    public var canSwitchSource: Bool { self == .shelf }

    /// Whether the reader offers to keep the book when it closes.
    public var asksToAddToShelf: Bool { self == .preview }

    /// The mode for a reader opened with a preview's table of contents.
    public init(previewChapters: [Chapter]?) {
        self = previewChapters == nil ? .shelf : .preview
    }
}
