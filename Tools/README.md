# 装到另一台手机上

部署脚本不再写死设备 UDID，插上哪台就装哪台。

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

它会选设备、检查登录状态，然后跑 `xtool-proxy dev run --udid <目标>`，由 xtool 内部完成注册 → 重签 → 安装。

检查当前状态：

```bash
bash Tools/verify-tools.sh     # 设备、账号注册、profile 覆盖、语法
```

## 脚本

| 文件 | 作用 |
| --- | --- |
| `Tools/device.sh` | 设备发现（`list_devices`）、选择（`select_udid`）、bundle id 读取、`profile_covers`、`device_registered` |
| `Tools/pack-install.sh` | 把已签名的 `.app` 打成 ipa 并安装（设备须已注册且 profile 已含它） |
| `Tools/deploy.sh` | 安装 xtool 暂存目录里现成的 `app.ipa` |
| `Tools/dev-run.sh` | **新设备用这个**：注册 + 签名 + 安装一条命令 |
| `Tools/login-apple.sh` | 交互式 Apple 登录（只刷新 token，不会注册设备） |
| `Tools/verify-tools.sh` | 不装机的自检 |

设备枚举用 `pymobiledevice3 usbmux list` 的 JSON，不解析 `xtool devices` 的表格文本：JSON 字段有名字，xtool 改排版也不会静默匹配不到设备。安装本身用 xtool 自带的 `xtool install --udid`。

## 几个容易踩的点

- **三个概念要分清**：`device_registered`（在账号里）、`profile_covers`（在授权文件里）、以及 App 有没有签名。未注册时前两者都已注册不了，必须走 `dev-run.sh`。
- `profile_covers` 是**三态**：0 覆盖、1 不覆盖、2 无法判定（文件不存在或证书不写设备列表）。无法判定按未通过处理——把「不知道」当「可以装」会让错误出现在装机中途，更难查。
- 签名后 Info.plist 里的 bundle id 会多一个团队前缀（`XTL-4JBQYZ7D5X.com.yang.NovelReader`），拿 `xtool.yml` 里的原值查已安装应用会查不到。`app_bundle_id` 从产物里读。
- `xtool` 没有 `query` 子命令，查已安装版本仍要用 `pymobiledevice3 apps query`。
- `xtool ds devices` 只有 `list`，没有 register 子命令；注册只能经由 `dev run` 的安装路径。
