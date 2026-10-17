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
# v0.4.1 瘦身：-xcconfig MioRelease.xcconfig（关代码覆盖率插桩 / testability，-Osize + WMO，dead strip，dSYM 单独），
# 对所有 target（含 Swift 包）生效；-enableCodeCoverage NO：Firefox scheme 的 UnitTest.xctestplan 开了覆盖率，v0.4.0 的 build 带上了插桩
xcodebuild -project "$PROJ" -scheme Firefox -configuration Firefox -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation -enableCodeCoverage NO \
  -xcconfig apple/ios/mio/ci/MioRelease.xcconfig COMPILER_INDEX_STORE_ENABLE=NO \
  "${ARGS[@]}" build > "$LOG" 2>&1
RC=$?
grep -E "^\*\* BUILD" "$LOG" || true
if [ "$KIND" = sim ]; then APP="$DD/Build/Products/Firefox-iphonesimulator/Client.app"; else APP="$DD/Build/Products/Firefox-iphoneos/Client.app"; fi
if [ $RC -eq 0 ] && [ -d "$APP" ]; then
  # 覆盖率插桩必须没了（v0.4.0 的 Client 里有 __LLVM_COV / __llvm_prf_*）
  if otool -l "$APP/Client" | grep -q -E "__LLVM_COV|__llvm_prf"; then echo "error: Client still has coverage instrumentation"; RC=1; fi
  # 本地化只留中英文、删非运行时文件（apple/ios/mio/ci/slim-app.sh）
  bash apple/ios/mio/ci/slim-app.sh "$APP" || RC=1
  # dSYM 单独保存（不进 .app / ipa）
  mkdir -p "$DD/dSYMs"
  find "$(dirname "$APP")" -maxdepth 1 -name '*.dSYM' -exec cp -R {} "$DD/dSYMs/" \; 2>/dev/null || true
fi
if [ $RC -eq 0 ] && [ "$KIND" = sim ]; then
  # Firefox 配置的 "Strip Symbols" 阶段在 Frameworks / PlugIns 嵌入并签名之后才 strip，签名失效，
  # 模拟器 dyld 直接 SIGKILL（Code Signature Invalid）。上游靠归档时重签；这里 ad-hoc 重签（真机 ipa 由 SideStore 重签）。
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
