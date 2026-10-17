#!/usr/bin/env bash
# Android 模拟器冒烟：内置浏览器多标签页。debug 包里 BrowserActivity 收到 --ez mioTabsSmoke true 后：
# 开第二个标签、后台再开一个 m.youtube.com（检查后台标签也注入了防沉迷脚本 = per-tab setup）、切回、关闭、恢复关闭，结果写进 logcat（tag MioTabs）。
# 用法：scripts/android-tabs-smoke.sh <输出目录>（APK 已由 android-emulator-smoke.sh 装好）
set -uo pipefail
OUT="$1"; mkdir -p "$OUT"
adb logcat -c
adb shell am start -W -n xyz.mio.app/.browser.BrowserActivity -e url "https://example.org/" --ez mioTabsSmoke true | tee "$OUT/am-start-tabs.txt"
OK=0
for i in $(seq 1 45); do
  sleep 2
  adb logcat -d -v time > "$OUT/logcat-tabs.txt"
  if grep -q 'MioTabs.*smoke ' "$OUT/logcat-tabs.txt"; then break; fi
done
sleep 1
adb logcat -d -v time > "$OUT/logcat-tabs.txt"
adb exec-out screencap -p > "$OUT/screen-tabs.png" || true
echo "--- MioTabs"
grep -E "MioTabs|AndroidRuntime|FATAL" "$OUT/logcat-tabs.txt" | tail -20
FAIL=0
if grep -q "FATAL EXCEPTION" "$OUT/logcat-tabs.txt"; then echo "FAIL: crash"; FAIL=1; fi
if grep -q 'MioTabs.*smoke .*"ok":true' "$OUT/logcat-tabs.txt"; then OK=1; fi
[ "$OK" = 1 ] || { echo "FAIL: tabs smoke did not report ok (YouTube rate-limited? rerun only this job)"; FAIL=1; }
# 收起：任务移到后台，浏览器进程和标签都还在
adb shell input keyevent KEYCODE_BACK; sleep 1; adb shell input keyevent KEYCODE_BACK; sleep 2
adb shell pidof xyz.mio.app:browser > "$OUT/browser-pid.txt" || true
[ -s "$OUT/browser-pid.txt" ] && echo "browser process alive after hide: $(cat "$OUT/browser-pid.txt")" || echo "note: browser process not found after back presses"
[ "$FAIL" = 0 ] && echo "PASS: multi-tab smoke"
exit $FAIL
