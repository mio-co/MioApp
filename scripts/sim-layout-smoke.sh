#!/usr/bin/env bash
# iOS 模拟器：iPhone 内置浏览器 Safari 式布局截图冒烟（MioMobileChromeSmoke，MioMobileChrome.swift）。
# 每种布局启动一次（-mioLayoutSmoke YES -mio.browser.layout <layout>），App 每一步写 Documents/layout-smoke/step-<n>.json，
# 这里截图后写 ack-<n>；最后读 result.json（ok=false 即失败）。
# 用法：scripts/sim-layout-smoke.sh <App.app> <输出目录> [layouts...]（默认 compact bottom top）
set -uo pipefail
APP="$1"; OUT="$2"; shift 2
LAYOUTS="${*:-compact bottom top}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
DEV=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x["name"].startswith("iPhone")),""))')
if [ -z "$DEV" ]; then
  DEV=$(xcrun simctl list devices available -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
c=[(k,x["udid"]) for k,v in d.items() if "iOS" in k for x in v if x["name"].startswith("iPhone")]
print(sorted(c)[-1][1] if c else "")')
  xcrun simctl boot "$DEV" 2>/dev/null || true
  xcrun simctl bootstatus "$DEV" -b >/dev/null
fi
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$DEV" "$APP"
FAIL=0
for L in $LAYOUTS; do
  echo "== layout $L"
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
  DATA=$(xcrun simctl get_app_container "$DEV" "$BID" data)
  DIR="$DATA/Documents/layout-smoke"
  rm -rf "$DIR"
  xcrun simctl launch --terminate-running-process "$DEV" "$BID" -mioLayoutSmoke YES -mio.browser.layout "$L" > "$OUT/$L-launch.txt" 2>&1
  n=1; deadline=$((SECONDS+150))
  while [ $SECONDS -lt $deadline ]; do
    if [ -f "$DIR/step-$n.json" ]; then
      sleep 0.8
      name=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("name","step"))' "$DIR/step-$n.json" 2>/dev/null || echo step)
      xcrun simctl io "$DEV" screenshot "$OUT/$L-$n-$name.png" >/dev/null 2>&1 || true
      cp "$DIR/step-$n.json" "$OUT/$L-$n-$name.json"
      touch "$DIR/ack-$n"; n=$((n+1)); continue
    fi
    [ -f "$DIR/result.json" ] && break
    sleep 0.5
  done
  if [ -f "$DIR/result.json" ]; then
    cp "$DIR/result.json" "$OUT/$L-result.json"; cat "$OUT/$L-result.json"
    python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$OUT/$L-result.json" || { echo "FAIL: $L checks"; FAIL=1; }
  else
    echo "FAIL: $L no result.json (crash / timeout)"; FAIL=1
    xcrun simctl io "$DEV" screenshot "$OUT/$L-timeout.png" >/dev/null 2>&1 || true
  fi
done
xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
[ "$FAIL" = 0 ] && echo "PASS: layout smoke ($LAYOUTS)"
exit $FAIL
