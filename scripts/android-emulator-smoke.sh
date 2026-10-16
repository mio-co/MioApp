#!/usr/bin/env bash
# Android 模拟器冷启动：装 debug APK → 启动 → 检查起始地址和首个页面加载（未登录时到 Cloudflare Access / 登录页也算通过）
# 用法：scripts/android-emulator-smoke.sh <apk> <输出目录>
set -uo pipefail
APK="$1"; OUT="$2"; mkdir -p "$OUT"
EXPECTED="https://mio.300031.xyz/mio/nav"
adb wait-for-device
adb shell getprop ro.build.version.release | sed 's/^/android /'
adb install -r -g "$APK" || exit 1
adb logcat -c
adb shell am start -W -n xyz.mio.app/.MainActivity | tee "$OUT/am-start.txt"
OK=0
for i in $(seq 1 90); do
  sleep 2
  adb logcat -d -v time > "$OUT/logcat.txt"
  if grep -Eq "MioStart.*pageLoaded https://(mio\.300031\.xyz|[A-Za-z0-9.-]+\.cloudflareaccess\.com|accounts\.google\.com|github\.com)/" "$OUT/logcat.txt"; then OK=1; break; fi
done
adb exec-out screencap -p > "$OUT/screen.png" || true
adb shell pidof xyz.mio.app > "$OUT/pid.txt" || true
echo "--- MioStart / Capacitor"
grep -E "MioStart|Capacitor.*Loading app|ERR_|AndroidRuntime|FATAL" "$OUT/logcat.txt" | head -40
FAIL=0
grep -q "MioStart.*appUrl=$EXPECTED\$\|MioStart.*appUrl=$EXPECTED\s*$" "$OUT/logcat.txt" || grep -q "MioStart.*appUrl=$EXPECTED" "$OUT/logcat.txt" || { echo "FAIL: appUrl is not $EXPECTED"; FAIL=1; }
if grep -q "xyzmio" "$OUT/logcat.txt"; then echo "FAIL: malformed start URL (xyzmio)"; FAIL=1; fi
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then echo "FAIL: crash"; FAIL=1; fi
[ -s "$OUT/pid.txt" ] || { echo "FAIL: app process not running"; FAIL=1; }
[ "$OK" = 1 ] || { echo "FAIL: no page loaded from mio.300031.xyz / Access / login"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "PASS: start URL $EXPECTED, first page loaded"
exit $FAIL
