import Foundation

/// Which book the app should reopen when it starts.
///
/// Kept out of the view layer so the rule (and its edge cases) can be tested
/// without a UI: the shelf holds books that were never opened, and older
/// installs have progress without a `lastReadAt`.
public enum ReadingRecents {
    /// The book read most recently, or `nil` when nothing has been read yet.
    ///
    /// `lastReadAt` is the primary signal, but it is only written by the current
    /// build: progress saved by earlier versions carries `updatedAt` alone, and
    /// those books would otherwise never be resumed.
    public static func mostRecent(in books: [Book]) -> Book? {
        books
            .compactMap { book in
                readDate(of: book).map { (book: book, date: $0) }
            }
            .max { $0.date < $1.date }?
            .book
    }

    private static func readDate(of book: Book) -> Date? {
        if let lastReadAt = book.lastReadAt { return lastReadAt }
        // Never-opened books have no progress timestamp, so they are excluded
        // rather than being picked as "read at the epoch".
        return book.progress.isStarted ? book.progress.updatedAt : nil
    }
}
