#!/usr/bin/env bash
# Android 模拟器：内置浏览器 Safari 紧凑布局截图冒烟（debug 包 BrowserActivity --ez mioLayoutSmoke true）。
# 每看到一条 "MioLayout step N name" 日志就截图；最后 "MioLayout result {...ok...}"。
set -uo pipefail
OUT="$1"; mkdir -p "$OUT"
adb logcat -c
adb shell am start -W -n xyz.mio.app/.browser.BrowserActivity -e url "https://en.wikipedia.org/wiki/Safari_(web_browser)" --ez mioLayoutSmoke true > "$OUT/am-start.txt"
seen=0
for i in $(seq 1 120); do
  sleep 0.5
  adb logcat -d -v time -s MioTabs > "$OUT/logcat.txt"
  n=$(grep -c "MioLayout step" "$OUT/logcat.txt" || true)
  while [ "$seen" -lt "$n" ]; do
    seen=$((seen+1))
    name=$(grep "MioLayout step $seen " "$OUT/logcat.txt" | head -1 | sed -E 's/.*step [0-9]+ //')
    adb exec-out screencap -p > "$OUT/$seen-${name:-step}.png" || true
  done
  grep -q "MioLayout result" "$OUT/logcat.txt" && break
done
adb logcat -d -v time > "$OUT/logcat-all.txt"
grep "MioLayout" "$OUT/logcat.txt"
if grep -q "FATAL EXCEPTION" "$OUT/logcat-all.txt"; then echo "FAIL: crash"; exit 1; fi
grep -q 'MioLayout result .*"ok":true' "$OUT/logcat.txt" || { echo "FAIL: layout smoke"; exit 1; }
echo "PASS: compact layout smoke"
