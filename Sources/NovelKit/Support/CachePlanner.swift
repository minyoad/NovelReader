import Foundation

/// Decides which chapters to download ahead of the reader.
///
/// Kept free of networking and storage so the selection rules can be unit
/// tested: the reader hands over "what is already cached" and gets back the
/// list of chapter indices worth fetching.
public enum CachePlanner {

    /// Chapters to prefetch around the current one.
    ///
    /// Only fetches forward: a reader moves down the book far more often than
    /// up, and fetching backwards would fight with the *previous* chapter,
    /// which is usually already cached from having been read.
    public static func prefetchIndices(
        currentIndex: Int,
        chapterCount: Int,
        prefetchCount: Int,
        alreadyCached: Set<Int>
    ) -> [Int] {
        guard chapterCount > 0, prefetchCount > 0 else { return [] }
        guard currentIndex >= 0 else { return [] }

        var result: [Int] = []
        var index = currentIndex + 1
        while index < chapterCount && result.count < prefetchCount {
            if !alreadyCached.contains(index) {
                result.append(index)
            }
            index += 1
        }
        return result
    }

    /// Indices still missing from a whole-book download, in reading order,
    /// skipping the chapter being read so the UI never blocks on itself.
    public static func missingForWholeBook(
        chapterCount: Int,
        alreadyCached: Set<Int>,
        excluding currentIndex: Int? = nil
    ) -> [Int] {
        guard chapterCount > 0 else { return [] }
        return (0..<chapterCount).filter { index in
            if index == currentIndex { return false }
            return !alreadyCached.contains(index)
        }
    }

    /// Drops the oldest cached chapters once a book exceeds the per-book cap.
    ///
    /// "Oldest" means furthest from the reading position, so jumping back to an
    /// earlier chapter still finds it on disk. Returns the chapter URLs to
    /// delete, in the order they should go.
    public static func evictionCandidates(
        cachedChapterIndices: [Int],
        currentIndex: Int,
        limit: Int
    ) -> [Int] {
        guard limit > 0, cachedChapterIndices.count > limit else { return [] }
        let excess = cachedChapterIndices.count - limit
        return cachedChapterIndices
            .sorted { lhs, rhs in
                let lhsDistance = abs(lhs - currentIndex)
                let rhsDistance = abs(rhs - currentIndex)
                if lhsDistance != rhsDistance { return lhsDistance > rhsDistance }
                // Break ties by keeping the later chapter: reading moves forward.
                return lhs < rhs
            }
            .prefix(excess)
            .map { $0 }
    }
}
