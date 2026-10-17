#!/usr/bin/env bash
# Android 模拟器冒烟：内置浏览器打开 m.youtube.com，检查共享防沉迷脚本已注入（window.__mioYTFocus + 样式节点 + 规则数）。
# 依赖 debug 包：BrowserActivity 在 debug manifest 里 exported，YouTubeFocus.reportState 在 onPageFinished 把状态写进 logcat（tag MioYTFocus）。
# Google 限流 / 打不开 YouTube（google.com/sorry、无网络）时会失败 —— 只重跑 android-emulator 这个 job。
# 用法：scripts/android-ytfocus-smoke.sh <输出目录>（APK 已由 android-emulator-smoke.sh 装好）
set -uo pipefail
OUT="$1"; mkdir -p "$OUT"
URL="https://m.youtube.com/"
adb logcat -c
adb shell am start -W -n xyz.mio.app/.browser.BrowserActivity -e url "$URL" | tee "$OUT/am-start-browser.txt"
OK=0
for i in $(seq 1 60); do
  sleep 2
  adb logcat -d -v time > "$OUT/logcat-browser.txt"
  if grep -E 'MioYTFocus.*state .*"installed":true' "$OUT/logcat-browser.txt" | grep -q '"style":true'; then OK=1; break; fi
done
sleep 3
adb logcat -d -v time > "$OUT/logcat-browser.txt"
adb exec-out screencap -p > "$OUT/screen-youtube.png" || true
echo "--- MioYTFocus"
grep -E "MioYTFocus|AndroidRuntime|FATAL" "$OUT/logcat-browser.txt" | tail -20
FAIL=0
if grep -q "FATAL EXCEPTION" "$OUT/logcat-browser.txt"; then echo "FAIL: crash"; FAIL=1; fi
[ "$OK" = 1 ] || { echo "FAIL: YouTube focus script not detected on $URL (rate-limited? rerun only this job)"; FAIL=1; }
if [ "$OK" = 1 ]; then
  LINE=$(grep -E 'MioYTFocus.*state .*"installed":true' "$OUT/logcat-browser.txt" | tail -1)
  RULES=$(echo "$LINE" | sed -E 's/.*"rules":([0-9]+).*/\1/')
  case "$RULES" in ''|*[!0-9]*) RULES=0 ;; esac
  [ "$RULES" -ge 40 ] || { echo "FAIL: only $RULES CSS rules in mio-yt-focus-style"; FAIL=1; }
  echo "$LINE" | grep -q '"playables":true' || { echo "FAIL: Playables hiding not on by default"; FAIL=1; }
  echo "$LINE" | grep -q 'docStart' && echo "mode: document-start" || echo "mode: evaluateJavascript fallback"
fi
[ "$FAIL" = 0 ] && echo "PASS: YouTube focus injected on m.youtube.com"
exit $FAIL
