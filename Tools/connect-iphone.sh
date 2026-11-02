#!/usr/bin/env bash
# 一键把 WSL 连到 iPhone（中转 Windows 的 Apple Mobile Device Service）。
#
# 为什么走中转而不是 usbip：
#
# - usbip 把 USB 整个搬进 WSL，要经过 vhci 虚拟总线 + WSL 自己的 usbmuxd，
#   传输 ipa 时数据被复制好几遍，13MB 装十几分钟。
# - Windows 装了 Apple Mobile Device Support 之后，它自己的 usbmuxd 就常驻在
#   127.0.0.1:27015。WSL 是 mirrored 网络模式，这个端口在 WSL 里直接可达，
#   所以只要在 /var/run/usbmuxd 上架个转发，xtool 就能一路直达手机。
#
# 前提：Windows 侧装过 Apple Mobile Device Support（Apple Devices 或 iTunes 会带）。
#
# 用法：bash Tools/connect-iphone.sh
set -u

BRIDGE_LOG=/tmp/usbmux-bridge.log
TARGET_HOST=127.0.0.1
TARGET_PORT=27015
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '%s\n' "$*"; }
die() { printf '失败：%s\n' "$*" >&2; exit 1; }

say "=== 1. Windows 侧 usbmuxd 是否在监听 $TARGET_PORT ==="
if ! timeout 5 bash -c "echo > /dev/tcp/$TARGET_HOST/$TARGET_PORT" 2>/dev/null; then
  say "  $TARGET_HOST:$TARGET_PORT 不通"
  say ""
  say "  需要先在 Windows 装 Apple Mobile Device Support："
  say "    winget install --id Apple.AppleMobileDeviceSupport --exact"
  say "  装完确认服务在跑："
  say "    Get-Service 'Apple Mobile Device Service'"
  die "Windows 侧 usbmuxd 没起来"
fi
say "  $TARGET_HOST:$TARGET_PORT 可达"

say ""
say "=== 2. 断开 usbip（两条路同时开会抢设备）==="
if [ -d /sys/devices/platform/vhci_hcd.0 ]; then
  for p in 0 1 2 3 4 5 6 7; do sudo usbip detach -p "$p" 2>/dev/null; done
  say "  已断开 vhci 端口"
else
  say "  vhci 未加载，跳过"
fi

say ""
say "=== 3. 停掉 WSL 自带的 usbmuxd ==="
# 它看不到 USB，但会占着 /var/run/usbmuxd 这个 socket，桥接就绑不上。
if systemctl is-active --quiet usbmuxd 2>/dev/null; then
  sudo systemctl stop usbmuxd && say "  已停止" || die "停不掉 usbmuxd（需要 sudo）"
else
  say "  未运行"
fi

say ""
say "=== 4. 启动桥接 ==="
sudo pkill -f usbmux-bridge.py 2>/dev/null || true
sleep 1
sudo rm -f /var/run/usbmuxd
sudo BRIDGE_TARGET_HOST=$TARGET_HOST BRIDGE_TARGET_PORT=$TARGET_PORT \
  nohup python3 "$TOOLS_DIR/usbmux-bridge.py" >"$BRIDGE_LOG" 2>&1 &
sleep 2
head -1 "$BRIDGE_LOG" | grep -q "bridging" \
  || die "桥接没起来，看 $BRIDGE_LOG"
say "  $(head -1 "$BRIDGE_LOG")"

say ""
say "=== 5. 验证 ==="
udid=$(timeout 30 idevice_id -l 2>/dev/null | head -1)
if [ -z "$udid" ]; then
  say "  idevice_id 没读到设备"
  say "  检查手机是否插好、解锁、已点「信任此电脑」。"
  exit 2
fi
say "  设备 UDID: $udid"

if command -v xtool >/dev/null 2>&1; then
  # --usb 必须显式给：默认 --all 会枚举 Network 设备，那条在 WSL 里到不了。
  xtool devices --usb --no-wait 2>&1 | sed 's/^/  /'
fi

say ""
say "OK：链路已就绪，可以跑 xtool dev --usb"
