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

# 已签名的产物再走一次 `xtool install`，会在这个前缀之上再叠一层，
# 变成一个「新」应用：
#
#   XTL-4JBQYZ7D5X.com.yang.NovelReader            ← 正常
#   XTL-4JBQYZ7D5X.XTL-4JBQYZ7D5X.com.yang.NovelReader  ← 二次前缀
#
# 两者的数据显示不同步：新装的那个是空容器，老的那个还在，桌面上于是
# 出现两个同名「夜读」，各自有各自的书架和进度。卸掉任何一个都丢数据。
# 这里提前挡住：前缀出现两次就说明产物不是 --sign 的直出物。
case "$BUNDLE_ID" in
  *XTL-*XTL-*)
    echo "产物 bundle id 带了两层团队前缀：$BUNDLE_ID" >&2
    echo "这说明它被签名过一次之后又拿去 install 了一次，装上去会变成第二个 App。" >&2
    echo "重新从干净产物构建：" >&2
    echo "  cd $REPO_ROOT && xtool-proxy dev build --sign" >&2
    exit 4
    ;;
esac

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
# 不用 `xtool install`：它会对传入的包再做一次签名，而 --sign 出来的产物
# bundle id 已经带团队前缀，于是被加上第二层前缀，变成一个「新」应用独立安装：
#
#   XTL-4JBQYZ7D5X.com.yang.NovelReader                 ← 本来那个
#   XTL-4JBQYZ7D5X.XTL-4JBQYZ7D5X.com.yang.NovelReader  ← xtool install 造出来的
#
# 两个 App 容器各自独立，桌面上却是同名图标，卸掉任何一个都会丢书。
#
# pymobiledevice3 走 installation_proxy，只把包原样交给设备，不做签名，
# 同一 bundle id 就地替换，容器保留。签名仍由 `dev build --sign` 负责。
if [ ! -x "$PMD3_PY" ]; then
  echo "找不到 pymobiledevice3：$PMD3_PY" >&2
  echo "装包要用它（xtool install 会给已签名产物叠第二层前缀，见上面的注释）。" >&2
  exit 5
fi
"$PMD3_PY" apps install --udid "$TARGET" "$OUT" 2>&1 | tail -12
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

if [ "$STATUS" -eq 0 ] && [ -x "$PMD3_PY" ]; then
  # 设备上同时存在多个 NovelReader 时，安装只会更新与 bundle id 完全相同的
  # 那一个，另一个继续留在桌面上。两个同名图标各自有独立容器，数据不同步，
  # 用户很难看出点的是哪一个，所以装完就报出来。
  DUPES=$("$PMD3_PY" apps list --udid "$TARGET" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ids = [b for b in data if "NovelReader" in b]
if len(ids) > 1:
    for b in sorted(ids):
        print("  " + b)
' 2>/dev/null)

  if [ -n "$DUPES" ]; then
    echo
    echo "注意：设备上有多个夜读，桌面会显示成同名图标，各自数据独立：" >&2
    echo "$DUPES" >&2
    echo "只保留一个：$PMD3_PY apps uninstall <不要的那个 bundle id>" >&2
  fi
fi

exit "$STATUS"
