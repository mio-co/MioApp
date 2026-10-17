#!/usr/bin/env bash
# Mio iOS（firefox-ios fork）模拟器冒烟：
#   1. 冷启动 → 等待 → 截图（首页 = mio://home，地址栏应显示「Mio」）
#   2. 通过 URL scheme 打开 mio://home
#   3. 通过 <scheme>://open-url 打开一个网页 → 截图（含底部工具栏，另裁一张底部工具栏）
#   4. <scheme>://deep-link?url=/action/show-tab-tray → 截图标签页概览
# 任一步骤 App 进程消失即失败。
# 用法：apple/ios/mio/ci/sim-smoke.sh <Client.app> <输出目录>
set -uo pipefail

APP="$1"
OUT="$2"
WAIT="${SMOKE_WAIT:-25}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

DEV=$(xcrun simctl list devices available -j | python3 -c '
import json,sys,re
d=json.load(sys.stdin)["devices"]
best=None
for rt,devs in d.items():
    m=re.search(r"iOS-(\d+)-(\d+)",rt)
    if not m: continue
    v=(int(m.group(1)),int(m.group(2)))
    for x in devs:
        if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"] and (best is None or v>best[0]):
            best=(v,x["udid"])
if best is None:
    for rt,devs in d.items():
        for x in devs:
            if x["name"].startswith("iPhone"): best=((0,0),x["udid"])
print(best[1] if best else "")
')
[ -n "$DEV" ] || { echo "no iPhone simulator"; exit 2; }
xcrun simctl list devices | grep "$DEV" | tee "$OUT/device.txt"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
# 固定状态栏，截图更干净
xcrun simctl status_bar "$DEV" override --time 9:41 --batteryState charged --batteryLevel 100 2>/dev/null || true

BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")
SCHEME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$APP/Info.plist")
{
  echo "bundle id: $BID"
  echo "executable: $EXE"
  echo "public scheme: $SCHEME"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$APP/Info.plist"
} | tee "$OUT/app.txt"

FAIL=0
SUMMARY="$OUT/summary.txt"; : > "$SUMMARY"
touch "$OUT/.start"

xcrun simctl install "$DEV" "$APP" || { echo "INSTALL_FAILED" | tee -a "$SUMMARY"; exit 1; }
LOUT=$(xcrun simctl launch --terminate-running-process --stdout="$OUT/stdout.txt" --stderr="$OUT/stderr.txt" "$DEV" "$BID" 2>&1)
echo "$LOUT" > "$OUT/launch.txt"
PID=${LOUT##*: }

alive() {
  kill -0 "$PID" 2>/dev/null && return 0
  xcrun simctl spawn "$DEV" launchctl list 2>/dev/null | grep -q "UIKitApplication:${BID}\["
}
step() { # name, seconds
  local name="$1" secs="$2"
  for i in $(seq 1 "$secs"); do
    if ! alive; then echo "$name CRASHED (gone after ~${i}s)" | tee -a "$SUMMARY"; FAIL=1; return 1; fi
    sleep 1
  done
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1 || true
  echo "$name OK" | tee -a "$SUMMARY"
}
crop_bottom() { # src dst fraction
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  local h w ch
  h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/{print $2}')
  w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/{print $2}')
  ch=$((h * 18 / 100))
  sips -c "$ch" "$w" --cropOffset $((h - ch)) 0 "$src" --out "$dst" >/dev/null 2>&1 || true
}

if step 01-launch-home "$WAIT"; then
  xcrun simctl openurl "$DEV" "mio://home" 2>&1 | tee -a "$OUT/openurl.txt" || true
  step 02-mio-home 10 || true
fi
if [ "$FAIL" = 0 ]; then
  xcrun simctl openurl "$DEV" "${SCHEME}://open-url?url=https%3A%2F%2Fexample.com%2F" 2>&1 | tee -a "$OUT/openurl.txt" || true
  step 03-webpage 12 && crop_bottom "$OUT/03-webpage.png" "$OUT/03-webpage-bottom-toolbar.png"
fi
if [ "$FAIL" = 0 ]; then
  xcrun simctl openurl "$DEV" "${SCHEME}://deep-link?url=/action/show-tab-tray" 2>&1 | tee -a "$OUT/openurl.txt" || true
  step 04-tab-tray 6 || true
fi

xcrun simctl spawn "$DEV" log show --style compact --last 5m \
  --predicate "process == \"$EXE\" AND (messageType == error OR messageType == fault)" > "$OUT/oslog-errors.txt" 2>/dev/null || true
REPORTS="$HOME/Library/Logs/DiagnosticReports"
find "$REPORTS" -newer "$OUT/.start" -name "${EXE}*" -exec cp {} "$OUT/" \; 2>/dev/null || true
for f in "$OUT"/*.ips; do
  [ -f "$f" ] || continue
  echo "--- crash report $f"; head -c 6000 "$f"; echo
done
echo "--- stderr (tail)"; tail -n 60 "$OUT/stderr.txt" 2>/dev/null || true
echo "=== summary"; cat "$SUMMARY"
ls -la "$OUT"
exit $FAIL
