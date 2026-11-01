#!/usr/bin/env bash
# 把已签名的 NovelReader.app 打成 ipa 并安装到真机。
#
# 目标是哪台设备不再写死：默认取当前唯一连着的那台，多台时要求用 UDID 指定。
#   bash pack-install.sh
#   UDID=00008150-000C42C20E61401C bash pack-install.sh
set -u
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
. "$TOOLS_DIR/device.sh"

APP="$REPO_ROOT/xtool/NovelReader.app"
WORK="$REPO_ROOT/xtool/.ipa-build"
OUT="$REPO_ROOT/xtool/NovelReader.ipa"

if [ ! -d "$APP/_CodeSignature" ]; then
  echo "app 未签名，缺少 _CodeSignature"
  echo "先跑：cd ~/ios/NovelReader && xtool-proxy dev build --sign"
  exit 1
fi

# 先选设备再打包：设备有问题时不该先花时间压一个用不上的 ipa。
TARGET=$(select_udid) || exit 2
BUNDLE_ID=$(app_bundle_id "$APP")

echo "=== device ==="
echo "$TARGET"

# 授权文件不包含这台设备时，安装一定会失败，而且报错看不出原因。提前说清楚，
# 并给出补救步骤。
if ! profile_covers "$TARGET" "$APP"; then
  echo
  echo "这台设备不在当前签名授权里，装了也会失败。" >&2
  echo "现有 profile 只授权了旧设备。需要重新登录 xtool 刷新 profile：" >&2
  echo "  bash $TOOLS_DIR/login-apple.sh" >&2
  echo "（登录后 xtool-proxy dev build --sign 会把当前设备加进授权列表）" >&2
  exit 3
fi

rm -rf "$WORK"
mkdir -p "$WORK/Payload"
cp -a "$APP" "$WORK/Payload/"
cd "$WORK" || exit 1
rm -f "$OUT"
zip -qry "$OUT" Payload
echo "ipa: $OUT ($(stat -c%s "$OUT") bytes)"
cd - >/dev/null

echo "=== install ==="
xtool install --udid "$TARGET" "$OUT" 2>&1 | tail -12
STATUS=${PIPESTATUS[0]}

echo "=== verify ==="
# xtool 没有 query 子命令，查已安装版本仍走 pymobiledevice3。查不到不算失败：
# 安装本身已经报告成功，只是版本信息读不出来。
if [ -n "$BUNDLE_ID" ] && [ -x "$PMD3_PY" ]; then
  "$PMD3_PY" apps query --udid "$TARGET" "$BUNDLE_ID" 2>/dev/null \
    | grep -E 'CFBundleDisplayName|CFBundleIdentifier|CFBundleVersion' | head -5
fi

exit "$STATUS"
