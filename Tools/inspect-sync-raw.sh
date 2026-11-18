#!/usr/bin/env bash
# 仔细看两台设备的同步配置，确认 password 字段和 enabled/backend 的实际值。
set -u
PMD=~/.venv-pmd3/bin/pymobiledevice3
GW=$(ip route show default | head -1 | awk '{print $3}')
export USBMUXD_SOCKET_ADDRESS="$GW:27016"

BID=XTL-4JBQYZ7D5X.com.yang.NovelReader
BASE="Library/Application Support/NovelReader"

for pair in "17:00008150-000C42C20E61401C" "13:00008110-000E0D2E2E06801E"; do
  tag=${pair%%:*}; udid=${pair##*:}
  echo "===== iPhone $tag ====="
  rm -f /tmp/c$tag.json
  timeout 60 $PMD apps pull --udid "$udid" "$BID" "$BASE/settings.json" /tmp/c$tag.json >/dev/null 2>&1
  python3 - /tmp/c$tag.json <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
d = s.get("sync", {})
w = d.get("webdav", {})
p = w.get("password", None)
print("  enabled   :", d.get("enabled"))
print("  backend   :", d.get("backend"))
print("  url       :", repr(w.get("directoryURL")))
print("  username  :", repr(w.get("username")))
print("  password  :", repr(p), "(缺字段)" if p is None else "(长度 %d)" % len(p))
print("  lastSync  :", d.get("lastSyncedAt"))
print("  -- 完整 sync 对象 --")
print(" ", json.dumps(d, ensure_ascii=False)[:400])
PY
  echo
done
