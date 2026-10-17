#!/usr/bin/env bash
# Mio iOS（firefox-ios fork）模拟器冒烟：
#   1. 冷启动 → 等待 → 截图（首页 = mio://home，地址栏应显示「Mio」）
#   2. App 内 MioKit 断言（MioSmoke.swift → kit-smoke.json）：mio://home→MioCore、本机桥来源校验、广告拦截、Mio 扩展设置页截图
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
# SIMCTL_CHILD_MIO_SMOKE=1 → App 里的 MioSmoke（Client/Frontend/Browser/Mio/MioSmoke.swift）等 go 文件后跑 MioKit 断言
LOUT=$(SIMCTL_CHILD_MIO_SMOKE=1 xcrun simctl launch --terminate-running-process --stdout="$OUT/stdout.txt" --stderr="$OUT/stderr.txt" "$DEV" "$BID" 2>&1)
echo "$LOUT" > "$OUT/launch.txt"
PID=${LOUT##*: }

# 模拟器里的 App 进程在宿主机上可见。不用 `simctl spawn launchctl list`（每次 ~30 s，25 秒的等待会拖成十几分钟）
alive() {
  ps -p "$PID" >/dev/null 2>&1 && return 0
  pgrep -qx "$EXE" 2>/dev/null
}
# 带超时执行（macOS 没有 timeout 命令）
run_to() {
  local secs="$1"; shift
  "$@" & local p=$!
  ( sleep "$secs"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 </dev/null & local w=$!
  wait "$p"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}
step() { # name, seconds
  local name="$1" secs="$2"
  for i in $(seq 1 "$secs"); do
    if ! alive; then echo "$name CRASHED (gone after ~${i}s)" | tee -a "$SUMMARY"; FAIL=1; return 1; fi
    sleep 1
  done
  run_to 30 xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1 || true
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

# `simctl openurl` 打自定义 scheme 时模拟器会弹「在 Mio 中打开？」系统确认框，命令一直挂着（88f3e1a 的 run 里三次都 30 s 超时）。
# 所以 mio://home / 网页 / 标签页概览改由 App 内 MioSmoke 自己打开并请求截图（05-08）。
step 01-launch-home "$WAIT" || true

# App 内 MioKit 断言：mio://home → MioCore、example.com 调本机桥被拒 / mio://about 可用、广告请求被拦、Mio 扩展设置页
kit_smoke() {
  local smoke i name
  # 不用 `simctl get_app_container`（CI 上 simctl 很慢，30 s 也没返回）：App 启动时自己建 Documents/mio-smoke，直接在宿主机上找
  local apps="$HOME/Library/Developer/CoreSimulator/Devices/$DEV/data/Containers/Data/Application"
  smoke=""
  for i in $(seq 1 120); do
    smoke=$(ls -dt "$apps"/*/Documents/mio-smoke 2>/dev/null | head -n 1)
    [ -n "$smoke" ] && break
    alive || break
    sleep 1
  done
  [ -n "$smoke" ] || { echo "kit-smoke NO_CONTAINER" | tee -a "$SUMMARY"; FAIL=1; return 1; }
  echo "kit-smoke dir: $smoke"
  mkdir -p "$smoke"; rm -f "$smoke/report.json"; touch "$smoke/go"
  for i in $(seq 1 "${KIT_SMOKE_TIMEOUT:-900}"); do
    if ! alive; then echo "kit-smoke CRASHED (gone after ~${i}s)" | tee -a "$SUMMARY"; FAIL=1; break; fi
    if [ -f "$smoke/shot-request" ]; then
      name=$(cat "$smoke/shot-request")
      run_to 60 xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1 || echo "screenshot $name timed out (in-app copy: $name-app.png)"
      rm -f "$smoke/shot-request"
    fi
    [ -f "$smoke/report.json" ] && break
    sleep 1
  done
  cp "$smoke"/*.png "$OUT/" 2>/dev/null || true
  if [ ! -f "$smoke/report.json" ]; then
    [ "$FAIL" = 1 ] || { echo "kit-smoke TIMEOUT (no report.json)" | tee -a "$SUMMARY"; FAIL=1; }
    return 1
  fi
  cp "$smoke/report.json" "$OUT/kit-smoke.json"
  echo "--- kit-smoke.json"; cat "$OUT/kit-smoke.json"; echo
  python3 - "$OUT/kit-smoke.json" <<'PY' | tee -a "$SUMMARY"
import json, sys
r = json.load(open(sys.argv[1]))
for k in ("homeOK", "bridgeOK", "blockOK", "settingsOK", "newTabOK"):
    v = r.get(k)
    # homeOK == "access-login": MioCore is behind Cloudflare Access and CI is not signed in (login page reached = OK)
    print(f"kit-smoke {k} {v if isinstance(v, str) else ('OK' if v else 'FAIL')}")
h = r.get("home", {})
if h.get("landing") == "access-login":
    print(f"kit-smoke access-login host={h.get('loginHost')} ruleLists={len(h.get('loginRuleLists') or [])} ua={h.get('loginUserAgent')}")
for name, c in sorted((r.get("newTab", {}).get("cases") or {}).items()):
    if isinstance(c, dict):
        print(f"kit-smoke newTab {name} {'OK' if c.get('ok') else 'FAIL'} new={c.get('newTabs')} urls={c.get('newURLs')} same={c.get('sameTabAfter')}")
PY
  if [ "$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1])).get("pass") else 0)' "$OUT/kit-smoke.json")" != 1 ]; then
    FAIL=1; return 1
  fi
}
if [ "$FAIL" = 0 ]; then kit_smoke || true; fi
crop_bottom "$OUT/06-smoke-example.png" "$OUT/06-smoke-example-bottom-toolbar.png"

run_to 90 xcrun simctl spawn "$DEV" log show --style compact --last 5m \
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
