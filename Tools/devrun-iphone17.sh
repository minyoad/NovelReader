#!/usr/bin/env bash
# 注册 + 签名 + 安装到 iPhone 17。
#
# 两台设备都在线，必须显式指定 UDID；select_udid 的自动逻辑会挑中先枚举到的
# 那台，而 USB 列表里 13 排在前面。
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export PATH="$HOME/.local/bin:/opt/swift-6.4.1/usr/bin:/usr/local/bin:/usr/bin:/bin"
export USBMUXD_SOCKET_ADDRESS="$(ip route show default | awk '{print $3; exit}'):27016"

TARGET=00008150-000C42C20E61401C
echo "=== target: $TARGET (iPhone 17) ==="

LOG=/tmp/devrun-17.log
rm -f "$LOG"

# dev run 可能问「覆盖已有 profile」之类的问题，统一喂 yes。
( sleep 12; yes 2>/dev/null | head -60 ) | \
  script -qec "proxychains4 -q $HOME/.local/share/xtool/AppRun dev run --udid $TARGET --usb" /dev/null > "$LOG" 2>&1
echo "退出码: $?"

echo
echo "=== 关键输出 ==="
grep -avE '^y$|^\s*y\s*$|^\[' "$LOG" | grep -avE '^\s*$' | tail -40
