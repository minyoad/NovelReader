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
profile_covers "$TARGET" "$APP"
PROFILE_STATE=$?
if [ "$PROFILE_STATE" -ne 0 ]; then
  echo
  if device_registered "$TARGET"; then
    # 已注册，只是 profile 还是旧的：重新签名即可。
    echo "这台设备已注册，但当前签名 profile 还没带上它。重新签名一次就好：" >&2
    echo "  xtool-proxy dev build --sign" >&2
    echo "  bash $TOOLS_DIR/pack-install.sh" >&2
  else
    # 未注册：重新登录没有用，--sign 也不会注册，只有 install 路径会。
    echo "这台设备还没注册到 Apple 开发者账号（UDID $TARGET）。" >&2
    echo "重新登录或重新签名都不会把它加进去：" >&2
    echo "  'xtool dev build --sign' 调用 signInPlace(app:) 时不传 targetDevice，" >&2
    echo "  而注册设备那一步在没有 targetDevice 时直接返回，等于跳过。" >&2
    echo "只有带设备上下文的安装路径会注册它，也就是 'xtool dev run'：" >&2
    echo "  bash $TOOLS_DIR/dev-run.sh" >&2
  fi
  if [ "$PROFILE_STATE" -eq 2 ]; then
    echo
    echo "（当前没有可读的 embedded.mobileprovision，所以先按未签名处理。）" >&2
  fi
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
# --usb 不能省，理由同 dev-run.sh：默认 --all 会去枚举 Network 设备，那条走
# WSL 到不了的 IPv6 链路本地地址，xtool 处理到它时抛 Error: unknown，安装
# 直接失败。失败时下面还会打印设备上的旧版本，看起来像装成功了。
xtool install --udid "$TARGET" --usb "$OUT" 2>&1 | tail -12
STATUS=${PIPESTATUS[0]}

echo "=== verify ==="
# 查的是设备上当前安装的版本，用来区分「装上了」和「装的还是上一个版本」。
# 只有安装本身成功才值得看：安装失败时这里读到的是旧版本，容易被误读成
# 安装成功。
if [ "$STATUS" -ne 0 ]; then
  echo "安装失败（exit $STATUS），下面是设备上残留的旧版本信息：" >&2
fi
# xtool 没有 query 子命令，查已安装版本仍走 pymobiledevice3。查不到不算失败：
# 安装本身已经报告成功，只是版本信息读不出来。
if [ -n "$BUNDLE_ID" ] && [ -x "$PMD3_PY" ]; then
  "$PMD3_PY" apps query --udid "$TARGET" "$BUNDLE_ID" 2>/dev/null \
    | grep -E 'CFBundleDisplayName|CFBundleIdentifier|CFBundleVersion' | head -5
fi

exit "$STATUS"
