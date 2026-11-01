#!/bin/bash
# 交互式 Apple 登录（免费 Apple ID + 密码 + 2FA）
# 密码由 xtool 提示输入，不会写进脚本或历史记录。
set -e
# Work from the repository root so `xtool` picks up this project's xtool.yml.
cd "$(cd "$(dirname "$0")/.." && pwd)"

echo "=== xtool Apple 登录（password 模式） ==="
echo "提示：确认 iPhone 已解锁，并在弹出的「信任此电脑」中点信任。"
echo
read -r -p "Apple ID（邮箱）: " APPLE_ID
if [ -z "$APPLE_ID" ]; then
  echo "没有输入 Apple ID，退出。"
  exit 1
fi

echo
echo "下一步 xtool 会要求输入密码（输入时不显示），然后会要求 6 位双重认证验证码。"
echo
xtool-proxy auth login -m password -u "$APPLE_ID"

echo
echo "=== 登录结果 ==="
xtool auth status
echo
read -r -n 1 -p "按任意键关闭这个窗口…"
