#!/usr/bin/env bash
# iOS 模拟器冷启动冒烟：装 App → 冷启动 → 等 N 秒看进程是否还活着，抓 stderr / 崩溃报告。
# 再模拟免费 Apple ID 侧载（iloader / isideload、SideStore 等）：
#   CFBundleIdentifier 改成 <原 id>.<TEAMID>，BGTaskSchedulerPermittedIdentifiers 保持不变，ad-hoc 重签、不带 entitlements。
#
# 用法：scripts/sim-launch-smoke.sh <App.app> <输出目录> [label]
# 环境：SMOKE_WAIT（默认 20 秒）、SMOKE_STRICT=1 时任一场景崩溃即退出 1
set -uo pipefail

APP_SRC="$1"
OUT="$2"
LABEL="${3:-app}"
WAIT="${SMOKE_WAIT:-20}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

log() { echo "[$LABEL] $*"; }

# 选一台可用 iPhone 模拟器（最新 iOS 运行时）
DEV=$(xcrun simctl list devices available -j | python3 -c '
import json,sys,re
d=json.load(sys.stdin)["devices"]
best=None
for rt,devs in d.items():
    m=re.search(r"iOS-(\d+)-(\d+)",rt)
    if not m: continue
    v=(int(m.group(1)),int(m.group(2)))
    for x in devs:
        if x["name"].startswith("iPhone") and (best is None or v>best[0]):
            best=(v,x["udid"],x["name"],rt)
print(best[1] if best else "")
')
if [ -z "$DEV" ]; then echo "no iPhone simulator"; exit 2; fi
xcrun simctl list devices | grep "$DEV" | tee "$OUT/device.txt"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null

REPORTS="$HOME/Library/Logs/DiagnosticReports"
FAIL=0
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

run_case() {
  local name="$1" app="$2"
  local bid
  bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
  local dir="$OUT/$name"
  mkdir -p "$dir"
  log "== $name: bundle id $bid"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :BGTaskSchedulerPermittedIdentifiers' "$app/Info.plist" > "$dir/plist.txt" 2>&1 || true
  xcrun simctl terminate "$DEV" "$bid" 2>/dev/null || true
  xcrun simctl uninstall "$DEV" "$bid" 2>/dev/null || true
  touch "$dir/.start"
  sleep 1
  xcrun simctl install "$DEV" "$app" || { echo "$name INSTALL_FAILED" >> "$SUMMARY"; FAIL=1; return; }
  local out
  out=$(xcrun simctl launch --terminate-running-process --stdout="$dir/stdout.txt" --stderr="$dir/stderr.txt" "$DEV" "$bid" 2>&1)
  echo "$out" > "$dir/launch.txt"
  local pid=${out##*: }
  log "launched pid=$pid, waiting ${WAIT}s"
  # 模拟器里的 App 进程：看模拟器 launchd 的 UIKitApplication:<bid> 条目有没有 pid
  sim_pid() {
    xcrun simctl spawn "$DEV" launchctl list 2>/dev/null | awk -v b="UIKitApplication:$bid" 'index($3,b)==1 {print $1; exit}'
  }
  local alive=1 p
  for i in $(seq 1 "$WAIT"); do
    sleep 1
    p=$(sim_pid)
    if [ -z "$p" ] || [ "$p" = "-" ]; then alive=0; log "gone after ${i}s (launchctl pid='$p')"; break; fi
  done
  xcrun simctl spawn "$DEV" launchctl list 2>/dev/null | grep -i "mio\|UIKitApplication" > "$dir/launchctl.txt" || true
  # 崩溃报告（模拟器进程的 .ips 写在宿主机）
  sleep 2
  find "$REPORTS" -newer "$dir/.start" \( -name 'App-*.ips' -o -name 'App_*.ips' -o -name 'App*.crash' \) -exec cp {} "$dir/" \; 2>/dev/null || true
  xcrun simctl spawn "$DEV" log show --style compact --last 2m \
    --predicate 'process == "App" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] "exception" OR eventMessage CONTAINS "⚡️")' \
    > "$dir/oslog.txt" 2>/dev/null || true
  if [ "$alive" = 1 ]; then
    log "$name: ALIVE after ${WAIT}s"
    echo "$name ALIVE bid=$bid" >> "$SUMMARY"
    xcrun simctl io "$DEV" screenshot "$dir/screen.png" >/dev/null 2>&1 || true
    xcrun simctl terminate "$DEV" "$bid" 2>/dev/null || true
  else
    log "$name: CRASHED / exited"
    echo "$name CRASHED bid=$bid" >> "$SUMMARY"
    FAIL=1
  fi
  echo "--- stderr (tail)"; tail -n 40 "$dir/stderr.txt" 2>/dev/null || true
  for f in "$dir"/*.ips; do
    [ -f "$f" ] || continue
    echo "--- crash report $f"
    python3 - "$f" <<'PY' || head -c 4000 "$f"
import json,sys
raw=open(sys.argv[1]).read()
head,_,body=raw.partition("\n")
j=json.loads(body)
print("exception:", j.get("exception"))
print("termination:", j.get("termination"))
a=j.get("asi") or {}
for k,v in a.items(): print("asi", k, v)
ler=j.get("lastExceptionBacktrace") or []
imgs=j.get("usedImages") or []
def fr(f):
    img=imgs[f["imageIndex"]]["name"] if f.get("imageIndex") is not None and f["imageIndex"]<len(imgs) else "?"
    return f"{img} {f.get('symbol','?')}+{f.get('symbolLocation','')}"
if ler:
    print("lastExceptionBacktrace:")
    for f in ler[:25]: print("  ", fr(f))
th=j.get("threads") or []
ft=j.get("faultingThread",0)
if th and ft < len(th):
    print("faulting thread", ft)
    for f in th[ft].get("frames",[])[:25]: print("  ", fr(f))
PY
  done
}

# 1) 原样
WORK=$(mktemp -d)
APP1="$WORK/orig/App.app"
mkdir -p "$WORK/orig"; rm -rf "$APP1"; ditto "$APP_SRC" "$APP1"
codesign -f -s - "$APP1" >/dev/null 2>&1 || true
run_case original "$APP1"

# 2) 模拟 iloader / isideload：bundle id 加 TEAMID 后缀，其余 Info.plist 不动，ad-hoc 重签、无 entitlements
APP2="$WORK/sideload/App.app"
mkdir -p "$WORK/sideload"; rm -rf "$APP2"; ditto "$APP_SRC" "$APP2"
ORIG_BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP2/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${ORIG_BID}.ABCDE12345" "$APP2/Info.plist"
find "$APP2/Frameworks" -name '*.framework' -maxdepth 1 -exec codesign -f -s - {} \; >/dev/null 2>&1 || true
codesign -f -s - "$APP2" >/dev/null 2>&1 || true
run_case sideload-bundle-id "$APP2"

# 3) 侧载工具裁掉 BGTaskSchedulerPermittedIdentifiers / UIBackgroundModes 的极端情况
APP3="$WORK/stripped/App.app"
mkdir -p "$WORK/stripped"; rm -rf "$APP3"; ditto "$APP2" "$APP3"
/usr/libexec/PlistBuddy -c 'Delete :BGTaskSchedulerPermittedIdentifiers' "$APP3/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :UIBackgroundModes' "$APP3/Info.plist" 2>/dev/null || true
codesign -f -s - "$APP3" >/dev/null 2>&1 || true
run_case sideload-stripped-plist "$APP3"

echo "==== [$LABEL] summary"; cat "$SUMMARY"
if [ "${SMOKE_STRICT:-0}" = 1 ] && [ "$FAIL" = 1 ]; then exit 1; fi
exit 0
