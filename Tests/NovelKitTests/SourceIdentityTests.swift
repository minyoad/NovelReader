import Testing
import Foundation
@testable import NovelKit

/// `SourceIdentity` is what both the importer and the sync merge use to decide
/// "this is already here". If it is too loose, imports silently overwrite
/// different sites; too tight, and every re-import duplicates the collection.
@Suite("Source identity")
struct SourceIdentityTests {

    @Test("the same name and site match")
    func sameNameSameSite() {
        let a = SourceIdentity(name: "快眼看书", baseURL: "http://www.booksky.cc")
        let b = SourceIdentity(name: "快眼看书", baseURL: "http://www.booksky.cc")
        #expect(a == b)
    }

    @Test("a # fragment and trailing slashes are ignored")
    func normalizedURL() {
        let clean = SourceIdentity(name: "快眼看书", baseURL: "http://www.booksky.cc")
        let dirty = SourceIdentity(name: "快眼看书", baseURL: "  http://www.booksky.cc/#🎃  ")
        #expect(clean == dirty)
    }

    @Test("different sites with the same name do not match")
    func sameNameDifferentSite() {
        // 笔趣阁 is several unrelated sites.
        let a = SourceIdentity(name: "笔趣阁", baseURL: "https://a.example.com")
        let b = SourceIdentity(name: "笔趣阁", baseURL: "https://b.example.com")
        #expect(a != b)
    }

    @Test("one site under two names does not match")
    func sameSiteDifferentName() {
        // Two rules for one site can be deliberate; folding them deletes one.
        let a = SourceIdentity(name: "快眼看书", baseURL: "http://www.booksky.cc")
        let b = SourceIdentity(name: "快眼看书botaodz", baseURL: "http://www.booksky.cc")
        #expect(a != b)
    }

    @Test("surrounding whitespace in the name is ignored")
    func trimmedName() {
        let a = SourceIdentity(name: " 快眼看书 ", baseURL: "http://www.booksky.cc")
        let b = SourceIdentity(name: "快眼看书", baseURL: "http://www.booksky.cc")
        #expect(a == b)
    }

    @Test("a source built from a BookSource matches an imported one")
    func fromSource() {
        let source = BookSource(name: "得奇小说网", baseURL: "https://www.deqixs.org/")
        let imported = SourceIdentity(name: "得奇小说网", baseURL: "https://www.deqixs.org")
        #expect(SourceIdentity(of: source) == imported)
    }
}
