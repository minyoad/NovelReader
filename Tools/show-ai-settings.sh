#!/usr/bin/env bash
set -u
PMD=~/.venv-pmd3/bin/pymobiledevice3
GW=$(ip route show default | head -1 | awk '{print $3}')
export USBMUXD_SOCKET_ADDRESS="$GW:27016"

BID=XTL-4JBQYZ7D5X.com.yang.NovelReader
BASE="Library/Application Support/NovelReader"

for pair in "13:00008110-000E0D2E2E06801E" "17:00008150-000C42C20E61401C"; do
  tag=${pair%%:*}
  udid=${pair##*:}
  echo "=== iPhone $tag ==="
  rm -f /tmp/ai$tag.json
  timeout 60 $PMD apps pull --udid "$udid" "$BID" "$BASE/settings.json" /tmp/ai$tag.json >/dev/null 2>&1
  python3 - /tmp/ai$tag.json <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception as e:
    print("  读不到:", e); raise SystemExit(0)
ai = s.get("ai", {})
print("  ai 字段:")
for k in sorted(ai):
    v = ai[k]
    if "key" in k.lower():
        v = ("已设置 %d 字符" % len(v)) if v else "空"
    print("   ", k, "=", repr(v)[:80])
tts = s.get("tts", {})
rem = tts.get("remote", {})
print("  tts.remote:")
for k in sorted(rem):
    v = rem[k]
    if "key" in k.lower():
        v = ("已设置 %d 字符" % len(v)) if v else "空"
    print("   ", k, "=", repr(v)[:60])
PY
  echo
done
