#!/usr/bin/env bash
# 注册 + 签名 + 安装到 iPhone 13。
#
# 两台设备都可能在线，显式指定 UDID，避免装错。UDID 写死在这里是因为
# select_udid 自动挑选时 USB 列表里 13 排在前面，多设备时并不可靠。
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export PATH="$HOME/.local/bin:/opt/swift-6.4.1/usr/bin:/usr/local/bin:/usr/bin:/bin"
export USBMUXD_SOCKET_ADDRESS="$(ip route show default | awk '{print $3; exit}'):27016"

TARGET=00008110-000E0D2E2E06801E
echo "=== target: $TARGET (iPhone 13) ==="

LOG=/tmp/devrun-13.log
rm -f "$LOG"

# dev run 可能问「覆盖已有 profile」之类的问题，统一喂 yes。
( sleep 12; yes 2>/dev/null | head -60 ) | \
  script -qec "proxychains4 -q $HOME/.local/share/xtool/AppRun dev run --udid $TARGET --usb" /dev/null > "$LOG" 2>&1
echo "退出码: $?"

echo
echo "=== 关键输出 ==="
grep -avE '^y$|^\s*y\s*$|^\[' "$LOG" | grep -avE '^\s*$' | tail -30
