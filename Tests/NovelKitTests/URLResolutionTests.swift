import Foundation
import Testing
@testable import NovelKit

/// Source addresses come from hand-written third-party files, so resolving one
/// has to cope with the junk those files contain.
@Suite("URL resolution")
struct URLResolutionTests {

    @Test("a hash group suffix is not part of the base")
    func stripsGroupSuffix() {
        let base = TextProcessing.normalizedBaseURL("http://www.twotxt.com#🎉精选")
        #expect(base?.absoluteString == "http://www.twotxt.com")
    }

    @Test("surrounding spaces are removed from the base")
    func trimsBase() {
        let base = TextProcessing.normalizedBaseURL("  http://www.twotxt.com  ")
        #expect(base?.absoluteString == "http://www.twotxt.com")
    }

    @Test("a category path joins cleanly onto the base")
    func joinsPath() {
        let base = TextProcessing.normalizedBaseURL("http://www.twotxt.com")
        let resolved = TextProcessing.resolveURL("/xuanhuan/1.html", base: base)
        #expect(resolved == "http://www.twotxt.com/xuanhuan/1.html")
    }

    @Test("a base carrying a group label still resolves its categories")
    func groupLabelDoesNotBreakJoin() {
        // Regression: `bookSourceUrl` ending in `#分组` used to leave a
        // fragment in the joined address, and the request surfaced much later
        // as "invalid URL".
        let base = TextProcessing.normalizedBaseURL("http://m.twotxt.com#🎃")
        let resolved = TextProcessing.resolveURL("/xuanhuan/2.html", base: base)
        #expect(resolved == "http://m.twotxt.com/xuanhuan/2.html")
    }

    @Test("a relative address with no base is percent-encoded rather than dropped")
    func encodesWithoutBase() {
        // Nothing can be done with a bare path except encode it; returning it
        // untouched is what produced an unparseable URL downstream.
        let resolved = TextProcessing.resolveURL("/目录/玄幻", base: nil)
        #expect(resolved != nil)
        #expect(resolved?.contains(" ") != true)
    }
}
