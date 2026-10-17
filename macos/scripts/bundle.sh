#!/bin/bash
# 把 macos/ 包（依赖 apple/MioKit）构建成 Mio Preview.app（Info.plist + 资源包 + ad-hoc 签名）。
# 用法：macos/scripts/bundle.sh [输出目录，默认 macos/dist]   需要 macOS + Xcode
# 预览版 bundle id = xyz.mio.mac.preview：与现在的 Mac Catalyst 版（xyz.mio.app）并存，不共用 UserDefaults / 网站数据。
#
# 构建用 xcodebuild（默认），不用 swift build：MioKit 和 swift-psl（SafariConverterLib 依赖）带 SwiftPM 资源包，
# swift build 生成的 Bundle.module 在 macOS 上只找「.app 根目录」和编译机上的构建目录（找不到就 fatalError），
# 而 .app 根目录不能放文件（codesign：unsealed contents present in the bundle root）。
# Xcode 生成的 Bundle.module 先找 Bundle.main.resourceURL（= Contents/Resources），资源包放那里即可。
# MIO_MAC_BUILD=swiftpm 可退回 swift build（只适合在构建机上本地跑）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/macos"
OUT="${1:-$PKG/dist}"
VERSION=$(node -p "require('$ROOT/package.json').version" 2>/dev/null || echo 0.0.0)
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
MODE="${MIO_MAC_BUILD:-xcode}"

if [ "$MODE" = swiftpm ]; then
  CONFIG="${MIO_MAC_CONFIG:-release}"
  swift build --package-path "$PKG" -c "$CONFIG" ${MIO_MAC_ARCHS:-}
  PRODUCTS="$(swift build --package-path "$PKG" -c "$CONFIG" ${MIO_MAC_ARCHS:-} --show-bin-path)"
else
  CONFIG="${MIO_MAC_CONFIG:-Release}"
  DD="${MIO_MAC_DERIVED_DATA:-$PKG/.build/xcode-dd}"
  LOG="$(mktemp -t mio-mac-xcodebuild).log"
  # 默认只编本机架构（CI 是 arm64）；要通用二进制：MIO_MAC_XCODE_ARGS="ONLY_ACTIVE_ARCH=NO"
  if ! (cd "$PKG" && xcodebuild build -scheme MioMac -destination 'platform=macOS' -configuration "$CONFIG" \
      -derivedDataPath "$DD" -skipPackagePluginValidation -skipMacroValidation \
      CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ${MIO_MAC_XCODE_ARGS:-}) > "$LOG" 2>&1; then
    echo "--- xcodebuild errors ---"; grep -E "error:|fatal error|BUILD FAILED" "$LOG" | sort -u | head -120
    echo "--- xcodebuild tail ---"; tail -60 "$LOG"
    exit 1
  fi
  grep -c "warning:" "$LOG" | sed 's/^/xcodebuild warnings: /' || true
  tail -5 "$LOG"
  PRODUCTS="$DD/Build/Products/$CONFIG"
fi
BIN="$PRODUCTS/MioMac"
test -x "$BIN"

APP="$OUT/Mio Preview.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MioMac"
# SwiftPM 资源包（MioKit_MioKit.bundle：注入脚本 js/、内置规则 filters/；swift-psl 的公共后缀表）→ Contents/Resources
for b in "$PRODUCTS"/*.bundle; do
  [ -d "$b" ] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
done
test -d "$APP/Contents/Resources/MioKit_MioKit.bundle"
ls "$APP/Contents/Resources"
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
