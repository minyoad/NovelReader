# 第一阶段：基础 JavaScript 书源规则

## 已实现

- `@js:代码`：其后的全部内容视为 JS；最后一个表达式的值作为结果，也支持显式 `return`。
- `<js>代码</js>`：可以接在 CSS / XPath / JSONPath 提取之后，也支持多个脚本块串联。
- 标准字符串、正则、数字、布尔、数组、对象与 JSON 操作；数组可作为搜索结果、目录等列表的节点，后续使用普通 JSONPath 或基础 JS 提取字段。
- 搜索地址脚本、搜索与发现结果列表/字段、详情字段、目录及章节字段、正文转换和翻页链接等已进入规则引擎的位置。
- 脚本先替换为不透明标记，再解析规则的 `@@`、`||`、`&&` 和 `##`，脚本内部的这些运算符或字面文本不会被拆开。
- `undefined` / `null` 表示无结果；异常、缺失宿主接口、循环超时等产生明确提示，并允许规则外的回退分支继续执行。正文 JS 失败不会悄悄返回未经转换的原文。
- 同一次响应解析中，已超时的同一脚本不再对每个列表项重复执行。

旧式 `@js<` 标记尚未实现，请改写为上述两种明确标记。

## 上下文

| 变量 | 含义 |
| --- | --- |
| `result` | 前一步结果；没有提取前缀时，HTTP 根节点提供原始响应文本，已选中的 JSON 节点提供 JSON 值，HTML 列表节点提供其 HTML 字符串 |
| `baseUrl` / `baseURL` / `url` | 当前响应地址；搜索地址脚本中为书源站点地址 |
| `key` | 当前搜索词，或所在阶段传入的书名；缺省为空字符串 |
| `page` | 数值页码；目录/正文多页请求也提供当前页，缺省为 1 |
| `variables` | 原始变量字典，值为字符串 |

变量以 JSON 数据注入，不拼接到可执行代码中。脚本内直接使用 `key`、`page` 等变量；不会把 `{{key}}` 文本替换进脚本。声明式规则仍支持原来的占位符替换。

每次执行创建独立上下文。多个脚本块可传递 `result`，但不共享局部变量；不同字段、请求和书源之间没有全局状态。

## 示例

正文去掉特定文本：

```text
#content@text<js>result.replace(/广告内容/g, '').trim()</js>
```

拼接搜索地址：

```text
@js:baseUrl + '/search?q=' + encodeURIComponent(key) + '&page=' + page
```

JSON 响应生成目录列表：

```text
@js:JSON.parse(result).chapters
```

若列表项为 `{ "name": "第一章", "url": "/read/1" }`，章节名使用 `$.name`，章节链接使用 `$.url`；也可使用 `@js:result.name`。

脚本之外继续正则替换或回退：

```text
#content@text<js>result.trim()</js>##广告##
<js>''</js>||#content@text
```

`@js:` 会消耗余下全部规则；需要在 JS 后面继续书源操作时，应使用成对的 `<js>…</js>`。

## 执行器与限制

内置 MIT 许可的 QuickJS-ng v0.11.0，固定于提交 `6a9fe9af5ca0bf7c49ae697edef44864272317d1`，源码和许可证保存在 `Sources/CNovelJavaScript/vendor/`。

没有使用 JavaScriptCore 的私有中断接口，也没有把超时解释成「让一个死循环留在后台继续运行」。每次调用有默认 250 ms 中断预算、24 MiB 解释器内存上限、512 KiB 栈上限、256 KiB 脚本和 4 MiB 输入/输出上限。超时或资源错误后销毁运行时；阻塞的 `Atomics.wait` 被禁用。

规则由网络解析流水线调用。`RuleEngine` 仍是同步 API，不应在界面主线程主动执行外部脚本；书源列表的能力分析不会运行脚本。

这一阶段没有提供：

- legado 的 `java.*`、Java / Android 类、`org.jsoup` 或 DOM 对象桥接。
- `fetch`、网络连接、Cookie、文件、跨请求变量存储或原生对象。
- `book`、`source` 等宿主对象、`jsLib` 共享库、登录流程、脚本请求头与动态发现分类脚本。
- Promise / 异步规则调度；返回 Promise 会明确报错。QuickJS 不是浏览器，也不是 Node.js。

能力标记区分「支持基础 JS」和「依赖未实现能力」；静态提示不能证明任意脚本一定成功，仍需实际试读或检测。

## 验证

- 临时安装 Swift 6.0.3，在 Linux 实际编译 C 运行时与 NovelKit，并运行测试。
- JS 定向测试覆盖转换、分隔符保护、字符串/模板/注释、数组/对象、单元素数组串联、上下文隔离、并发、显式返回、异常回退、超时、内存与栈限制、禁用阻塞等待及能力提示。
- 回归：`swift test --skip TextDecodingTests`，71 个 XCTest + 334 个 Swift Testing 测试通过，共 405 项。
- 全量运行中的 GBK 相关 8 个既有测试失败（16 条断言），已在未修改的基线 `1afc931` 独立复现。排除的是整个 TextDecodingTests 组（12 项），没有改动编码实现或删改这些测试。
- C 层经过 ASan / UBSan 检查，覆盖循环中断、异常对象转字符串、JSON 序列化、内存上限及失败后的再次执行；当前环境的 ptrace 限制使 LeakSanitizer 无法运行，检查时关闭了泄漏检测。
- `git diff --check` 通过。Linux 不会类型检查 SwiftUI / UIKit 分支，iOS 构建和真机书源验证仍待执行。
