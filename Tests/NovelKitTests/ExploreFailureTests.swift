import Foundation
import Testing
@testable import NovelKit

/// Filtering dead discover pages is only worth having if it keeps the working
/// ones, so the decision of what a failure takes down with it is tested.
@Suite("Explore failure scope")
struct ExploreFailureTests {

    @Test("a missing section address only hides that tab")
    func missingAddressIsLocal() {
        #expect(ExploreFailure.failsWholeSource(HTTPError.badStatus(404, "https://x/sort/2/")) == false)
        #expect(ExploreFailure.failsWholeSource(HTTPError.badStatus(410, "https://x/old/")) == false)
        #expect(ExploreFailure.failsWholeSource(HTTPError.badURL("http://x/<,1.html>")) == false)
    }

    @Test("an unreachable host takes the whole source with it")
    func unreachableHostIsWide() {
        #expect(ExploreFailure.failsWholeSource(HTTPError.transport("未能找到使用指定主机名的服务器。")) == true)
        #expect(ExploreFailure.failsWholeSource(HTTPError.transport("请求超时。")) == true)
        #expect(ExploreFailure.failsWholeSource(HTTPError.invalidResponse) == true)
        #expect(ExploreFailure.failsWholeSource(HTTPError.emptyBody("https://x/list")) == true)
    }

    @Test("a site that blocks or fails server-side fails every tab")
    func blockedOrBrokenIsWide() {
        #expect(ExploreFailure.failsWholeSource(HTTPError.badStatus(403, "https://x/lianzai/")) == true)
        #expect(ExploreFailure.failsWholeSource(HTTPError.badStatus(521, "https://x/xuanhuan/")) == true)
        #expect(ExploreFailure.failsWholeSource(HTTPError.badStatus(503, "https://x/")) == true)
    }

    @Test("a rule that no longer matches takes the whole source down")
    func staleRuleIsWide() {
        // The page opened but its selectors matched nothing: every category of
        // that source is parsed by the same rules.
        #expect(ExploreFailure.failsWholeSource(SourceError.noResults("没有匹配到内容")) == true)
        #expect(ExploreFailure.failsWholeSource(SourceError.unsupported("没有配置发现页")) == true)
    }

    @Test("a chapter-level failure says nothing about the source")
    func contentErrorsAreLocal() {
        #expect(ExploreFailure.failsWholeSource(SourceError.notFound("章节不存在")) == false)
        #expect(ExploreFailure.failsWholeSource(SourceError.emptyContent("正文为空")) == false)
    }

    @Test("an unrecognised error counts as local")
    func unknownIsLocal() {
        struct Mystery: Error {}
        // A wrong guess here costs one tab; hiding a working source costs the
        // reader the whole source.
        #expect(ExploreFailure.failsWholeSource(Mystery()) == false)
    }
}
