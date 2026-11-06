# 夜读 · NovelReader

一个用 SwiftUI 写的 iOS 网络小说阅读器：导入「阅读 / legado」书源，搜索、加入书架、离线缓存章节，支持多种语音朗读引擎（TTS）和 OpenAI 兼容接口的 AI 文本整理。

引擎（`NovelKit`）只依赖 Foundation，可以在 Linux 上编译和跑单测；App 层（`NovelReader`）用 `#if canImport(SwiftUI)` 包裹，因此同一个工程既能 `swift test` 也能用 [xtool](https://github.com/xtool-org/xtool) 在没有 macOS 的机器上构建 iOS App。

## 功能

- **书源**：兼容 legado 书源 JSON 的常用子集，支持搜索 / 详情 / 目录 / 正文 / 下一页。
- **书架**：最近阅读排序、阅读进度（章节 + 字符偏移）、移出书架、清缓存。
- **阅读器**：字号 / 行距 / 段距 / 边距 / 四种主题（纸白、米黄、深灰、纯黑）、目录跳转、上下章、阅读进度保存；章节标题在顶栏（点开即目录），启动时可自动回到上次读到的位置。
- **翻页**：两种模式——连续滚动，或左右滑动分页（默认）。分页用 CoreText 精确排版，滑动跟手、松手按位移或甩动速度判定翻页；跨章时显示「上一章 / 下一章」提示页。三种翻页效果：覆盖（整页跟手位移）、淡入、仿真（从**右上角**掀起去翻下一页，**左上角**掀起退回上一页：斜折痕，折痕旁一条卷曲带显示绕折痕镜像的纸背，更远处露出下一页，带子随进度张开再收拢，左右两个方向互为镜像）。朗读时自动翻到正在读的那一页，并高亮当前句。
- **排版**：字号 / 行距 / 段距 / 边距、首行缩进两字、两端对齐；字体可选系统衬线、系统无衬线、苹方、宋体、楷体、圆体。缩进用段落样式实现而不改写文本，字符偏移不变，阅读进度不会错位。
- **全屏阅读**：正文页只留一行章节标题在顶部，其余控件（目录、换源、AI、缓存、设置、朗读栏）点击屏幕才出现，再点一次收回；状态栏一并隐藏。退出朗读、启动 App 都直接回到这个全屏状态。
- **换源**：阅读器顶栏和书目详情页都能打开候选书源列表，每个候选可先「试读这一章」，确认能取到正文再切换；切过去后按章节标题保留阅读进度。
- **离线缓存**：阅读时后台预缓存接下来 N 章（默认 5，可设 0 关闭），断网也能继续往下读；支持「缓存全本」带进度、每本缓存上限（超出后优先清理离阅读位置最远的章节）、按本清理与占用统计；加入书架时可选择自动缓存全本。
- **TTS**：三种引擎——系统朗读（离线）、微软 Edge 在线朗读（免费、无需注册，音色接近真人）、自定义 OpenAI 兼容 `/audio/speech`（可指向本地部署的模型）。按整句分组请求，服务端返回的句级时间戳用来驱动高亮；暂停/继续、语速与音调、读完自动下一章；句间跳转在控制中心/锁屏快进快退，朗读中也能从底栏直接进「朗读设置」换音色。音频按句缓存，重复收听不联网，超出上限后按最久未听淘汰。已声明 `UIBackgroundModes: audio`，锁屏后继续播。
- **后台与系统播放**：锁屏、控制中心、CarPlay 和蓝牙耳机都能控制朗读。三行信息依次是书名、作者、正在读的那一句，另有封面和进度条（按字数估算，随语速缩放）。耳机单击播放/暂停、双击下一章、三击上一章；控制中心的上一首/下一首切章，快进/快退切句，拖动进度条跳到大致位置。换章时保留音频会话并申请一小段后台额度，锁屏状态下也能取回下一章。来电等打断会自动暂停，系统允许时再续播；拔掉耳机会立刻暂停，避免外放。
- **AI 整理**：OpenAI 兼容 `/chat/completions`，分块处理长章节，三种模式（清理排版 / 校对纠错 / 精简去水），可附加自定义要求；输出格式可选按段换行 / 保留原换行 / 整段连排 / 段间空行，整理前的原文会保留，可一键还原；另可整理书籍简介。可选「自动去广告」：每章读到时先让模型删掉广告代码、无关废话和章末附加的话语，正文其余部分不动。
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
│   │   ├── TTS/                  EdgeToken / EdgeTTSClient / OpenAISpeechClient / SpeechTimeline
│   │   └── Support/              文本处理、编码识别、分句分块、内置示例
│   └── NovelReader/              SwiftUI App（Linux 上被 #if canImport(SwiftUI) 跳过）
│       ├── App/                  AppModel、入口、Tab
│       ├── Design/               主题、封面、Banner、空状态
│       └── Features/             书架 / 详情 / 阅读器 / 搜索 / 书源 / 设置 / TTS
└── Tests/NovelKitTests/          规则引擎与流水线测试（85 个）
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

SwiftPM 会读 `http_proxy` / `https_proxy`，首次拉 SwiftSoup 前先设好代理即可。注意 xtool 自身**不读**这两个变量，它在 `xtool sdk install` 阶段要单独能联网（见下）。

> 真机安装需要 Apple 账号签名，先跑 `xtool setup` 完成登录。

### 在这台机器上配置 xtool 环境（WSL2 / Ubuntu 24.04）

已配置完成，记录关键点以便复现或换机：

| 组件 | 版本 / 位置 |
| --- | --- |
| Swift | 6.4.1，由 swiftly 管理，`~/.local/share/swiftly/toolchains/6.4.1` |
| xtool | 1.24.0，`/usr/local/bin/xtool` |
| Darwin SDK | Xcode 27.1，`~/.swiftpm/swift-sdks/darwin.artifactbundle`（`swift sdk list` 显示 `darwin`） |
| usbmuxd / ideviceinfo | 已装（真机连接用） |

WSL 是 **mirrored 网络模式**，两个坑：

1. **DNS**：WSL 自带的 DNS 隧道（`10.255.255.254`）不可用，只有本地网关 `192.168.53.1` 能解析。
   已在 `/etc/wsl.conf` 里关掉 `generateResolvConf`，并把 `/etc/resolv.conf` 固定为
   `nameserver 192.168.53.1` / `192.168.53.157`。换网络后要改成新的网关 IP。
2. **代理**：Windows 侧代理（`127.0.0.1:10809`）在 mirrored 模式下 WSL 可直接访问，
   `autoProxy=true` 会把 Windows 系统代理注入成环境变量。

`xtool sdk install` 需要从 GitHub 拉 `toolset` 和 `OpenAppleMacros` 两个 tarball，走代理极慢且会卡住。
绕过办法是先在 Windows 侧直连下载（直连比走代理快得多），再用环境变量指向本地文件：

```bash
# Windows（直连，约 20 秒）
curl -fL -o toolset-x86_64.tar.gz \
  https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.1.0/toolset-x86_64.tar.gz
curl -fL -o OpenAppleMacrosServer-x86_64.tar.gz \
  https://github.com/xtool-org/OpenAppleMacros/releases/download/v1.4.1/OpenAppleMacrosServer-x86_64.tar.gz

# WSL
export XTL_TOOLSET_TARBALL=/mnt/e/.../toolset-x86_64.tar.gz
export XTL_OAM_TARBALL=/mnt/e/.../OpenAppleMacrosServer-x86_64.tar.gz
xtool sdk install ~/xcode/Xcode.xip
```

> 解压 2GB 的 XIP 要几分钟，**中途别打断**——被中断会留下残缺的 `Xcode.app`，
> 之后构建会报 `unable to find platform for 'iphoneos'`（因为缺 `SDKSettings.json`），
> 这时只能删掉 `~/.swiftpm/swift-sdks/darwin.artifactbundle*` 重跑。
> 建议用 `Start-Process wsl.exe ...` 从 Windows 侧起一个独立进程，避免 shell 超时把安装杀掉。

### 真机连接

**首选：中转 Windows 的 usbmuxd**（快，一条命令）

```bash
bash Tools/connect-iphone.sh
```

它做的事：确认 Windows 侧的 `127.0.0.1:27015` 可达 → 断开 usbip → 停掉 WSL 自带的
usbmuxd → 在 `/var/run/usbmuxd` 上架桥转发到 Windows → 验证设备。

前提是 Windows 装了 Apple Mobile Device Support（`Apple Devices` 或 iTunes 都带）：

```powershell
winget install --id Apple.AppleMobileDeviceSupport --exact
Get-Service "Apple Mobile Device Service"      # 应显示 Running
```

**为什么不走 usbip**：usbip 要把 USB 整个搬进 WSL，数据经过 vhci 虚拟总线再被
WSL 自己的 usbmuxd 解包一遍，装 13MB 的 ipa 要十几分钟，而且跑到最后
`[Connecting] 100%` 时容易超时。中转方式只转发 usbmuxd 协议本身，`xtool devices`
从 10 秒级降到 300ms 以内。

之所以能直连 `127.0.0.1:27015`，是因为这台机器的 WSL 是 **mirrored 网络模式**，
Windows 的监听端口在 WSL 里同样位于回环地址。NAT 模式则需要一条
`netsh interface portproxy`，见 `Tools/fix-device-link.sh` 里的说明。

插好手机后：

```bash
xtool devices --usb          # 应列出 "My iPhone 17 [usb]: <UDID>"
xtool dev --usb              # 构建 + 安装 + 启动
```

> `xtool devices` 默认走 `--all`，会去枚举 Network 设备，那条链路在 WSL 里到不了，
> 抛一个不带信息的 `Error: unknown`。**显式加 `--usb`**。

#### 备选：usbipd 直通

如果 Windows 上不想装 Apple 的软件，也可以用 **usbipd-win** 把 USB 转进 WSL。
能编译能装，就是慢。

```powershell
# Windows（管理员）：绑一次就够，之后一直记着
usbipd bind --busid 3-6
```

```bash
# WSL：每次重新插拔后都要跑
sudo modprobe vhci-hcd                       # WSL 内核自带，但这步不能省
sudo usbip attach -r 127.0.0.1 -b 3-6
sudo systemctl start usbmuxd
idevice_id -l                                # 应输出设备 UDID
```

几个坑：

- **`usbipd attach --wsl` 用不了**。它读的是管理员账户的 `HKCU`，而这个 Ubuntu 是用户级安装，
  管理员上下文里看不到，会报 `There are no WSL distributions installed`。
  所以只做 `bind`，attach 交给 WSL 侧的 `usbip` 主动连 `127.0.0.1:3240`。
- **Ubuntu 24.04 没有独立的 `usbip` 包**，装在 `linux-tools-generic` 里。
  `apt` 装完后 `/usr/bin/usbip` 是个包装脚本，会因为内核版本（6.18）对不上 6.8 的工具目录而报
  `usbip not found for kernel`。直接指向真实二进制即可：

  ```bash
  sudo ln -sf /usr/lib/linux-tools/6.8.0-147-generic/usbip /usr/local/bin/usbip
  ```
- **`vhci_hcd` 加载失败是静默的**。`sudo` 没拿到密码时 `modprobe` 直接失败但不报错，
  之后 `usbip attach` 会报 `open vhci_driver (is vhci_hcd loaded?)`。
  跑完 `ls /sys/devices/platform/vhci_hcd*` 确认一下。
- **attach 会掉**。手机锁屏休眠、拔插一次都会断，`vhci` 端口回到空闲（`sta 004`）。
  报 `usbip: Device not found` 说明是 Windows 侧设备不在了，重插手机再 `usbipd bind`。
- 跑中转方式前**必须先 detach**，两条路同时开会抢设备。


> `xtool devices` 默认走 `--all`，会去枚举 Network 设备，那条链路在 WSL 里到不了，
> 抛一个不带信息的 `Error: unknown`。**显式加 `--usb`**。

首次装机可能会要求吊销一张已有的 `Apple Development` 证书（免费帐号每个 Team 只允许有限张）。
提示是 `Continue? (yes/no):`，**要输入完整的 `yes`**，输 `y` 会被当作取消。
而且它只在 pty 上提问，管道里塞 `yes y` 不会被读到，得走 `script`：

```bash
( sleep 60; echo yes ) | script -q -c "xtool dev --usb" /dev/null
```

#### 不要让 xtool 吊销证书

xtool 有时会要求吊销一张早先的 `Apple Development` 证书（比如显示名是别的名字）。
**先别答应**——那张证书很可能就是你自己另一台电脑装的，吊销会让那台机器上的 App 立刻失效。

判断方法：`xtool ds certificates list` 看那张证书的 `common name` / `team id`
是不是你这个 Apple ID 和 Team。如果是同一 Team，本地 `~/.config/xtool/data/<TEAMID>`
里通常已经存着配对的私钥和证书，可以验证：

```bash
python3 - <<'PY'
import plistlib, os, subprocess, tempfile
d = plistlib.load(open(os.path.expanduser("~/.config/xtool/data/4JBQYZ7D5X"), "rb"))
k = tempfile.mktemp(suffix=".pem"); open(k, "wb").write(d["privateKey"]["data"])
c = tempfile.mktemp(suffix=".der")
cert = d["certificate"]
open(c, "wb").write(cert.encode("latin-1") if isinstance(cert, str) else cert)
priv = subprocess.run(["openssl","rsa","-in",k,"-pubout"],capture_output=True,text=True).stdout
pub  = subprocess.run(["openssl","x509","-inform","DER","-in",c,"-noout","-pubkey"],capture_output=True,text=True).stdout
print("配对:", priv.strip() == pub.strip())
PY
```

如果配对成功、`xtool ds profiles list` 里也有状态 `ACTIVE` 且包含当前设备的描述文件，
那就**不需要吊销**：xtool 之前某次运行已经把签名好的 ipa 留在
`~/.cache/xtool/pid-*/dir-staging-*/staging/app.ipa`，直接装它就行：

```bash
xtool install --usb ~/.cache/xtool/pid-*/dir-staging-*/staging/app.ipa
```

（`xtool install` 报 `LockdownClient.Error.muxError` 时先 `sudo systemctl restart usbmuxd`。）

描述文件 7 天后过期，到期后还是得让 xtool 重新签 — 那时它会复用已有的证书，
前提是**别删掉 `~/.config/xtool/data/<TEAMID>`**。

### bundleID 要写全，否则手机上会出现两个 App

`xtool.yml` 里的 `bundleID` 必须写成**最终的完整值**，包括 xtool 自己加的 `XTL-<TEAMID>` 前缀：

```yaml
bundleID: XTL-4JBQYZ7D5X.com.yang.NovelReader
```

只写 `com.yang.NovelReader` 时，xtool 会去 Apple 后台找一个叫 `XTL-4JBQYZ7D5X.com.yang.NovelReader`
的 App ID。如果那个 ID 已经存在（比如别的电脑先用过），它不会复用，而是**再套一层前缀**
建一个 `XTL-4JBQYZ7D5X.XTL-4JBQYZ7D5X.com.yang.NovelReader`。两个 bundle ID 在 iOS 眼里是两个 App，
手机上就会并排出现两个同名图标，书架和阅读进度互不相通。

确认当前解析出的 ID：

```bash
xtool dev build
python3 -c "import plistlib;print(plistlib.load(open('xtool/NovelReader.app/Info.plist','rb'))['CFBundleIdentifier'])"
```

卸载多出来的那个：

```bash
ideviceinstaller -U XTL-4JBQYZ7D5X.XTL-4JBQYZ7D5X.com.yang.NovelReader
```

> `xtool ds identifiers` 只有 `list`，没有删除。多出来的 App ID 和它的描述文件要去
> Apple 开发者后台手动删，留着不影响构建。

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

### 自动去广告

`设置 → AI 整理 → 自动去广告`（默认关闭，需要先启用 AI 并填好接口）。打开后，读到一章时会把三类内容删掉：

1. 广告代码与广告文字（网址、群号、公众号、下载 App、站点的推广语等）；
2. 与剧情无关的废话（公告、求票求推荐、更新说明、作者的话等）；
3. 章节末尾附加的无关话语。

#### 为什么翻页不用等

AI 接口一次要几秒，如果翻到下一章时才调用，每一章都要卡住。所以做成**提前处理**：

- 读到第 N 章时，后台按顺序把第 N+1 到 N+3 章**下载并清洗好**，写进章节缓存；
- 翻页时直接读缓存，等待时间就等于普通下载；
- 设置里的「提前处理 X 章」控制窗口大小（默认 3，0 表示关闭提前处理）。

也就是说，费用花在你读当前这一章的那几分钟里，而不是花在翻页的那一下。窗口默认 3 章，读得慢的话用不完，读得快的话翻页时可能还没洗完，此时那一章会先显示原文，后台洗完后再覆盖缓存。

#### 只检查开头和结尾

发出去的**不是整章**，而是开头约 600 字和结尾约 600 字，中间用 `==========` 隔开。广告和站点附加的话语集中在这两端，中间是正文，没必要读，也没必要冒险改。短于 1400 字的章节才整章发送。

首尾两段在模型返回后按原顺序与**未被发送的中间部分**拼回，中间部分一个字都不会经过模型。若首尾都被判定为垃圾、模型返回空，则保留原文。

#### 其它配套规则

- 提示词只允许**整行或整段**删除，避免在保留的句子里删掉半句话、连人物名字一起删掉；拿不准就保留。
- 已经清理过的章节（`ChapterContent.cleaned`）和占位内容（「内容正在获取中」）不会再次发送。
- 单章清洗失败不提示、不影响阅读：只是这一章仍是原文，下次翻到时再试。
- 朗读时例外：朗读从拿到的文本开始，所以**开启朗读的那一章会同步清洗**，否则会把广告念出来。
- 想退出时在设置里关掉即可，已清洗的章节可用 ✨ 菜单「还原为站点原文」恢复。


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
aiAutoClean              每章自动去广告（默认 false）
aiCleanAhead             提前下载并清洗后面的几章（默认 3，0 = 关闭）
tts.engine               朗读引擎：system / edge / openAICompatible
tts.remote               远端引擎参数（Edge 音色、自定义接口地址与音色）
tts.cacheEnabled / tts.cacheLimitMB  朗读音频缓存开关与上限（0 = 不限）
tts.proxy                朗读专用的 HTTP 代理（host:port，留空直连）
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

### 网络不通怎么办

微软有两个朗读地址，代码会依次尝试：`speech.platform.bing.com`（旧）和 `api.msedgeservices.com`（迁移后的新地址）。成功过的那个会记在内存里，后续优先使用，避免每一句都先撞一次失败握手。

正常直连时这两个地址都能通，**一般不需要任何设置**。实测中 `TLS error`（`URLError.notSecureConnection`，原文 "A TLS error caused the secure connection to fail"）是**手机系统里开着的代理 / VPN 拦截了握手**导致的——关掉它就好了，这种情况下在 App 里再填代理只会更糟。

排查顺序：

1. 先关掉手机系统设置里的代理 / VPN，重新试听。
2. 没有系统代理但仍失败时，打开设置里同一页的「朗读网络诊断」：它分项列出每个地址的 HTTPS 可达性和真实朗读握手。HTTPS 绿、朗读红 = 协议被拒；两个都红 = 网络到该域名不通。
3. 只有在网络确实屏蔽微软语音域名、而你又有可用 HTTP 代理时，才在「网络」一节填 `host:port`（省略端口按 7890）。**只有朗读走代理，抓书源仍然直连**。
4. 以上都不行，切回「系统朗读」，它完全离线。

音频缓存按「引擎 + 音色 + 语速 + 音调 + 文本」的哈希存成 `speech/<hash>.mp3`，任一参数变化都会重新合成；缓存上限默认 300 MB，超出后按文件修改时间（即最后收听时间）淘汰最久未用的句子。

`TTSSettings.engine` 的默认值是 `.edge`：装完可以直接听接近真人的中文，无需任何配置；想离线或接口失效时在设置里切回系统朗读。

### 后台与系统播放

朗读会把自己登记到系统的 Now Playing 里（`NowPlayingCenter.swift`），于是锁屏、控制中心、CarPlay 以及蓝牙耳机都能看到并控制它：

| 系统控件 | 作用 |
| --- | --- |
| 单击耳机按键 / 播放暂停 | 播放、暂停（暂停状态再按继续） |
| 双击耳机 / 上一首下一首 | 下一章、上一章（音量键位的双击是系统行为，按耳机型号略有差异） |
| 快进 / 快退 | 下一句、上一句 |
| 拖动进度条 | 跳到大致位置（按字数比例，再落到最接近的那一句） |

信息三行：书名、作者、正在读的那一句；句子只出现在系统播放组件里，阅读界面靠正文高亮表示进度。

只在朗读进行中响应切章：没在朗读时按耳机上的下一首不会把阅读器跳到别处。

关于后台连续性有两处刻意的处理：

- **换章时保留音频会话**。音频在后台是靠「正在播放」这一事实维持的；换章那一段是静音的（下载、断句、合成），如果这时把会话关掉，iOS 会立刻挂起 App，下一章就永远取不回来。所以换章路径用 `stop(keepingSession:)`。
- **换章时申请一小段后台额度**（`BackgroundGrace.swift`）。会话只在真正出声时才有效，下载这一小段仍然需要额外的时间预算；一旦开始播放就立刻归还。

另外：来电或其它 App 抢占音频会话时自动暂停，系统说可以续播时再继续；拔掉耳机（路由变为「旧设备不可用」）立刻暂停，避免突然外放。

进度条的长度是按字数估算的（默认 5 字/秒，随语速缩放）。章节是一段段合成的，本来就没有单一的真实时长；估算保证了拖动条比例正确，具体位置再靠上一句/下一句微调。

## 当前限制 / 后续

- 只在 iOS 真机上验证，没有模拟器（WSL 无 iOS Simulator），UI 未做系统化的点按回归。
- 书源仅支持文本类型；音频/图片源会按文本规则处理并提示。
- 搜索目前是并发搜全部启用书源（可在设置里改成只用第一个）。
- 书架封面走 `AsyncImage`，无本地缓存。
- 未做 iCloud 同步、导入导出备份、正则书源调试器。
- 代理只支持 HTTP，且只对朗读生效；SOCKS 会提示地址无法识别。

## 已知行为

- `xtool dev build` 产物在 `xtool/NovelReader.app`；`xtool dev` 会安装到已连接设备并启动。
- `swift test` 在 Linux 上只编 `NovelKit` 与测试；UI 文件通过 `#if canImport(SwiftUI)` 排除。
- 抓取章节失败时阅读器会给出「重试」，重试会先删掉该章缓存再重新请求。
