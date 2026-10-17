#!/bin/bash
# 把 macos/ 包（依赖 apple/MioKit）构建成 Mio Preview.app（Info.plist + 资源包 + ad-hoc 签名）。
# 用法：macos/scripts/bundle.sh [输出目录，默认 macos/dist]   需要 macOS + Xcode
# 预览版 bundle id = xyz.mio.mac.preview：与现在的 Mac Catalyst 版（xyz.mio.app）并存，不共用 UserDefaults / 网站数据。
# 发布版（MIO_MAC_RELEASE=1）：Mio.app、bundle id xyz.mio.app（v0.3.x Mac Catalyst 的 id —— 旧版的软件内更新器只接受这个 id，
# 替换后沿用同一份 UserDefaults / 网站数据）、构建号 MIO_MAC_BUILD_NUMBER（默认 git 提交数）、App 图标。
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
BUILD="${MIO_MAC_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
if [ "${MIO_MAC_RELEASE:-0}" = 1 ]; then
  APP_NAME="Mio"; BUNDLE_ID="xyz.mio.app"
else
  APP_NAME="Mio Preview"; BUNDLE_ID="xyz.mio.mac.preview"
fi
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

APP="$OUT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MioMac"
# SwiftPM 资源包（MioKit_MioKit.bundle：注入脚本 js/、内置规则 filters/；swift-psl 的公共后缀表）→ Contents/Resources
for b in "$PRODUCTS"/*.bundle; do
  [ -d "$b" ] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
done
test -d "$APP/Contents/Resources/MioKit_MioKit.bundle"
# App 图标（apple/ios/mio/brand/mio-appicon-1024.png → AppIcon.icns）
ICON_SRC="$ROOT/apple/ios/mio/brand/mio-appicon-1024.png"
ICON_KEY=""
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null; then
  ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ISET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
ls "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>MioMac</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  $ICON_KEY
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
