import Foundation

/// A remote position adopted by a successful merge which is actually farther
/// into the same edition, rather than merely carrying a newer timestamp.
public struct SyncProgressAdvance: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var localProgress: ReadingProgress
    public let remoteBook: Book

    public init(id: UUID, localProgress: ReadingProgress, remoteBook: Book) {
        self.id = id
        self.localProgress = localProgress
        self.remoteBook = remoteBook
    }

    public static func detect(local: [Book], merged: [Book]) -> [Self] {
        let previous = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return merged.compactMap { book in
            guard let old = previous[book.id], old.sourceID == book.sourceID,
                  old.detailURL == book.detailURL,
                  let remoteDate = book.progress.updatedAt,
                  remoteDate > (old.progress.updatedAt ?? .distantPast),
                  book.progress.isAhead(of: old.progress) else { return nil }
            return Self(id: old.id, localProgress: old.progress, remoteBook: book)
        }
    }
}

public extension ReadingProgress {
    func isAhead(of other: ReadingProgress) -> Bool {
        if chapterIndex != other.chapterIndex { return chapterIndex > other.chapterIndex }
        return characterOffset > other.characterOffset
    }

    var positionDescription: String {
        let chapter = chapterTitle.isEmpty ? "第\(chapterIndex + 1)章" : chapterTitle
        return "\(chapter) · 章内第 \(max(characterOffset, 0)) 字"
    }
}
