#!/usr/bin/env bash
# 验证 Tools/ 脚本的设备发现、授权判断和语法，不实际安装。
set -u
cd /home/yang/ios/NovelReader/Tools

echo "=== 语法 ==="
for f in device.sh pack-install.sh deploy.sh dev-run.sh login-apple.sh fix-device-link.sh; do
  bash -n "$f" && echo "$f ok"
done
python3 -m py_compile usbmux-bridge.py && echo "usbmux-bridge.py ok"

echo
echo "=== 桥接链路 ==="
if [ -S /var/run/usbmuxd ]; then
  echo "/var/run/usbmuxd 存在"
  if pgrep -f usbmux-bridge.py >/dev/null 2>&1; then
    echo "桥接进程在跑"
  else
    echo "桥接进程没跑 → bash Tools/fix-device-link.sh"
  fi
else
  echo "/var/run/usbmuxd 不存在 → bash Tools/fix-device-link.sh"
fi

echo
echo "=== xtool 视角 ==="
# --usb 是必需的：默认 --all 会枚举 Network 设备，那条走 NAT 下不可达的
# IPv6 链路本地地址，会让 xtool 抛 Error: unknown。
if out=$(timeout 90 xtool devices --usb --no-wait 2>&1); then
  if [ -n "$out" ]; then
    echo "$out"
  else
    echo "(xtool 没报错但没列出设备)"
  fi
else
  echo "$out"
fi

echo
echo "=== 设备发现（pymobiledevice3） ==="
. ./device.sh
list_devices
echo "(列表为空 = 当前没有设备连着)"

echo
echo "=== 账号里已注册的设备 ==="
xtool ds devices list 2>/dev/null | grep -E 'name:|udid:' || echo "(读不到)"

echo
echo "=== 自动选择 ==="
if picked=$(select_udid); then
  echo "挑中: $picked"
  if device_registered "$picked"; then
    echo "已注册到账号: 是"
  else
    echo "已注册到账号: 否 → 应该走 dev-run.sh，而不是 build --sign"
  fi
  profile_covers "$picked"
  case $? in
    0) echo "签名 profile 覆盖: 是" ;;
    1) echo "签名 profile 覆盖: 否" ;;
    *) echo "签名 profile 覆盖: 无法判定（没有产物 profile）" ;;
  esac
else
  echo "没有唯一设备可测"
fi

echo
echo "=== 装机路径 ==="
# pack-install.sh 装的是 --sign 直出物，必须走 pymobiledevice3：交给 xtool install
# 会被再签一次，前缀叠成两层，装出第二个同名 App。
if grep -qE '^[[:space:]]*xtool[[:space:]].*install' pack-install.sh; then
  echo "pack-install.sh 里有会被执行的 xtool install → 会叠第二层前缀，应改用 pymobiledevice3"
else
  echo "pack-install.sh 走 pymobiledevice3 ok"
fi

if [ -x "$PMD3_PY" ] && [ -n "${picked:-}" ]; then
  dupes=$("$PMD3_PY" apps list --udid "$picked" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ids = [b for b in data if "NovelReader" in b]
print(len(ids))
if len(ids) > 1:
    for b in sorted(ids):
        print("  " + b)
')
  echo "设备上的夜读数量: $(printf '%s\n' "$dupes" | head -1)"
  printf '%s\n' "$dupes" | tail -n +2
fi
