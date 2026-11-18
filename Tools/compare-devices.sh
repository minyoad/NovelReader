#!/usr/bin/env bash
# 从两台手机各拉一份书架和书源，然后对比。
#
# 用来确认两台设备同步后是否一致、有没有重复书目。只读：不改设备上的任何数据。
set -u
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

PMD=~/.venv-pmd3/bin/pymobiledevice3
BID=XTL-4JBQYZ7D5X.com.yang.NovelReader
BASE="Library/Application Support/NovelReader"

# device.sh 里设好了 USBMUXD_SOCKET_ADDRESS；不设的话 apps pull 连不上设备。
# shellcheck disable=SC1091
. "$TOOLS_DIR/device.sh" >/dev/null 2>&1
export USBMUXD_SOCKET_ADDRESS

pull_device() {
    local label=$1 udid=$2 out=$3
    rm -rf "$out" && mkdir -p "$out"
    for f in books.json sources.json settings.json; do
        if $PMD apps pull --udid "$udid" "$BID" "$BASE/$f" "$out/" >/dev/null 2>&1; then
            echo "  $label $f ok"
        else
            echo "  $label $f 失败"
        fi
    done
}

echo "--- 拉取 ---"
pull_device "iPhone 13" 00008110-000E0D2E2E06801E /tmp/cmp13
pull_device "iPhone 17" 00008150-000C42C20E61401C /tmp/cmp17
echo
python3 "$TOOLS_DIR/compare-devices.py" "$@"
