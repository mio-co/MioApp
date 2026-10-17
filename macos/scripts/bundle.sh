#!/bin/bash
# 把 SwiftPM 构建的 MioMac 可执行文件包成 Mio Preview.app（Info.plist + ad-hoc 签名）。
# 用法：macos/scripts/bundle.sh [输出目录，默认 macos/dist]   需要 macOS + Xcode（swift build）
# 预览版 bundle id = xyz.mio.mac.preview：与现在的 Mac Catalyst 版（xyz.mio.app）并存，不共用 UserDefaults / 网站数据。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/macos"
OUT="${1:-$PKG/dist}"
VERSION=$(node -p "require('$ROOT/package.json').version" 2>/dev/null || echo 0.0.0)
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG="${MIO_MAC_CONFIG:-release}"

swift build --package-path "$PKG" -c "$CONFIG" ${MIO_MAC_ARCHS:-}
BIN="$(swift build --package-path "$PKG" -c "$CONFIG" ${MIO_MAC_ARCHS:-} --show-bin-path)/MioMac"
test -x "$BIN"

APP="$OUT/Mio Preview.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MioMac"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>MioMac</string>
  <key>CFBundleIdentifier</key><string>xyz.mio.mac.preview</string>
  <key>CFBundleName</key><string>Mio Preview</string>
  <key>CFBundleDisplayName</key><string>Mio Preview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
  <key>NSCameraUsageDescription</key><string>网页请求使用摄像头（例如视频通话）时需要。</string>
  <key>NSMicrophoneUsageDescription</key><string>网页请求使用麦克风（例如视频通话）时需要。</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "$APP"
