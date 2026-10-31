# 夜读 · NovelReader

一个用 SwiftUI 写的 iOS 网络小说阅读器：导入「阅读 / legado」书源，搜索、加入书架、离线缓存章节，支持多种语音朗读引擎（TTS）和 OpenAI 兼容接口的 AI 文本整理。

引擎（`NovelKit`）只依赖 Foundation，可以在 Linux 上编译和跑单测；App 层（`NovelReader`）用 `#if canImport(SwiftUI)` 包裹，因此同一个工程既能 `swift test` 也能用 [xtool](https://github.com/xtool-org/xtool) 在没有 macOS 的机器上构建 iOS App。

## 功能

- **书源**：兼容 legado 书源 JSON 的常用子集，支持搜索 / 详情 / 目录 / 正文 / 下一页。
- **书架**：最近阅读排序、阅读进度（章节 + 字符偏移）、移出书架、清缓存。
- **阅读器**：字号 / 行距 / 段距 / 边距 / 四种主题（纸白、米黄、深灰、纯黑）、目录跳转、上下章、阅读进度保存。
- **翻页**：两种模式——连续滚动，或左右滑动分页（默认）。分页用 CoreText 精确排版，滑动跟手、松手按位移或甩动速度判定翻页；跨章时显示「上一章 / 下一章」提示页。三种翻页效果：覆盖（整页跟手位移）、淡入、仿真（从**右上角**掀起去翻下一页，**左上角**掀起退回上一页：斜折痕，折痕旁一条卷曲带显示绕折痕镜像的纸背，更远处露出下一页，带子随进度张开再收拢，左右两个方向互为镜像）。朗读时自动翻到正在读的那一页，并高亮当前句。
- **排版**：字号 / 行距 / 段距 / 边距、首行缩进两字、两端对齐、章节标题可关；字体可选系统衬线、系统无衬线、苹方、宋体、楷体、圆体。缩进用段落样式实现而不改写文本，字符偏移不变，阅读进度不会错位。
- **换源**：阅读器顶栏和书目详情页都能打开候选书源列表，每个候选可先「试读这一章」，确认能取到正文再切换；切过去后按章节标题保留阅读进度。
- **离线缓存**：阅读时后台预缓存接下来 N 章（默认 5，可设 0 关闭），断网也能继续往下读；支持「缓存全本」带进度、每本缓存上限（超出后优先清理离阅读位置最远的章节）、按本清理与占用统计；加入书架时可选择自动缓存全本。
- **TTS**：三种引擎——系统朗读（离线）、微软 Edge 在线朗读（免费、无需注册，音色接近真人）、自定义 OpenAI 兼容 `/audio/speech`（可指向本地部署的模型）。按整句分组请求，服务端返回的句级时间戳用来驱动高亮；暂停/继续、上一句/下一句、语速与音调、读完自动下一章；音频按句缓存，重复收听不联网，超出上限后按最久未听淘汰。已声明 `UIBackgroundModes: audio`，锁屏后继续播。
- **AI 整理**：OpenAI 兼容 `/chat/completions`，分块处理长章节，三种模式（清理排版 / 校对纠错 / 精简去水），可附加自定义要求；输出格式可选按段换行 / 保留原换行 / 整段连排 / 段间空行，整理前的原文会保留，可一键还原；另可整理书籍简介。
- **离线可用**：内置示例书《长夜灯下》3 章 + 内置离线书源，无网络也能体验阅读、TTS、AI（AI 需自行配置 key）。
- **隐私**：AI API Key 存在系统钥匙串，不写入普通配置文件。

## 目录结构

```
NovelReader/
├── Package.swift                 SwiftPM 工程（xtool 使用单一 library product）
├── xtool.yml                     bundleID / Info.plist / 图标位置
├── Info.plist                    显示名、后台音频、ATS、版本号
├── AppIcon.png                   1024×1024 主图标，xtool 由此生成各尺寸
├── Docs/app-icon-preview.png     图标预览（README 用）
├── Docs/curl-geometry.png        仿真翻页几何验证渲染图
├── Tools/verify-curl-geometry.py 在 Linux 上验证翻页几何（numpy + Pillow）
├── Sources/
│   ├── NovelKit/                 纯 Swift 引擎，可在 Linux 上编译和测试
│   │   ├── Models/               Book / BookSource / Settings / JSONValue
│   │   ├── Network/              HTTPClient（Cookie、重试、编码识别）
│   │   ├── Source/               RuleEngine / JSONPath / SourceEngine / LegadoImporter
│   │   ├── Store/                LibraryStore（文件 JSON 持久化 + 朗读音频缓存）
│   │   ├── AI/                   AIClient + 提示词 / 分块
│   │   ├── TTS/                  EdgeToken / EdgeTTSClient / OpenAISpeechClient
│   │   └── Support/              文本处理、编码识别、分句分块、内置示例
│   └── NovelReader/              SwiftUI App（Linux 上被 #if canImport(SwiftUI) 跳过）
│       ├── App/                  AppModel、入口、Tab
│       ├── Design/               主题、封面、Banner、空状态
│       └── Features/             书架 / 详情 / 阅读器 / 搜索 / 书源 / 设置 / TTS
└── Tests/NovelKitTests/          规则引擎与流水线测试（65 个）
```

## 构建与测试

```bash
# 引擎单测（Linux / macOS 本机，不需要 iOS SDK）
swift test

# 只编引擎
swift build --target NovelKit

# 编 iOS App（产物：xtool/NovelReader.app）
xtool dev build

# 装到已连接的真机
xtool devices
xtool dev
```

首次构建或改依赖后，如果 SwiftPM 需要联网：

```bash
xtool-proxy dev build
```

> xtool 不读 `http_proxy`，联网操作请走 `xtool-proxy`。
> 真机安装需要 Apple 账号签名，先跑 `xtool setup` 完成登录。

### App 图标

图标只由 `xtool.yml` 的一行决定：

```yaml
iconPath: ./AppIcon.png
```

xtool 发现 `iconPath` 后，会把主图拷进 app bundle 根目录，并在生成的 `Info.plist` 里写入 `CFBundleIconFile`，由 iOS 自行缩放取用。因此仓库里只保留一份 1024×1024 的 `AppIcon.png`，不需要各尺寸副本，也不需要 `.xcassets`。

**不要**在 target 里放 `.xcassets`：Linux 上没有 `actool`，xtool 一旦发现资源目录里有 asset catalog，就会去调用它并直接构建失败（`actool is not an executable file`）。

### 仿真翻页是怎么算的

模型是**捏住纸角掀起**，不是沿一条竖线把纸对折。掀的是**上面的角**：往下一页翻时是右上角，往上一页翻时是左上角，折痕从顶边往下扫。

**手指捏住的是卷曲的自由边**，所以卷边始终贴着手指；折痕在手指前方一个卷带宽度处，折痕之外露出下一页。卷带最大宽度约为页宽的 16%（手机上是 60pt 上下），随进度从 0 张开、末端再收拢到 0，因此一碰屏幕不会凭空冒出一条带子，翻完之后也没有残留。

按到参考线的有向距离 `d` 分三段（`d = 0` 在手指处，朝折痕方向为正）：

| 区域 | 画什么 |
| --- | --- |
| `d <= -band` | 当前页正面，平整 |
| `-band < d < 0` | 卷曲带：纸背，绕折痕逐像素反射采样 |
| `d >= 0` | 下一页，已露出 |

`band` 随进度先张开再收拢，进度到 1 时收敛到 0，所以最后一帧是干净的下一页、静止时没有残留。几何全在 `CurledPage.swift` 的 `CurlGeometry` 里，拖动进度直接参数化折痕，不再反解触点。

参考了 legado 的 `SimulationPageAnim`，但没有照搬它的 `calcPoints`：触点与页角同水平线时它会除以约 0 的数，把第二条贝塞尔曲线甩到页面外几万像素，纸舌下半页消失；而且末端翻不完。

几何可以在 Linux 上单独验证，不需要真机：

```bash
python3 Tools/verify-curl-geometry.py   # 需要 numpy + Pillow
```

脚本复刻了 Swift 里的同一套公式，检查三区域是否恰好覆盖整页且零重叠、末端带子是否收敛到 0、左右方向是否严格互为镜像，并把序列渲染到 `Tools/out/swift-geometry.png`。


## 导入书源

三种方式：

1. 书源页 →「粘贴书源 JSON」→ 粘贴 legado 导出内容 → 导入。
2. 书源页 →「直接读取剪贴板」。
3. 书源页 →「从链接导入」→ 填书源 JSON 的直链。

同一个站点（`bookSourceUrl` 相同）重复导入会覆盖旧配置而不是产生重复项。每个书源可以单独启用/停用、编辑规则、查看原始 JSON、删除。

### 预置书源

首次启动会写入两个可直接用的联网书源（来自 [yuancang.cc](https://yuancang.cc) 的公开合集，已按本站引擎能力整理，去掉了 JS 规则并指向当前可用域名）：

| 书源 | 站点 | 特点 |
| --- | --- | --- |
| 得奇小说网 | `www.deqitxt.com` | 免费全文，目录单页全量；实测《剑来》1302 条目录正文可读（1225 条正传 + 77 条从「第1章」重新编号的番外） |
| 顶点小说 23uswx | `www.23uswx.la` | 免费全文，目录单页全量；实测《凡骨》4051 章（含大结局与番外）正文完整 |

目录到正文结束处重新编号（番外从「第1章」开始）是站点自身的排法，不是解析错误：
引擎按目录顺序翻页，章节标题只作显示，进度以「章节序号 + 字符偏移」记录，因此不受影响。

选源时只保留**正文真的能取到**的站点。像 bqg6 / b5200 这类站点前几章免费、之后统一返回
`小说《××》的最新章节《××》内容正在获取中，稍候重试。。。` 的，会被排除在外：
引擎现在会识别这种占位正文并直接报错「站点未返回正文（付费墙或占位内容），请换一个书源」，
而不是把它当成正文缓存下来。

预置书源有固定 ID。升级 App 且预置集合变化时（`BuiltinContent.presetVersionFlag` 控制版本），
会按预置 ID 段替换旧预置，自己导入的书源不受影响；日常启动不会重复写入。删掉后重启不会自动加回来。

内置的「离线示例」书源不可联网，只用于体验；`设置 → 关于 → 书源规则说明` 里能看到一份可参考的示例 JSON。

### 支持的规则语法

| 语法 | 示例 | 说明 |
| --- | --- | --- |
| CSS | `@css:.book-list li a@href` | 支持 `@text` `@html` `@outerHtml` `@href` `@src` `@attr.xxx` |
| legado 路径 | `class.book-list@tag.li@tag.a@href` | `class.` / `tag.` / `id.` / `text.` → CSS |
| 行内索引 | `class.odd.0@tag.a.1@text` | 每一级取第 n 个匹配（按父节点分别计算，等价 legado 语义） |
| 列表排除 | `tag.tr!0`、`class.box_con@tag.dd!0:1:2` | 下标为**排除**项；`!-1` 从末尾数 |
| 数量限制 | `tag.li:lt(20)` | 只取前 n 个 |
| XPath | `@XPath://div[@id='list']//dd/a/@href` | 转换常用子集（tag、@class、@id、属性、序号） |
| JSONPath | `$.data.list[*].name`、`$..name` | 支持 `*`、`[n]`、`..key`、`[a,b]` |
| 回退链 | `规则A@@规则B` | A 无结果时用 B |
| 或 / 且 | `规则A\|\|规则B`、`规则A&&规则B` | `\|\|` 依次尝试；`&&` 拼接（用于分类 + 状态） |
| 正则替换 | `规则##pattern##replacement` | 省略 replacement 表示删掉匹配内容 |
| 提取后缀 | `@text` / `@html` / `@textNodes` / `@ownText` | 也可单独写在列表项规则里，表示当前节点 |
| 变量 | `{{key}}` `{{page}}` | 搜索地址、POST body 自动替换 |

不支持的：`@js:` / `<js>` JavaScript 规则（会在导入/使用时提示并跳过）。这类书源仍可导入，但对应字段为空，需要手动改成 CSS/XPath 规则。

### 编码

正文抓取自动处理 UTF-8、GBK/GB18030、Big5、UTF-16 与 BOM，并会嗅探 `<meta charset>`。

## AI 整理配置

`设置 → AI 整理`：

- 预置 OpenAI / DeepSeek / Kimi / 智谱 / SiliconFlow / Ollama（本地）以及自定义。
- 填写接口地址（可带 `/v1`）、模型名、API Key；「测试连接」会发一次最小请求。
- 高级参数：temperature、最大输出 tokens、分块字数（默认 1800 字/块）、超时、额外整理要求。

阅读器右上角 ✨ 选择整理模式（清理排版 / 校对纠错 / 精简去水）。整理结果里的段落格式可选：

| 格式 | 效果 |
| --- | --- |
| 按段换行 | 每段一行，段距由阅读设置统一控制（默认） |
| 保留原换行 | 完全沿用模型输出里的换行，包括空行 |
| 整段连排 | 所有段落合并成一整段，适合小屏快速扫读 |
| 段间空行 | 段落之间插入空行，观感更松散 |

格式既写进 prompt，也会在拿到结果后按格式再规整一次——长章节分块整理时模型看不到跨块边界，只在 prompt 里提要求会前后不一致。

整理前会保留抓取到的原文（`ChapterContent.originalText`），随时可用 ✨ 菜单里的「还原为站点原文」切回去，不需要重新联网。还原后清理版副本会被丢弃。

## 数据存放

App 沙盒 `Application Support/NovelReader/`：

```
books.json               书架与阅读进度
sources.json             书源配置
settings.json            阅读 / TTS / 网络 / AI 设置（不含 key）
chapters/<book>-toc.json 目录缓存
chapters/<book>-<hash>.json 章节正文缓存（含整理前的原文时体积约为两倍）
speech/<hash>.mp3        朗读音频缓存（按句，文件时间即「最后收听时间」）
```

`settings.json` 里与阅读体验相关的字段：

```
reading.fontSize / lineSpacing / paragraphSpacing / horizontalPadding
reading.theme / pageTurnMode / pageTurnEffect
reading.fontFamily / firstLineIndent / alignment / showChapterTitle
reading.followSystemAppearance  跟随系统深/浅色（选中主题决定用哪一族色）
aiOutputFormat           AI 整理后的段落格式
tts.engine               朗读引擎：system / edge / openAICompatible
tts.remote               远端引擎参数（Edge 音色、自定义接口地址与音色）
tts.cacheEnabled / tts.cacheLimitMB  朗读音频缓存开关与上限（0 = 不限）
cache.prefetchCount      阅读时预缓存的章节数（0 = 关闭）
cache.maxCachedChaptersPerBook  每本缓存上限（0 = 不限，超出后清理离阅读位置最远的章节）
cache.autoCacheOnAdd     加入书架时自动缓存全本
```

这些字段全部做了容错解码：旧版本写下的 `settings.json` 缺少新字段时取默认值，不会因为升级把已有设置重置。

AI Key 单独存 Keychain（service `com.yang.NovelReader`）。

`tts.remote.apiKey`（自定义朗读接口的密钥）同样只存 Keychain，`settings.json` 里始终是空字符串。

## 朗读引擎说明

| 引擎 | 费用 | 联网 | 音质 | 备注 |
| --- | --- | --- | --- | --- |
| 系统朗读 | 免费 | 否 | 偏机械 | `AVSpeechSynthesizer`，可在系统里下载更好的中文语音 |
| Edge 在线 | 免费 | 是 | 接近真人 | 微软 Edge「大声朗读」的未公开接口，无需 key，但可能随时失效 |
| 自定义接口 | 取决于服务 | 视部署 | 视模型 | 任何兼容 `POST /v1/audio/speech` 的服务，可指向本地 |

Edge 用的是未公开接口，服务端会校验 `Sec-MS-GEC` 令牌（自定义 SHA-256 + 64 位构造，每 5 分钟换一档），实现在 `NovelKit/TTS/EdgeToken.swift`，并有实测向量保证不会悄悄失效。如果哪天令牌被拒，朗读会明确报错而不是静默失败，届时换回系统朗读即可。

`TTSSettings.engine` 的默认值是 `.edge`：装完可以直接听接近真人的中文，无需任何配置；想离线或接口失效时在设置里切回系统朗读。

音频缓存按「引擎 + 音色 + 语速 + 音调 + 文本」的哈希存成 `speech/<hash>.mp3`，任一参数变化都会重新合成；缓存上限默认 300 MB，超出后按文件修改时间（即最后收听时间）淘汰最久未用的句子。

## 当前限制 / 后续

- 只在 iOS 真机上验证，没有模拟器（WSL 无 iOS Simulator），UI 未做系统化的点按回归。
- 书源仅支持文本类型；音频/图片源会按文本规则处理并提示。
- 搜索目前是并发搜全部启用书源（可在设置里改成只用第一个）。
- 书架封面走 `AsyncImage`，无本地缓存。
- 未做 iCloud 同步、导入导出备份、正则书源调试器。

## 已知行为

- `xtool dev build` 产物在 `xtool/NovelReader.app`；`xtool dev` 会安装到已连接设备并启动。
- `swift test` 在 Linux 上只编 `NovelKit` 与测试；UI 文件通过 `#if canImport(SwiftUI)` 排除。
- 抓取章节失败时阅读器会给出「重试」，重试会先删掉该章缓存再重新请求。
