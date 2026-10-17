#!/usr/bin/env bash
# 用法：apple/ios/mio/ci/build.sh sim|device <derivedDataPath> <log>
# 构建 Firefox scheme / Firefox 配置（release 渠道，产物名 Client.app，显示名 Mio）
set -uo pipefail
KIND="$1"; DD="$2"; LOG="$3"
PROJ=apple/ios/firefox-ios/Client.xcodeproj
xcodebuild -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile \
  -project "$PROJ" -scheme Firefox -derivedDataPath "$DD" -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -n 30
if [ "$KIND" = sim ]; then
  ARGS=(-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
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
if [ $RC -ne 0 ]; then
  echo "=== errors"
  grep -E "(error|fatal error): " "$LOG" | grep -v "^ " | sed -E 's#^/Users/runner/work/MioApp/MioApp/##' | sort -u | head -n 150
  echo "=== failed commands"
  grep -A20 "The following build commands failed" "$LOG" | cut -c1-300
fi
exit $RC
