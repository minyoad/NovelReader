import Foundation
import Testing
@testable import NovelKit

/// Discover-page categories come from a third-party format, so the parser has
/// to cope with the shapes real sources actually use.
@Suite("Explore categories")
struct ExploreParserTests {

    @Test("name::url lines become categories in order")
    func basicList() {
        let raw = """
        玄幻::/list/1_{{page}}.html
        都市::/list/2_{{page}}.html
        """
        let categories = ExploreParser.categories(from: raw)
        #expect(categories.map(\.name) == ["玄幻", "都市"])
        #expect(categories.first?.url == "/list/1_{{page}}.html")
    }

    @Test("blank lines and surrounding whitespace are ignored")
    func tolerantOfWhitespace() {
        let raw = """

           玄幻 :: /list/1_{{page}}.html 

           都市::/list/2_{{page}}.html

        """
        let categories = ExploreParser.categories(from: raw)
        #expect(categories.map(\.name) == ["玄幻", "都市"])
        #expect(categories.first?.url == "/list/1_{{page}}.html")
    }

    @Test("a URL containing a scheme keeps its colon")
    func absoluteURL() {
        let categories = ExploreParser.categories(from: "排行::https://example.com/top?p={{page}}")
        #expect(categories.first?.url == "https://example.com/top?p={{page}}")
    }

    @Test("`&&` also separates category entries")
    func ampersandSeparator() {
        // 🥈31小说 writes its whole list on one line; treating it as a single
        // address produced a nonsense URL and an "invalid link" error.
        let raw = "玄幻::/list/1/&&修真::/list/2/&&都市::/list/3/&&"
        let categories = ExploreParser.categories(from: raw)
        #expect(categories.map(\.name) == ["玄幻", "修真", "都市"])
        #expect(categories.first?.url == "/list/1/")
    }

    @Test("the page number is substituted into the address")
    func urlSubstitutesPage() {
        // Regression: the engine used to resolve `category.url` directly, and
        // `{{` is not valid in a URL, so every request went to `...page=%7B%7Bpage%7D%7D`.
        let category = ExploreCategory(name: "玄幻", url: "/xuanhuan?page={{page}}")
        #expect(ExploreParser.url(for: category, page: 1) == "/xuanhuan?page=1")
        #expect(ExploreParser.url(for: category, page: 7) == "/xuanhuan?page=7")
    }

    @Test("duplicate names keep only the first")
    func deduplicates() {
        let raw = """
        玄幻::/a{{page}}
        玄幻::/b{{page}}
        """
        #expect(ExploreParser.categories(from: raw).map(\.url) == ["/a{{page}}"])
    }

    @Test("lines without a separator are skipped rather than guessed at")
    func skipsMalformed() {
        let raw = """
        /orphan/url
        玄幻::/list/1_{{page}}.html
        没有地址::
        """
        #expect(ExploreParser.categories(from: raw).map(\.name) == ["玄幻"])
    }

    @Test("an empty explore rule yields no categories")
    func empty() {
        #expect(ExploreParser.categories(from: "").isEmpty)
    }

    @Test("paging substitutes the page number")
    func pageSubstitution() {
        let category = ExploreCategory(name: "玄幻", url: "/list/1_{{page}}.html")
        #expect(ExploreParser.url(for: category, page: 3) == "/list/1_3.html")
        // Page numbers below one are clamped: sources are 1-based.
        #expect(ExploreParser.url(for: category, page: 0) == "/list/1_1.html")
    }

    @Test("a category with no placeholder keeps its URL")
    func noPlaceholder() {
        let category = ExploreCategory(name: "玄幻", url: "/list/all.html")
        #expect(ExploreParser.url(for: category, page: 2) == "/list/all.html")
    }

    @Test("a per-category option block is split off the URL, not left on it")
    func perCategoryOptions() {
        // Real sources attach the parsing rules to each category line; the
        // address has to come out clean or every request 404s on a URL ending
        // in a JSON blob.
        let raw = #"排行::/top,{"ruleExplore":{"bookList":".item","name":"h3@text"}}"#
        let categories = ExploreParser.categories(from: raw)
        #expect(categories.count == 1)
        #expect(categories.first?.url == "/top")
        #expect(categories.first?.options["ruleExplore"]?["bookList"]?.stringValue == ".item")
    }

    @Test("a page placeholder in the address keeps its braces")
    func placeholderWithOptions() {
        // `{{page}}` is made of braces too, so the scanner must not mistake it
        // for the start of the option block.
        let raw = #"排行::/top?p={{page}},{"method":"POST"}"#
        let categories = ExploreParser.categories(from: raw)
        #expect(categories.first?.url == "/top?p={{page}}")
        #expect(categories.first?.options["method"]?.stringValue == "POST")
    }

    @Test("single-quoted option blocks parse too")
    func singleQuotedOptions() {
        let raw = #"排行::/top,{'method':'POST'}"#
        #expect(ExploreParser.categories(from: raw).first?.options["method"]?.stringValue == "POST")
    }

    @Test("a malformed option block keeps the address rather than dropping the category")
    func brokenOptions() {
        let raw = "排行::/top?p={{page}},{not json at all"
        let categories = ExploreParser.categories(from: raw)
        #expect(categories.count == 1)
        #expect(categories.first?.options.isEmpty == true)
        // The leftover text stays on the URL so the request at least has an address.
        #expect(categories.first?.url.contains("{not json") == true)
    }

    @Test("each category carries its own options")
    func optionsArePerCategory() {
        let raw = """
        玄幻::/a,{"method":"POST"}
        都市::/b
        """
        let categories = ExploreParser.categories(from: raw)
        #expect(categories[0].options["method"]?.stringValue == "POST")
        #expect(categories[1].options.isEmpty)
    }

    @Test("a POST body gets the page number")
    func bodyPaging() {
        let category = ExploreCategory(
            name: "排行",
            url: "/top",
            options: ["body": .string("page={{page}}&type=1")]
        )
        #expect(ExploreParser.body(for: category, page: 2) == "page=2&type=1")
        #expect(ExploreParser.body(for: ExploreCategory(name: "x", url: "/y"), page: 1) == nil)
    }

    @Test("a source whose categories have no rules cannot open its discover page")
    func unusableWithoutRules() {
        // `exploreUrl` without `ruleExplore` is the common half-configured
        // shape: the tabs would render and every one would fail.
        let source = BookSource(
            name: "无规则",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: "玄幻::/list/1_{{page}}.html"
        )
        #expect(source.canExplore == false)
        #expect(source.openableExploreCategories.isEmpty)
    }

    @Test("a source-level explore rule makes plain categories usable")
    func usableWithSourceRules() {
        let source = BookSource(
            name: "有规则",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: "玄幻::/list/1_{{page}}.html",
            explore: SearchRule(bookList: ".item", name: "a@text", bookURL: "a@href")
        )
        #expect(source.canExplore)
        #expect(source.openableExploreCategories.map(\.name) == ["玄幻"])
    }

    @Test("a category with its own rules is kept even when the source has none")
    func perCategoryRulesSuffice() {
        let raw = #"玄幻::/a,{"ruleExplore":{"bookList":".item","name":"a@text"}}"#
        let source = BookSource(
            name: "分类自备",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: raw
        )
        #expect(source.canExplore)
        #expect(source.openableExploreCategories.map(\.name) == ["玄幻"])
    }

    @Test("an empty ruleExplore falls back to the search rules")
    func fallsBackToSearchRules() {
        // The shape of 🎉耐看吧 and many other sources: a long exploreUrl, an
        // empty ruleExplore, and one complete ruleSearch. The listing page
        // uses the same markup as search, so falling back is what makes the
        // categories work at all.
        let source = BookSource(
            name: "耐看吧",
            baseURL: "http://m.twotxt.com",
            enabledExplore: true,
            exploreURL: "玄幻奇幻::/xuanhuan/{{page}}.html\n都市生活::/dushi/{{page}}.html",
            search: SearchRule(
                bookList: "class.list@tag.li",
                name: "tag.li.0@class.bookname@text",
                bookURL: "tag.li.0@class.bookname@tag.a@href"
            ),
            explore: SearchRule(bookList: "")
        )
        #expect(source.fallbackExploreRule.bookList == "class.list@tag.li")
        #expect(source.canExplore)
        #expect(source.openableExploreCategories.count == 2)
    }

    @Test("a source whose rules need JavaScript is not offered")
    func javaScriptRulesRejected() {
        // 🎉搜狗阅读 ships an obfuscated `@js:` list. The engine cannot run it,
        // so every tab would come back empty.
        let source = BookSource(
            name: "搜狗阅读",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: "玄幻::/xuanhuan/{{page}}.html",
            search: SearchRule(bookList: ".list li@js:var O=[\"x\"];"),
            explore: SearchRule(bookList: "")
        )
        #expect(source.canExplore == false)
        #expect(source.openableExploreCategories.isEmpty)
    }

    @Test("an explicit explore rule wins over the search fallback")
    func exploreRulesTakePrecedence() {
        let source = BookSource(
            name: "都有",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: "玄幻::/a",
            search: SearchRule(bookList: "class.search@tag.li"),
            explore: SearchRule(bookList: "class.explore@tag.li")
        )
        #expect(source.fallbackExploreRule.bookList == "class.explore@tag.li")
    }

    @Test("categories without rules are dropped, the rest survive")
    func mixedCategories() {
        let raw = """
        玄幻::/a,{"ruleExplore":{"bookList":".item","name":"a@text"}}
        都市::/b
        """
        let source = BookSource(
            name: "混合",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: raw
        )
        #expect(source.openableExploreCategories.map(\.name) == ["玄幻"])
    }

    @Test("an empty explore rule is not offered at all")
    func emptyExploreURL() {
        let source = BookSource(
            name: "空",
            baseURL: "https://example.com",
            enabledExplore: true,
            exploreURL: "",
            explore: SearchRule(bookList: ".item")
        )
        #expect(source.canExplore == false)
    }

    @Test("a disabled explore page is not offered")
    func disabledExplore() {
        let source = BookSource(
            name: "关闭",
            baseURL: "https://example.com",
            enabledExplore: false,
            exploreURL: "玄幻::/a",
            explore: SearchRule(bookList: ".item")
        )
        #expect(source.canExplore == false)
    }
}


