#!/usr/bin/env bash
# 安装脚本共用的设备选择。
#
# 以前 pack-install.sh 和 deploy.sh 各自写死了一个 UDID（00008110-...），换台
# 手机就得改脚本，而且改漏一处就会往旧手机装。这里改成运行时发现设备：
#
#   bash pack-install.sh                          # 当前唯一连着的那台
#   UDID=00008150-xxxxxxxxxxxxxxxx bash pack-install.sh   # 指定
#   UDID=all bash pack-install.sh                 # 所有连着的设备
#
# 有多台设备却没指定时会直接报错并列清单，不会随便猜一台：装错手机时两个 App
# 的 bundle id 完全一样，光看手机屏幕分辨不出来。
#
# 用法（在别的脚本里）：
#   . "$(cd "$(dirname "$0")" && pwd)/device.sh"
#   TARGET=$(select_udid) || exit 2
set -u

DEVICE_COUNT=0
PMD3_PY="${PMD3_PY:-$HOME/.venv-pmd3/bin/pymobiledevice3}"

# usbmux 走 Windows 上 Apple 服务的转发端口，不设这个环境变量连不上。
export USBMUXD_SOCKET_ADDRESS="$(
  ip route show default | awk '{print $3; exit}'
):27015"

# 已连接的设备，每行：UDID<TAB>名称<TAB>型号<TAB>连接方式
#
# 用 pymobiledevice3 的 JSON 而不是解析 `xtool devices` 的表格文本：JSON 里字段
# 有名字，不会因为 xtool 改排版就静默匹配不到设备。
#
# 同一台手机插线又连 Wi-Fi 时会出现两条，只有 USB 那条能装机，所以按 UDID 去重
# 并优先保留 USB。
list_devices() {
  if [ ! -x "$PMD3_PY" ]; then
    echo "找不到 pymobiledevice3：$PMD3_PY" >&2
    return 1
  fi

  "$PMD3_PY" usbmux list 2>/dev/null | python3 -c '
import json, sys

try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)

best = {}
for device in devices:
    ident = device.get("UniqueDeviceID") or device.get("Identifier")
    if not ident:
        continue
    usb = device.get("ConnectionType") == "USB"
    previous = best.get(ident)
    if previous is None or (usb and not previous[0]):
        best[ident] = (usb, device)

rows = []
for ident, (usb, device) in best.items():
    rows.append((
        0 if usb else 1,
        ident,
        device.get("DeviceName") or "?",
        "{} · iOS {}".format(
            device.get("ProductType") or "?",
            device.get("ProductVersion") or "?",
        ),
        "USB" if usb else "Wi-Fi",
    ))

# USB 在前，其次按名字，让多台设备的清单稳定可读。
for _, ident, name, model, link in sorted(rows):
    print("\t".join([ident, name, model, link]))
'
}

# 挑一台设备，把 UDID 打到 stdout。
#
# 插着线的那台优先：装机和调试都走 USB，而旧手机留在 Wi-Fi 上时会一直出现在
# 列表里。如果按「总数必须是 1」来判断，一台早就该退休的 Wi-Fi 手机会让每次
# 部署都卡在选择上。只有当 USB 上不止一台，或者一台 USB 都没有时，才让用户
# 自己用 UDID 指定。
select_udid() {
  if [ -n "${UDID:-}" ]; then
    DEVICE_COUNT=1
    printf '%s\n' "$UDID"
    return 0
  fi

  local rows total usb_rows usb_count
  rows="$(list_devices)" || return 1
  total="$(printf '%s\n' "$rows" | grep -c . || true)"
  DEVICE_COUNT="$total"

  if [ "$total" -eq 0 ]; then
    echo "没有检测到已连接的 iOS 设备。" >&2
    echo "检查：数据线插好、手机上点过「信任此电脑」、Windows 的 Apple 服务在跑。" >&2
    return 1
  fi

  usb_rows="$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "USB"')"
  usb_count="$(printf '%s\n' "$usb_rows" | grep -c . || true)"

  case "$usb_count" in
    1)
      printf '%s\n' "$usb_rows" | cut -f1
      ;;
    0)
      # 没插线，只剩 Wi-Fi；只有一台时仍然可以装。
      if [ "$total" -eq 1 ]; then
        printf '%s\n' "$rows" | cut -f1
        return 0
      fi
      echo "检测到 $total 台设备，但都没有插 USB。用 UDID=<id> 指定一台：" >&2
      printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %s  %s  (%s, %s)\n", $1, $2, $3, $4 }' >&2
      return 1
      ;;
    *)
      echo "USB 上检测到 $usb_count 台设备，用 UDID=<id> 指定要装到哪一台：" >&2
      printf '%s\n' "$usb_rows" | awk -F'\t' '{ printf "  %s  %s  (%s, %s)\n", $1, $2, $3, $4 }' >&2
      return 1
      ;;
  esac
}

# 已签名 App 的真实 bundle id。
#
# 不能拿 xtool.yml 里那个：免费账号签名后 Info.plist 里的 id 会被加上团队前缀
# （XTL-4JBQYZ7D5X.com.yang.NovelReader），查已安装应用要按最终 id 查。
app_bundle_id() {
  python3 - "$1/Info.plist" <<'PY'
import plistlib, sys

try:
    with open(sys.argv[1], "rb") as handle:
        print(plistlib.load(handle).get("CFBundleIdentifier", ""))
except Exception:
    print("")
PY
}

# 这个 App 的签名 profile 是否覆盖了某台设备。
#
# 免费 Apple ID 的授权文件把设备 UDID 写死在里面。新手机没登录刷新过 profile 时，
# 装机会失败在签名阶段之前且报错很含糊，所以先在这里说清楚。
profile_covers() {
  local udid="$1"
  local app="${2:-$HOME/ios/NovelReader/xtool/NovelReader.app}"

  if [ ! -f "$app/embedded.mobileprovision" ]; then
    return 0
  fi

  python3 - "$app/embedded.mobileprovision" "$udid" <<'PY'
import plistlib, sys

path, udid = sys.argv[1], sys.argv[2]
raw = open(path, "rb").read()
start = raw.find(b"<?xml")
end = raw.rfind(b"</plist>")
if start < 0 or end < 0:
    sys.exit(0)

plist = plistlib.loads(raw[start:end + len(b"</plist>")])
devices = plist.get("ProvisionedDevices")
if devices is None:
    # 企业/个人证书不写设备列表，不做判断。
    sys.exit(0)

sys.exit(0 if udid in devices else 1)
PY
}
