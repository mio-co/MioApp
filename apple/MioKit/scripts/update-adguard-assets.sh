#!/usr/bin/env bash
# 更新 Resources/adguard：npm pack 指定版本的 @adguard/scriptlets 和 @adguard/extended-css，复制运行库文件。
# 用法：apple/MioKit/scripts/update-adguard-assets.sh [scriptlets 版本] [extended-css 版本]
set -euo pipefail
cd "$(dirname "$0")/.."
SL=${1:-2.5.1}; EC=${2:-2.3.0}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
( cd "$tmp" && npm pack "@adguard/scriptlets@$SL" "@adguard/extended-css@$EC" >/dev/null && for f in *.tgz; do mkdir "${f%.tgz}" && tar xzf "$f" -C "${f%.tgz}"; done )
cp "$tmp/adguard-scriptlets-$SL/package/dist/scriptlets.corelibs.json" Sources/MioKit/Resources/adguard/
cp "$tmp/adguard-extended-css-$EC/package/dist/extended-css.min.js" Sources/MioKit/Resources/adguard/
echo "updated: scriptlets $SL, extended-css $EC"
