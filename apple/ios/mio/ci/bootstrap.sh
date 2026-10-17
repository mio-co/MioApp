#!/usr/bin/env bash
# firefox-ios 构建前置：下载 nimbus-fml（Nimbus 特性清单代码生成器，构建期工具，不进 App）。
# 与上游 bootstrap.sh 的 firefox 分支相同，但不装 git hooks / swiftlint。
# 还要跑 webpack：Client/Assets 下的 UserScripts 产物（AllFramesAtDocumentStart.js、translations-engine.worker.js …）被 .gitignore 忽略，不入库。
set -euo pipefail
cd "${FF_ROOT:-apple/ios}"
curl --proto '=https' --tlsv1.2 -sSf --retry 3 \
  https://raw.githubusercontent.com/mozilla/application-services/main/components/nimbus/ios/scripts/bootstrap.sh \
  | bash -s -- --directory ./firefox-ios/bin ./firefox-ios/nimbus.fml.yaml
ls -la firefox-ios/bin

# UserScripts（webpack → firefox-ios/Client/Assets/*.js）
npm ci --no-audit --no-fund
npm run build
ls -la firefox-ios/Client/Assets/*.js | head -n 40
