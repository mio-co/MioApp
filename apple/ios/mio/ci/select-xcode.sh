#!/usr/bin/env bash
# firefox-ios v158 用 Xcode 26.5（上游 README / bitrise）。优先精确 26.5，否则最高 26.x。
set -euo pipefail
X=""
for c in /Applications/Xcode_26.5.app /Applications/Xcode_26.5.0.app; do
  [ -d "$c" ] && { X="$c"; break; }
done
[ -n "$X" ] || X=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n1)
echo "Using $X"
sudo xcode-select -s "$X/Contents/Developer"
xcodebuild -version
# Xcode 26 默认用 swift-syntax 预编译包；ModifiedCopyMacro 在 CI 上解析不到 SwiftSyntax 模块 → 关掉预编译，从源码构建宏依赖
defaults write com.apple.dt.Xcode IDEPackageEnablePrebuilts -bool NO
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
xcrun simctl list runtimes | grep -i ios || true
