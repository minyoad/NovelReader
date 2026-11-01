# 装到另一台手机上

部署脚本不再写死设备 UDID，插上哪台就装哪台。

## 设备连不上时先跑这个

```bash
bash Tools/fix-device-link.sh
```

「手机插着、Windows 的 Apple 设备里也能看到，但 `xtool devices` 报 `Error: unknown` 或列表为空」时，用这一条恢复。它会把三个环节一起重做并验证。

三个必须同时成立的环节，缺一个就是上面那个现象：

| 环节 | 为什么必须有 |
| --- | --- |
| Windows 侧 portproxy `27016 → 127.0.0.1:27015` | Apple 的 usbmuxd 只绑 `127.0.0.1:27015`；WSL 是 NAT 网络（Windows 10 没有镜像网络），进不来 |
| WSL 侧 `/var/run/usbmuxd` 的 unix socket 桥接 | xtool 经 libusbmuxd 只连 unix socket，不认 `USBMUXD_SOCKET_ADDRESS` 那种 TCP 地址；而 WSL 自带的 usbmuxd 看不到 USB，必须停掉让它让位 |
| 两侧的 lockdown 配对记录 | 新手机只在 Windows 侧配对过时，WSL 缺 `00008xxx.plist`，装机卡在签名之后 |

监听端口用 **27016**，不是 27015。原因见下面「几个容易踩的点」。

## 日常用法（设备已经在账号里）

```bash
cd ~/ios/NovelReader
xtool-proxy dev build --sign          # 编译 + 签名
bash Tools/pack-install.sh            # 打包 ipa 并安装
```

`pack-install.sh` 会自己找设备：

| 情况 | 行为 |
| --- | --- |
| 只插了一台 USB | 直接装到这台 |
| 插了多台 USB | 停下并列清单，要求 `UDID=<id>` 指定 |
| 一台 USB 都没有，只有一台 Wi-Fi 上的 | 装到这一台 |
| 一台都没有 | 报错并提示检查数据线 / 信任电脑 |

USB 优先：旧手机留在 Wi-Fi 上时会一直出现在列表里，按「总数必须为 1」判断会让每次部署都被它挡住。

指定设备：

```bash
UDID=00008150-000C42C20E61401C bash Tools/pack-install.sh
```

## 换新手机：要用 `dev-run.sh`

免费 Apple ID 的授权文件把能装的设备 UDID 写死在里面，最多 3 台，7 天过期。新手机要先**注册到开发者账号**，否则 profile 里永远没有它。

**关键点：`xtool dev build --sign` 不会注册设备。** 不是配置问题，是 xtool 的结构：

```swift
// DeveloperServicesAddDeviceOperation.swift 第一行
guard let targetDevice = context.targetDevice else { return }
```

注册这一步在 `DeveloperServicesProvisioningOperation` 里排第一，但：

| 调用路径 | 是否传 `targetDevice` | 结果 |
| --- | --- | --- |
| `dev build --sign` → `signInPlace(app:)` | 否 | **跳过注册**，profile 只按账号已有设备生成 |
| `dev run` → `install(app:udid:...)` | 是 | 先注册，再签、再装 |

所以换了新手机时，**重新登录没用、重新签名也没用**——两条路都不会把新 UDID 加进账号。正确做法：

```bash
bash Tools/dev-run.sh
```

它会选设备、检查登录状态，然后跑 `xtool-proxy dev run --udid <目标> --usb`，由 xtool 内部完成注册 → 重签 → 安装。

检查当前状态：

```bash
bash Tools/verify-tools.sh     # 桥接、xtool 视角、账号注册、profile 覆盖、语法
```

## 脚本

| 文件 | 作用 |
| --- | --- |
| `Tools/device.sh` | 设备发现（`list_devices`）、选择（`select_udid`）、bundle id 读取、`profile_covers`、`device_registered` |
| `Tools/pack-install.sh` | 把已签名的 `.app` 打成 ipa 并安装（设备须已注册且 profile 已含它） |
| `Tools/deploy.sh` | 安装 xtool 暂存目录里现成的 `app.ipa` |
| `Tools/dev-run.sh` | **新设备用这个**：注册 + 签名 + 安装一条命令 |
| `Tools/login-apple.sh` | 交互式 Apple 登录（只刷新 token，不会注册设备） |
| `Tools/fix-device-link.sh` | 重建 WSL→Windows 的 usbmuxd 通道并验证 |
| `Tools/usbmux-bridge.py` | unix socket → TCP 的双向转发，由上一个脚本启动 |
| `Tools/verify-tools.sh` | 不装机的自检 |

设备枚举用 `pymobiledevice3 usbmux list` 的 JSON，不解析 `xtool devices` 的表格文本：JSON 字段有名字，xtool 改排版也不会静默匹配不到设备。安装本身用 xtool 自带的 `xtool install --udid`。

## 几个容易踩的点

- **`--usb` 不能省**。`xtool devices` / `dev run` 默认 `--all`，会同时枚举 USB 和 Network 设备。Network 那条是 Bonjour 发现的对等连接，响应里带 `NetworkAddress` 和 IPv6 链路本地地址，WSL 的 NAT 到不了，xtool 处理到该条目时抛一个不带任何信息的 `Error: unknown`，整条命令失败——哪怕 USB 那台是好的。表现极具误导性：`xtool devices --usb` 正常，不加参数就报错。
- **27015 不能直接转发**。`netsh portproxy` 把 `0.0.0.0:27015` 转到 `127.0.0.1:27015` 会把回环地址一起占掉，Apple 的 usbmuxd 绑不上 27015，只能退到随机端口，整条通道静默失效。残留证据是 27015 上堆着上万条 TIME_WAIT，而 `AppleMobileDeviceProcess` 不监听任何 TCP 端口。监听端口必须错开（这里用 27016）。这个故障重启电脑能暂时绕过，但规则还在，下次 Apple 服务重启就会复发。
- **WSL 自带的 usbmuxd 必须让位**。它占着 `/var/run/usbmuxd`，但看不到任何 USB 设备。不停掉它，桥接就起不来。
- **`USBMUXD_SOCKET_ADDRESS` 对 xtool 无效**。那是 `pymobiledevice3` 的约定；xtool 经 libusbmuxd 只连 unix socket。所以脚本里 `device.sh` 设了它给 pymobiledevice3 用，而 xtool 走的是桥接。
- **四个概念要分清**：链路通不通（`fix-device-link.sh`）、`device_registered`（在账号里）、`profile_covers`（在授权文件里）、以及 App 有没有签名。未注册时重新登录和重新签名都没用，必须走 `dev-run.sh`。
- `profile_covers` 是**三态**：0 覆盖、1 不覆盖、2 无法判定（文件不存在或证书不写设备列表）。无法判定按未通过处理——把「不知道」当「可以装」会让错误出现在装机中途，更难查。注意 `dev run` 完成后产物目录里没有 `embedded.mobileprovision`（签名在设备侧完成），所以此时必然是「无法判定」，这不代表出错；要判断是否装成，直接查设备上的 App。
- 签名后 Info.plist 里的 bundle id 会多一个团队前缀（`XTL-4JBQYZ7D5X.com.yang.NovelReader`），拿 `xtool.yml` 里的原值查已安装应用会查不到。`app_bundle_id` 从产物里读。
- `xtool` 没有 `query` 子命令，查已安装版本仍要用 `pymobiledevice3 apps query`。
- `xtool ds devices` 只有 `list`，没有 register 子命令；注册只能经由 `dev run` 的安装路径。
