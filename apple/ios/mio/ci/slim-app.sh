#!/usr/bin/env bash
# 用法：apple/ios/mio/ci/slim-app.sh <Client.app>
# v0.4.1 瘦身：构建后、签名 / 打包前，删掉 .app 里的非运行时文件，本地化只留英文和中文。
# 模拟器冒烟包（build.sh sim，之后 ad-hoc 重签）和真机 ipa（build.sh device）都走这一步，冒烟测的就是发出去的内容。
#
# - 本地化：只留 Base / en / en-US / zh-CN（简体，等同 zh-Hans）/ zh-TW（繁体，等同 zh-Hant）/ zh-Hans / zh-Hant。
#   firefox-ios 的中文目录叫 zh-CN / zh-TW；系统语言是 zh-Hans-* / zh-Hant-* 时 iOS 会匹配到它们。英文字符串的默认值写在代码里
#   （NSLocalizedString 的 value:），其他语言的系统会回落到英文。
# - 非运行时文件：Xcode 测试计划 / xcconfig / Glean 与 Nimbus 的 yaml 定义（生成代码已编进二进制）/ xcfilelist /
#   SyncIntegrationTests（上游 Python 测试）/ 框架里的 Headers、Modules（swiftmodule、swiftdoc、abi.json、swiftsourceinfo）/
#   Sync.framework 的测试证书。
# - dSYM 不在 .app 里（build.sh 另存为 CI 产物）。
set -euo pipefail
APP="$1"
test -d "$APP"
before=$(du -sk "$APP" | cut -f1)

KEEP_RE='^(Base|en|en-US|zh-CN|zh-TW|zh-Hans|zh-Hant)\.lproj$'
removed_lproj=0
while IFS= read -r -d '' d; do
  name=$(basename "$d")
  if [[ ! "$name" =~ $KEEP_RE ]]; then rm -rf "$d"; removed_lproj=$((removed_lproj + 1)); fi
done < <(find "$APP" -type d -name '*.lproj' -prune -print0)

# 非运行时文件（只在 .app 顶层 / 框架顶层找，不碰网页资源和 bundle 内部）
removed_files=0
rmf() { for f in "$@"; do if [ -e "$f" ]; then rm -rf "$f"; removed_files=$((removed_files + 1)); fi; done; }
shopt -s nullglob
rmf "$APP"/*.xctestplan "$APP"/*.xcconfig "$APP"/*.yaml "$APP"/*.yml "$APP"/*.xcfilelist "$APP"/SyncIntegrationTests
for fw in "$APP"/Frameworks/*.framework; do
  rmf "$fw/Headers" "$fw/PrivateHeaders" "$fw/Modules" "$fw"/*.pem "$fw"/*.tbd
done
find "$APP" \( -name '*.swiftmodule' -o -name '*.swiftdoc' -o -name '*.swiftinterface' -o -name '*.abi.json' \
  -o -name '*.swiftsourceinfo' -o -name '*.dSYM' -o -name '*.bcsymbolmap' \) -prune -print0 | while IFS= read -r -d '' f; do rm -rf "$f"; done
shopt -u nullglob

after=$(du -sk "$APP" | cut -f1)
left=$(find "$APP" -type d -name '*.lproj' -prune | sed 's#.*/##' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
echo "slim-app: removed $removed_lproj .lproj dirs, $removed_files non-runtime items; ${before} KB -> ${after} KB; lproj left: $left"
