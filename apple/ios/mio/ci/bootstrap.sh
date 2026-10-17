#!/usr/bin/env bash
# firefox-ios 构建前置：下载 nimbus-fml（Nimbus 特性清单代码生成器，构建期工具，不进 App）。
# 与上游 bootstrap.sh 的 firefox 分支相同，但不装 git hooks / swiftlint，也不跑 npm（UserScripts 产物已入库）。
set -euo pipefail
cd "${FF_ROOT:-apple/ios}"
curl --proto '=https' --tlsv1.2 -sSf --retry 3 \
  https://raw.githubusercontent.com/mozilla/application-services/main/components/nimbus/ios/scripts/bootstrap.sh \
  | bash -s -- --directory ./firefox-ios/bin ./firefox-ios/nimbus.fml.yaml
ls -la firefox-ios/bin
