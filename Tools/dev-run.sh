#!/usr/bin/env bash
# 注册新设备 + 签名 + 安装，一条命令。
#
# 为什么不用 `xtool dev build --sign`：那条路调用 `signInPlace(app:)` 时没有
# targetDevice，而 xtool 里注册设备的那一步（DeveloperServicesAddDeviceOperation）
# 开头就是 `guard let targetDevice = context.targetDevice else { return }`，
# 没有设备上下文就直接跳过。所以对新手机来说，重新登录和重新 --sign 都不会把
# 它的 UDID 加进账号，profile 永远只含旧设备。
#
# 带设备上下文的是 install 路径（`xtool dev run`）：它会先把设备注册到开发者
# 账号，再生成包含它的 profile，然后签名、上传安装。
#
#   bash Tools/dev-run.sh
#   bash Tools/dev-run.sh --configuration release
#   UDID=00008150-000C42C20E61401C bash Tools/dev-run.sh
set -u
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
. "$TOOLS_DIR/device.sh"

TARGET=$(select_udid) || exit 2

echo "=== device ==="
echo "$TARGET"

if ! xtool auth status >/dev/null 2>&1; then
  echo "还没有登录 Apple ID，先跑：bash $TOOLS_DIR/login-apple.sh" >&2
  exit 4
fi

if device_registered "$TARGET"; then
  echo "这台设备已在开发者账号里"
else
  # 免费账号最多 3 台。满了的话注册会失败，先把话说明白，免得对着
  # Apple 的原始报错猜。
  registered_count=$(xtool ds devices list 2>/dev/null | grep -c 'udid:' || true)
  echo "这台设备还没注册，将由 xtool dev run 注册（账号现有 ${registered_count} 台，免费账号上限 3 台）"
fi

echo "=== build + register + sign + install ==="
# dev run 自己会构建，不需要先 build --sign。它内部的 signing 会把
# targetDevice 带进去，这才是设备能进 profile 的原因。
cd "$REPO_ROOT" || exit 1

# --usb 不能省。默认的 --all 会同时枚举 USB 和 Network 设备，而 Network 那条
# 是本机经 Bonjour 发现的对等连接（响应里带 NetworkAddress 和 IPv6 链路本地
# 地址），WSL 的 NAT 网络到不了它，xtool 处理到该条目时会抛一个不带信息的
# "Error: unknown"，整条命令直接失败——即使 USB 那台是好的。
#
# 这里只装 USB 上的设备：装机和注册都必须走 USB，任何设备最终都是插线完成的。
xtool-proxy dev run --udid "$TARGET" --usb "$@"
