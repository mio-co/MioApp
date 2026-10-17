#!/usr/bin/env bash
# 把未签名的 Client.app 打成 ipa（Payload/Mio.app），检查品牌信息。
# 免费 Apple ID 侧载每 7 天最多 10 个 App ID，每个扩展都占一个，所以 ipa 里不带 App 扩展（PlugIns/Extensions）。
set -euo pipefail
APP="$1"; OUT="$2"
rm -rf Payload; mkdir -p Payload
cp -R "$APP" Payload/Mio.app
rm -rf Payload/Mio.app/PlugIns Payload/Mio.app/Extensions
P=Payload/Mio.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleDisplayName' \
  -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$P"
du -sh Payload/Mio.app
(cd . && zip -qry "$OUT" Payload)
ls -lh "$OUT"
