#!/usr/bin/env bash
# 选最高的 Xcode 26.x（firefox-ios v158 要求 26.5）
set -euo pipefail
ls -d /Applications/Xcode*.app || true
X=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n1 || true)
[ -n "$X" ] || X=$(ls -d /Applications/Xcode*.app | sort -V | tail -n1)
echo "Using $X"
sudo xcode-select -s "$X/Contents/Developer"
xcodebuild -version
xcrun simctl list runtimes | grep -i ios || true
