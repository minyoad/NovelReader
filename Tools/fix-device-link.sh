#!/usr/bin/env bash
# 重建 WSL 到 Windows usbmuxd 的通道，并验证 xtool 能看到设备。
#
# 这件事有三个必须同时成立的环节，缺一个就是「手机明明插着，xtool 却说
# Error: unknown」：
#
# 1. Windows 侧 Apple 的 usbmuxd 只绑 127.0.0.1:27015。WSL 是 NAT 网络
#    （Windows 10 没有镜像网络模式），所以要一条 portproxy 转发。
#    监听端口必须错开：写成 0.0.0.0:27015 → 127.0.0.1:27015 会连回环一起
#    占掉 27015，Apple 绑不上只能退到随机端口，整条通道静默失效。
#    这里用 27016。
#
# 2. WSL 自带的 usbmuxd 看不到 USB（没有直通），但它在 /var/run/usbmuxd
#    上占着 unix socket。xtool 经由 libusbmuxd 只连这个 unix socket，
#    所以要在它上面架一个转发到 Windows。WSL 的 usbmuxd 必须先停掉，
#    否则你查到的设备永远是空的。
#
# 3. 配对记录（lockdown plist）要各存一份：Windows 在
#    C:\ProgramData\Apple\Lockdown，WSL 在 /var/lib/lockdown。新手机只在
#    Windows 侧配对过时，WSL 缺这个文件，装机时会卡在签名之后。
#
# 用法：bash Tools/fix-device-link.sh
set -u
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_PY="$TOOLS_DIR/usbmux-bridge.py"
BRIDGE_LOG=/tmp/usbmux-bridge.log
LISTEN_PORT=27016

fail() {
  echo "失败：$*" >&2
  exit 1
}

echo "=== 1. Windows 侧 portproxy ==="
if ! command -v netsh.exe >/dev/null 2>&1; then
  echo "没有 netsh.exe，跳过后面的 Windows 检查（非 WSL 环境？）"
else
  # 自环规则必须先删：它会占住 27015，让 Apple 的 usbmuxd 绑不上。
  netsh.exe interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=27015 >/dev/null 2>&1 || true
  netsh.exe interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$LISTEN_PORT >/dev/null 2>&1 || true
  netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$LISTEN_PORT \
    connectaddress=127.0.0.1 connectport=27015 >/dev/null \
    || fail "add portproxy $LISTEN_PORT"
  echo "0.0.0.0:$LISTEN_PORT -> 127.0.0.1:27015"
fi

echo
echo "=== 2. Windows 侧防火墙 ==="
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command "
    if (-not (Get-NetFirewallRule -DisplayName 'WSL usbmuxd $LISTEN_PORT' -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName 'WSL usbmuxd $LISTEN_PORT' -Direction Inbound \
        -Action Allow -Protocol TCP -LocalPort $LISTEN_PORT -Profile Any | Out-Null
      'added inbound rule'
    } else { 'rule exists' }
  " 2>&1 | tr -d '\r'
fi

echo
echo "=== 3. WSL 自带 usbmuxd 让位 ==="
if systemctl is-active --quiet usbmuxd 2>/dev/null; then
  sudo -n systemctl stop usbmuxd 2>/dev/null \
    && echo "已停止 usbmuxd（它看不到 USB，留着只会抢走 unix socket）" \
    || fail "停不掉 usbmuxd：需要免密 sudo，或手动 sudo systemctl stop usbmuxd"
else
  echo "未运行"
fi

echo
echo "=== 4. 启动 unix socket 桥接 ==="
[ -f "$BRIDGE_PY" ] || fail "缺少 $BRIDGE_PY"
sudo -n pkill -f usbmux-bridge.py 2>/dev/null || true
sleep 1
sudo -n rm -f /var/run/usbmuxd 2>/dev/null || true
sudo -n nohup python3 "$BRIDGE_PY" >"$BRIDGE_LOG" 2>&1 &
sleep 2
grep -q "bridging" "$BRIDGE_LOG" 2>/dev/null || fail "桥接没起来，看 $BRIDGE_LOG"
sed -n '1p' "$BRIDGE_LOG"

echo
echo "=== 5. 同步配对记录 ==="
WIN_LOCKDOWN=/mnt/c/ProgramData/Apple/Lockdown
if [ -d "$WIN_LOCKDOWN" ]; then
  for f in "$WIN_LOCKDOWN"/*.plist; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    if [ ! -f "/var/lib/lockdown/$name" ]; then
      sudo -n cp "$f" "/var/lib/lockdown/$name" \
        && sudo -n chown usbmux:plugdev "/var/lib/lockdown/$name" \
        && echo "同步 $name"
    fi
  done
else
  echo "读不到 $WIN_LOCKDOWN，跳过"
fi

echo
echo "=== 6. 验证 ==="
cd "$TOOLS_DIR/.." || exit 1
# 必须显式 --usb：默认 --all 会去枚举 Network 设备，而那条走 WSL 到不了的
# IPv6 链路本地地址，会让 xtool 抛一个不带信息的 Error: unknown。
if out=$(timeout 90 xtool devices --usb --no-wait 2>&1); then
  if [ -n "$out" ]; then
    echo "$out"
    echo
    echo "OK：链路已恢复"
    exit 0
  fi
else
  echo "$out" >&2
  fail "xtool 报错了，链路还是不通"
fi

# xtool 没报错也没列出设备。这两种情况要分开说，否则会把「没插线」误报成
# 「链路坏了」，让人去改根本没问题的配置。
if command -v powershell.exe >/dev/null 2>&1; then
  present=$(powershell.exe -NoProfile -Command "
    (Get-PnpDevice -ErrorAction SilentlyContinue |
      Where-Object { \$_.FriendlyName -match 'Apple Mobile Device USB Device' -and \$_.Present } |
      Measure-Object).Count
  " 2>/dev/null | tr -d '\r\n ')
  if [ "${present:-0}" = "0" ]; then
    echo "链路正常，但 Windows 上没有任何 Apple USB 设备在位。"
    echo "插上手机、解锁并点「信任此电脑」，再跑一次。"
    exit 2
  fi
  echo "Windows 上有 $present 个 Apple USB 设备在位，但 xtool 没枚举到。" >&2
fi
echo "检查数据线 / 手机上是否点了「信任此电脑」。" >&2
exit 3
