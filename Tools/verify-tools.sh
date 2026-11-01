#!/usr/bin/env bash
# 验证仓库内 Tools/ 脚本能独立工作（设备发现 + 授权检查 + 语法）。
set -u
cd /home/yang/ios/NovelReader/Tools

echo "=== 语法 ==="
for f in device.sh pack-install.sh deploy.sh login-apple.sh; do
  bash -n "$f" && echo "$f ok"
done

echo
echo "=== 设备发现 ==="
. ./device.sh
list_devices

echo
echo "=== 自动选择 ==="
if picked=$(select_udid); then
  echo "挑中: $picked"
  if profile_covers "$picked" ; then
    echo "签名授权覆盖: 是"
  else
    echo "签名授权覆盖: 否（需要重新登录刷新 profile）"
  fi
else
  echo "没有唯一设备"
fi

echo
echo "=== pack-install.sh 前置检查 ==="
bash ./pack-install.sh
echo "exit=$?"
