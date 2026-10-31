# 夜读 · NovelReader

一个用 SwiftUI 写的 iOS 网络小说阅读器：导入「阅读 / legado」书源，搜索、加入书架、离线缓存章节，支持系统语音朗读（TTS）和 OpenAI 兼容接口的 AI 文本整理。

引擎（`NovelKit`）只依赖 Foundation，可以在 Linux 上编译和跑单测；App 层（`NovelReader`）用 `#if canImport(SwiftUI)` 包裹，因此同一个工程既能 `swift test` 也能用 [xtool](https://github.com/xtool-org/xtool) 在没有 macOS 的机器上构建 iOS App。

## 功能

- **书源**：兼容 legado 书源 JSON 的常用子集，支持搜索 / 详情 / 目录 / 正文 / 下一页。
- **书架**：最近阅读排序、阅读进度（章节 + 字符偏移）、移出书架、清缓存。
- **阅读器**：字号 / 行距 / 段距 / 边距 / 四种主题（纸白、米黄、深灰、纯黑）、目录跳转、上下章、阅读进度保存。
- **翻页**：两种模式——连续滚动，或左右滑动分页（默认）。分页用 CoreText 精确排版，滑动跟手、松手按位移或甩动速度判定翻页；跨章时显示「上一章 / 下一章」提示页。三种翻页效果：覆盖（整页跟手位移）、淡入、仿真（3D 透视 + 侧边阴影）。朗读时自动翻到正在读的那一页，并高亮当前句。
- **TTS**：按句朗读、句级高亮跟随滚动、暂停/继续、上一句/下一句、语速与音调、中文声音选择、读完自动下一章；已声明 `UIBackgroundModes: audio`，锁屏后继续播。
- **AI 整理**：OpenAI 兼容 `/chat/completions`，分块处理长章节，三种模式（清理排版 / 校对纠错 / 精简去水），可附加自定义要求；另可整理书籍简介。
- **离线可用**：内置示例书《长夜灯下》3 章 + 内置离线书源，无网络也能体验阅读、TTS、AI（AI 需自行配置 key）。
- **隐私**：AI API Key 存在系统钥匙串，不写入普通配置文件。

## 目录结构

```
NovelReader/
├── Package.swift                 SwiftPM 工程（xtool 使用单一 library product）
├── xtool.yml                     bundleID / Info.plist 位置
├── Info.plist                    显示名、后台音频、ATS、版本号
├── Sources/
│   ├── NovelKit/                 纯 Swift 引擎，可在 Linux 上编译和测试
│   │   ├── Models/               Book / BookSource / Settings / JSONValue
│   │   ├── Network/              HTTPClient（Cookie、重试、编码识别）
│   │   ├── Source/               RuleEngine / JSONPath / SourceEngine / LegadoImporter
│   │   ├── Store/                LibraryStore（文件 JSON 持久化）
│   │   ├── AI/                   AIClient + 提示词 / 分块
│   │   └── Support/              文本处理、编码识别、内置示例
│   └── NovelReader/              SwiftUI App（Linux 上被 #if canImport(SwiftUI) 跳过）
│       ├── App/                  AppModel、入口、Tab
│       ├── Design/               主题、封面、Banner、空状态
│       └── Features/             书架 / 详情 / 阅读器 / 搜索 / 书源 / 设置 / TTS
└── Tests/NovelKitTests/          规则引擎与流水线测试（45 个）
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
| 得奇小说网 | `www.deqitxt.com` | 免费全文，目录单页全量；实测《剑来》1302 章正文完整 |
| 顶点小说 23uswx | `www.23uswx.la` | 免费全文，目录单页全量；末尾若干章与站点重复书目相连 |

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

阅读器右上角 ✨ 选择整理模式，结果会覆盖当前章节缓存；再次抓取章节即可恢复原文（清缓存后重新进入章节）。

## 数据存放

App 沙盒 `Application Support/NovelReader/`：

```
books.json               书架与阅读进度
sources.json             书源配置
settings.json            阅读 / TTS / 网络 / AI 设置（不含 key）
chapters/<book>-toc.json 目录缓存
chapters/<book>-<hash>.json 章节正文缓存
```

AI Key 单独存 Keychain（service `com.yang.NovelReader`）。

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
