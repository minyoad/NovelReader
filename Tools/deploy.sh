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

# 已签名的包不能交给 `xtool install`：它会再签一次，团队前缀因此叠成两层，
# 变成一个独立的新应用（见 pack-install.sh 里的说明）。这种包只有
# pymobiledevice3 会原样交给设备，同 id 就地替换。
#
# 未签名的暂存包反过来必须走 xtool，签名是它负责的。
IPA_ID=$(python3 - "$IPA" <<'PY'
import plistlib, sys, zipfile

try:
    with zipfile.ZipFile(sys.argv[1]) as bundle:
        name = next(n for n in bundle.namelist()
                    if n.startswith("Payload/") and n.endswith(".app/Info.plist"))
        print(plistlib.loads(bundle.read(name)).get("CFBundleIdentifier", ""))
except Exception:
    print("")
PY
)

echo "=== install ==="
case "$IPA_ID" in
  *XTL-*)
    if [ ! -x "$PMD3_PY" ]; then
      echo "这个 ipa 已经签过名，但它不能再走 xtool install（会叠第二层前缀）。" >&2
      echo "找不到 pymobiledevice3：$PMD3_PY" >&2
      exit 5
    fi
    echo "已签名：$IPA_ID"
    "$PMD3_PY" apps install --udid "$TARGET" "$IPA" 2>&1 | tail -12
    ;;
  *)
    echo "未签名：${IPA_ID:-读不出 bundle id}，交给 xtool 签名后安装"
    xtool install --udid "$TARGET" --usb "$IPA" 2>&1 | tail -12
    ;;
esac
exit "${PIPESTATUS[0]}"
