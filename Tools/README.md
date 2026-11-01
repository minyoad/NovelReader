# 装到另一台手机上

部署脚本不再写死设备 UDID，插上哪台就装哪台。

## 日常用法

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

## 换新手机：必须先刷新签名授权

**免费 Apple ID 的授权文件把能装的设备 UDID 写死在里面**，最多 3 台，7 天过期。新手机没被加进去时，安装一定失败，而且报错信息看不出原因。

`pack-install.sh` 会在打包前读 `xtool/NovelReader.app/embedded.mobileprovision`，发现目标设备不在列表里就直接停下（退出码 3），并指路：

```bash
bash Tools/login-apple.sh      # 重新登录，xtool 刷新 profile 时带上当前设备
```

登录后重新签名，授权文件就会包含新设备。检查当前覆盖了哪些设备：

```bash
# 装机前的完整自检：设备发现、选择、授权覆盖、语法
bash Tools/verify-tools.sh
```

## 脚本

| 文件 | 作用 |
| --- | --- |
| `Tools/device.sh` | 共享的设备发现（`list_devices`）、选择（`select_udid`）、bundle id 读取、授权覆盖检查 |
| `Tools/pack-install.sh` | 把已签名的 `.app` 打成 ipa 并安装 |
| `Tools/deploy.sh` | 安装 xtool 暂存目录里现成的 `app.ipa` |
| `Tools/login-apple.sh` | 交互式 Apple 登录，刷新签名授权 |
| `Tools/verify-tools.sh` | 不装机的自检 |

设备枚举用 `pymobiledevice3 usbmux list` 的 JSON，不解析 `xtool devices` 的表格文本：JSON 字段有名字，xtool 改排版也不会静默匹配不到设备。安装本身用 xtool 自带的 `xtool install --udid`。

## 两个容易踩的点

- 签名后 Info.plist 里的 bundle id 会多一个团队前缀（`XTL-4JBQYZ7D5X.com.yang.NovelReader`），拿 `xtool.yml` 里的原值查已安装应用会查不到。`app_bundle_id` 从产物里读。
- `xtool` 没有 `query` 子命令，查已安装版本仍要用 `pymobiledevice3 apps query`。
