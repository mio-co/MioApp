#!/usr/bin/env bash
# Android 模拟器冒烟：容器（登录状态隔离）。debug 包里的 ContainerSelfTestActivity 检测 MULTI_PROFILE；
# 支持时建两个容器，验证 Cookie / LocalStorage 互相隔离、默认容器看不到、删除后 Profile 被删掉；结果写 logcat（tag MioContainerSmoke）。
# 系统 WebView 不支持 MULTI_PROFILE 时只验证 isSupported()==false 能正确报告（通过，并打印 WebView 版本）。
# 用法：scripts/android-containers-smoke.sh <输出目录>（APK 已由 android-emulator-smoke.sh 装好）
set -uo pipefail
OUT="$1"; mkdir -p "$OUT"
adb shell am force-stop xyz.mio.app || true
adb logcat -c
adb shell am start -W -n xyz.mio.app/xyz.mio.app.containers.ContainerSelfTestActivity | tee "$OUT/am-start-containers.txt"
LINE=""
for i in $(seq 1 45); do
  sleep 2
  adb logcat -d -v time > "$OUT/logcat-containers.txt"
  LINE=$(grep -E 'MioContainerSmoke.*result ' "$OUT/logcat-containers.txt" | tail -1)
  [ -n "$LINE" ] && break
done
echo "--- MioContainerSmoke / MioContainers"
grep -E "MioContainerSmoke|MioContainers|AndroidRuntime|FATAL" "$OUT/logcat-containers.txt" | tail -30
FAIL=0
if grep -q "FATAL EXCEPTION" "$OUT/logcat-containers.txt"; then echo "FAIL: crash"; FAIL=1; fi
[ -n "$LINE" ] || { echo "FAIL: no result from ContainerSelfTestActivity"; FAIL=1; }
if [ -n "$LINE" ]; then
  echo "$LINE" | grep -q '"ok":true' || { echo "FAIL: container isolation self-test failed"; FAIL=1; }
  if echo "$LINE" | grep -q '"supported":true'; then
    echo "MULTI_PROFILE supported: cookie + localStorage isolation verified"
    echo "$LINE" | grep -q '"profilesDeleted":true' || echo "note: profiles not deleted within 8s (kept in pendingRemovals, purged next launch)"
  else
    echo "MULTI_PROFILE not supported on this emulator WebView: containers disabled (isSupported()=false)"
  fi
fi
[ "$FAIL" = 0 ] && echo "PASS: containers smoke"
exit $FAIL
