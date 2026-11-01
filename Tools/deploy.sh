#!/usr/bin/env bash
# 用 xtool 暂存目录里的 ipa 装到真机。
#
# 目标是哪台设备不再写死：默认取当前唯一连着的那台，多台时要求用 UDID 指定。
#   bash deploy.sh
#   UDID=00008150-000C42C20E61401C bash deploy.sh
set -u
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TOOLS_DIR/device.sh"

IPA=$(ls -t "$HOME"/.cache/xtool/pid-*/dir-staging-*/staging/app.ipa 2>/dev/null | head -1)

if [ -z "${IPA:-}" ] || [ ! -f "$IPA" ]; then
  echo "找不到 app.ipa，先运行 xtool dev build --sign"
  exit 1
fi
echo "ipa: $IPA ($(stat -c%s "$IPA") bytes)"

TARGET=$(select_udid) || exit 2
echo "=== device ==="
echo "$TARGET"

echo "=== install ==="
xtool install --udid "$TARGET" "$IPA" 2>&1 | tail -12
exit "${PIPESTATUS[0]}"
