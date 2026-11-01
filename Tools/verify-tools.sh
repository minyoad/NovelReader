#!/usr/bin/env bash
# 验证 Tools/ 脚本的设备发现、授权判断和语法，不实际安装。
set -u
cd /home/yang/ios/NovelReader/Tools

echo "=== 语法 ==="
for f in device.sh pack-install.sh deploy.sh dev-run.sh login-apple.sh; do
  bash -n "$f" && echo "$f ok"
done

echo
echo "=== 设备发现 ==="
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
  if profile_covers "$picked"; then
    echo "签名 profile 覆盖: 是"
  else
    echo "签名 profile 覆盖: 否"
  fi
else
  echo "没有唯一设备可测"
fi
