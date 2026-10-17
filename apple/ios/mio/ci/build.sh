#!/usr/bin/env bash
# 用法：apple/ios/mio/ci/build.sh sim|device <derivedDataPath> <log>
# 构建 Firefox scheme / Firefox 配置（release 渠道，产物名 Client.app，显示名 Mio）
set -uo pipefail
KIND="$1"; DD="$2"; LOG="$3"
PROJ=apple/ios/firefox-ios/Client.xcodeproj
xcodebuild -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile \
  -project "$PROJ" -scheme Firefox -derivedDataPath "$DD" -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -n 30
if [ "$KIND" = sim ]; then
  # 不传 -sdk iphonesimulator：命令行 -sdk 会让 Swift 宏（ModifiedCopyMacros）也按模拟器 SDK 构建，编译器加载不了（"malformed response"）
  ARGS=(-destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
else
  ARGS=(-sdk iphoneos -destination 'generic/platform=iOS'
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
fi
xcodebuild -project "$PROJ" -scheme Firefox -configuration Firefox -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation COMPILER_INDEX_STORE_ENABLE=NO \
  "${ARGS[@]}" build > "$LOG" 2>&1
RC=$?
grep -E "^\*\* BUILD" "$LOG" || true
if [ $RC -eq 0 ] && [ "$KIND" = sim ]; then
  # Firefox 配置的 "Strip Symbols" 阶段在 Frameworks / PlugIns 嵌入并签名之后才 strip，签名失效，
  # 模拟器 dyld 直接 SIGKILL（Code Signature Invalid）。上游靠归档时重签；这里 ad-hoc 重签（真机 ipa 由 SideStore 重签）。
  APP="$DD/Build/Products/Firefox-iphonesimulator/Client.app"
  if [ -d "$APP" ]; then
    find "$APP/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null \
      | xargs -0 -I{} codesign --force --sign - --timestamp=none {}
    find "$APP/PlugIns" -maxdepth 1 -name '*.appex' -print0 2>/dev/null \
      | xargs -0 -I{} codesign --force --sign - --timestamp=none --preserve-metadata=entitlements {}
    codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$APP" || RC=$?
    codesign --verify --deep --strict "$APP" && echo "re-signed (ad-hoc): $APP" || RC=1
  fi
fi
if [ $RC -ne 0 ]; then
  echo "=== errors"
  grep -E "(error|fatal error): " "$LOG" | grep -v "^ " | sed -E 's#^/Users/runner/work/MioApp/MioApp/##' | sort -u | head -n 150
  echo "=== failed commands"
  grep -A20 "The following build commands failed" "$LOG" | cut -c1-300
fi
exit $RC
