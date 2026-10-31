import Foundation

/// Bundled content so the app is usable (and testable) before the user has
/// imported a working book source, plus a documented example of the legado
/// JSON format.
public enum BuiltinContent {

    public static let exampleLegadoJSON = """
    [
      {
        "bookSourceName": "示例书源",
        "bookSourceUrl": "https://www.example.com",
        "bookSourceGroup": "示例",
        "enabled": false,
        "searchUrl": "/search.php?keyword={{key}}",
        "ruleSearch": {
          "bookList": "@css:.book-list li",
          "name": "@css:a@text",
          "author": "@css:.author@text",
          "intro": "@css:.intro@text",
          "kind": "@css:.kind@text",
          "lastChapter": "@css:.last@text",
          "updateTime": "@css:.time@text",
          "bookUrl": "@css:a@href",
          "coverUrl": "@css:img@src"
        },
        "ruleBookInfo": {
          "name": "@css:h1@text",
          "author": "@css:.author@text",
          "intro": "@css:#intro@html",
          "coverUrl": "@css:.cover img@src",
          "tocUrl": ""
        },
        "ruleToc": {
          "chapterList": "@css:#list dd a",
          "chapterName": "@text",
          "chapterUrl": "@href"
        },
        "ruleContent": {
          "content": "@css:#content@html"
        }
      }
    ]
    """

    public static let sampleBookID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    public static let sampleSourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    // MARK: - Preset online sources

    /// A few real-world legado book sources, bundled so search works on a fresh
    /// install. They come from the public yuancang.cc collection, cleaned up to
    /// drop rules this engine cannot run (JS) and to point at live domains.
    ///
    /// Each source is stored as legado JSON so the app can re-export it, and
    /// imports through the normal `LegadoImporter` path — preset sources get no
    /// special treatment from the rule engine.
    /// Preset sources bundled on first launch. Kept as raw legado JSON (rather
    /// than constructed `BookSource` values) so the exact rules a user can see
    /// in the app match what the importer produced, and so a fixed ID can be
    /// attached afterwards.
    ///
    /// Only sites verified to serve complete chapter bodies belong here. Sites
    /// that hand out a handful of free chapters and then reply with
    /// "内容正在获取中，稍候重试" (bqg6 / b5200) are deliberately excluded.
    public static let presetLegadoJSON = """
    [
      {
        "bookSourceName": "得奇小说网",
        "bookSourceUrl": "https://www.deqitxt.com",
        "bookSourceGroup": "预置 · 全本",
        "bookSourceComment": "免费全文，实测《剑来》1300+ 章均有完整正文。来源：yuancang.cc",
        "bookSourceType": 0,
        "enabled": true,
        "enabledExplore": false,
        "searchUrl": "https://www.deqitxt.com/so/so.aspx?key={{key}}",
        "ruleSearch": {
          "bookList": "@css:div.container div.item",
          "name": "tag.h3@tag.a@text",
          "author": "tag.p.1@tag.a@text##作者：",
          "kind": "tag.p.0@tag.span.1@text",
          "lastChapter": "tag.ul@tag.li.0@tag.a@text",
          "bookUrl": "tag.h3@tag.a@href",
          "coverUrl": "tag.a@tag.img@src"
        },
        "ruleBookInfo": {
          "name": "class.itemtxt@tag.h1@tag.a@text",
          "author": "class.itemtxt@tag.p.1@tag.a@text##作者：",
          "intro": "class.des@text",
          "kind": "class.itemtxt@tag.p.0@tag.span.1@text",
          "coverUrl": "class.item@tag.img@src",
          "lastChapter": "class.itemtxt@tag.ul.0@tag.li.0@tag.a@text"
        },
        "ruleToc": {
          "chapterList": "id.list@tag.li@tag.a",
          "chapterName": "text",
          "chapterUrl": "href"
        },
        "ruleContent": {
          "content": "@css:div.con p@text",
          "nextContentUrl": "@css:div.prenext a:contains(下一页)@href"
        }
      },
      {
        "bookSourceName": "顶点小说 23uswx",
        "bookSourceUrl": "http://www.23uswx.la",
        "bookSourceGroup": "预置 · 全本",
        "bookSourceComment": "免费全文，目录分页拼接但正文完整；末尾几章与站点重复书目相连。来源：yuancang.cc",
        "bookSourceType": 0,
        "enabled": true,
        "enabledExplore": false,
        "searchUrl": "/modules/article/search.php?q={{key}}",
        "ruleSearch": {
          "bookList": "class.grid@tag.tr!0",
          "name": "tag.td.0@tag.a@text##（.*|\\\\(.*|免费阅读|全文.*阅读|最新章节|顶点小说",
          "author": "tag.td.2@text",
          "lastChapter": "tag.td.1@tag.a@text",
          "bookUrl": "tag.td.0@tag.a@href"
        },
        "ruleBookInfo": {
          "name": "id.info@tag.h1.0@text##（.*|\\\\(.*|免费阅读|全文.*阅读|最新章节|顶点小说",
          "author": "id.info@tag.p.0@text##作\\\\s*者：",
          "intro": "id.intro@text",
          "coverUrl": "id.fmimg@tag.img@src",
          "lastChapter": "id.info@tag.p.3@tag.a@text"
        },
        "ruleToc": {
          "chapterList": "id.list@tag.dd",
          "chapterName": "tag.a@text",
          "chapterUrl": "tag.a@href"
        },
        "ruleContent": {
          "content": "id.content@html##最新网址.*|顶点小说.*|请记住我们的网址.*"
        }
      }
    ]
    """

    /// Fixed IDs so a preset keeps its identity across launches (bookmarks and
    /// library entries reference `sourceID`).
    private static let presetIDs: [String: UUID] = [
        "得奇小说网": UUID(uuidString: "B5200000-0000-4000-8000-000000000001")!,
        "顶点小说 23uswx": UUID(uuidString: "B5200000-0000-4000-8000-000000000002")!,
    ]

    /// All preset IDs live in this prefix. Used to recognise preset entries
    /// (including ones shipped by older builds) when migrating.
    public static func isPresetID(_ id: UUID) -> Bool {
        id.uuidString.hasPrefix("B5200000-0000-4000-8000-")
    }

    /// Bumping this value re-runs the preset migration on the next launch.
    /// Bump it whenever `presetLegadoJSON` changes in a way that must reach
    /// devices that already ran an older build.
    public static let presetVersionFlag = "presetSourcesV2"

    /// Parsed preset sources. Returns `[]` if the bundled JSON is ever broken,
    /// so a bad preset can never block startup.
    public static var presetSources: [BookSource] {
        guard let result = try? LegadoImporter.importSources(fromJSON: presetLegadoJSON) else {
            return []
        }
        return result.sources.map { source in
            var copy = source
            if let id = presetIDs[source.name] { copy.id = id }
            return copy
        }
    }


    public static var sampleSource: BookSource {
        BookSource(
            id: sampleSourceID,
            name: "离线示例",
            baseURL: "local://sample",
            group: "内置",
            comment: "内置的离线示例，用来体验阅读、TTS 和 AI 整理，不联网。",
            enabled: true,
            isBuiltIn: true
        )
    }

    public static var sampleChapters: [Chapter] {
        chapters.enumerated().map { index, chapter in
            Chapter(index: index, title: chapter.title, url: "local://sample/\(index)")
        }
    }

    public static var sampleBook: Book {
        Book(
            id: sampleBookID,
            sourceID: sampleSourceID,
            sourceName: "离线示例",
            detailURL: "local://sample",
            name: "长夜灯下",
            author: "示例文本",
            intro: "这是一本内置的离线样章，用来在没有书源的情况下体验阅读器、语音朗读和 AI 文本整理。正文为演示用文字，非真实出版物。",
            kind: "示例 / 短篇",
            lastChapterTitle: chapters.last?.title ?? "",
            progress: ReadingProgress(),
            addedAt: Date()
        )
    }

    public static func content(forChapterAt index: Int) -> String? {
        guard chapters.indices.contains(index) else { return nil }
        return chapters[index].body
    }

    private struct SampleChapter {
        var title: String
        var body: String
    }

    private static let chapters: [SampleChapter] = [
        SampleChapter(
            title: "第一章 灯下",
            body: """
            城里最后一家旧书店开在巷子尽头，门脸窄得只容一个人侧身进去。

            老板姓周，六十来岁，戴一副镜腿用胶布缠过的眼镜。他每天下午四点开门，晚上十点关灯，中间从不休息，也从不多说一句话。熟客都知道，问他书在哪里，他会抬手指一下方向；问他价钱，他会把算盘拨得噼啪响，然后在本子上写一个数字。

            那天傍晚下着雨。一个背着帆布包的年轻人推门进来，雨水顺着他的裤脚滴在木地板上，很快就积成一小滩。

            「周叔。」年轻人说，「我来还书。」

            周老板从账本上抬起头，看了他一会儿，才慢慢把眼镜摘下来。镜片上一层薄薄的雾，他用手背擦了擦，又重新戴上。

            「三年了。」他说。

            年轻人笑了笑，把帆布包放在柜台上，从里面取出一本用牛皮纸包着的书。纸已经发黄，边角起毛，看得出被翻过很多次。他把书推过去，手指在封面上停了一瞬，又收了回来。

            周老板没有立刻去接。他只是看着那本书，像在看一件很久以前的事情。
            """
        ),
        SampleChapter(
            title: "第二章 旧页",
            body: """
            书的名字很朴素，四个字：《灯下杂记》。没有作者，没有出版社，扉页上只有一行钢笔字，写着一个日期，和一句谁也看不懂的话——「灯亮着，人就还在」。

            年轻人叫沈舟。三年前的这个时候，他也是这样站在柜台前，只不过那时候他手里空空，身上也没有钱，只是进来躲雨。

            那天周老板给了他一把椅子，一杯热茶，还有这本《灯下杂记》。「看完再还。」老板当时说，「不着急。」

            不着急这三个字，一说就是三年。

            沈舟后来去了很远的城市，换过几份工作，搬过七次家。这本书一直跟着他，被塞在行李箱最底层，和几件旧衣服挤在一起。有几次他想寄回来，又觉得应该亲手还。

            「书我看完了。」沈舟说，「但是有一页，我一直没读懂。」

            周老板翻开书，翻到中间偏后的位置。那里夹着一张薄薄的纸，纸上是密密麻麻的字，被水浸过，边缘晕开，像一片模糊的云。

            「这页写的是什么？」沈舟问。

            老板沉默了很久，久到窗外的雨都小了下来。然后他说：「写的是一个人，怎么把一间书店开了四十年。」
            """
        ),
        SampleChapter(
            title: "第三章 灯灭之前",
            body: """
            书店是周老板的父亲留下的。那时候这条巷子还很热闹，街口有卖糖粥的，有修钟表的，有在夏天把竹床搬到门口乘凉的人。

            后来巷子一点点安静下来。先是钟表铺关了门，再后来是糖粥摊，最后连街口的路灯也换成了感应灯，人走过去才会亮。

            书店却一直开着。周老板说，不是因为他喜欢书，而是因为有些人需要知道，这条巷子尽头还有一盏灯。

            「你父亲写的那句话，」沈舟说，「是什么意思？」

            周老板把那张薄纸小心地夹回书里，合上，双手按在封面上。

            「意思是，只要还有人愿意在夜里推门进来，这盏灯就不算白点。」

            雨停了。巷子里传来收摊的三轮车碾过石板的声音。沈舟站起来，把椅子推回原位。

            他本来想说，我下个月再来。但他知道，下个月他大概又会去另一个城市，又会把这件小事往后推。

            于是他只是说：「周叔，我帮您把门口那块牌子擦一下吧。」

            周老板愣了一下，笑了。那是沈舟第一次看见他笑。

            「好。」他说，「抹布在水缸边上。」
            """
        ),
    ]
}
