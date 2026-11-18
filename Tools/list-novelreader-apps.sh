#!/usr/bin/env bash
# 用仓库里的 Tools/device.sh 环境，看两台设备上究竟有几份 NovelReader。
. /home/yang/ios/NovelReader/Tools/device.sh 2>/dev/null

for u in 00008110-000E0D2E2E06801E 00008150-000C42C20E61401C; do
  echo "== $u"
  out=$("$PMD3_PY" apps list --udid "$u" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "  apps list 失败（exit $rc）: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    continue
  fi
  printf '%s\n' "$out" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("  输出不是 JSON:", e); sys.exit(0)
ids = sorted(b for b in data if "NovelReader" in b)
print("  共 %d 份:" % len(ids))
for b in ids:
    print("   ", b)
'
done
