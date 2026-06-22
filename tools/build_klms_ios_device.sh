#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj"
LOCAL_CONFIG="$ROOT_DIR/apps/KLMSync/Config/KLMSiOS.local.xcconfig"
SDK="${IOS_DEVICE_SDK:-iphoneos}"
DESTINATION="${IOS_DEVICE_DESTINATION:-generic/platform=iOS}"
SYMROOT="${SYMROOT:-/private/tmp/klms-ios-device-build}"
OBJROOT="${OBJROOT:-/private/tmp/klms-ios-device-obj}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/klms-ios-device-derived}"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-/private/tmp/klms-ios-device-module-cache}"
CODE_SIGNING_ALLOWED_VALUE="${CODE_SIGNING_ALLOWED:-YES}"
LOCAL_SIGNING_OVERRIDES=()
XCODEBUILD_PROVISIONING_ARGS=()
BUILD_LOG="${IOS_DEVICE_BUILD_LOG:-$(mktemp -t klms-ios-device-build.XXXXXX)}"
REMOVE_BUILD_LOG=0

if [[ -z "${IOS_DEVICE_BUILD_LOG:-}" ]]; then
  REMOVE_BUILD_LOG=1
fi

if [[ "${IOS_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  XCODEBUILD_PROVISIONING_ARGS=(-allowProvisioningUpdates)
fi

if [[ "$CODE_SIGNING_ALLOWED_VALUE" != "NO" && ! -f "$LOCAL_CONFIG" ]]; then
  print -ru2 -- "Missing ignored local signing config: apps/KLMSync/Config/KLMSiOS.local.xcconfig"
  print -ru2 -- "Create it from apps/KLMSync/README.md, or run CODE_SIGNING_ALLOWED=NO $0 for compile-only validation."
  exit 2
fi

if [[ "$CODE_SIGNING_ALLOWED_VALUE" == "NO" ]]; then
  LOCAL_SIGNING_OVERRIDES=(
    KLMS_IOS_DEVELOPMENT_TEAM=
    KLMS_IOS_BUNDLE_IDENTIFIER=com.local.KLMSync.iOS
  )
fi

"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null

mkdir -p "$SYMROOT" "$OBJROOT" "$DERIVED_DATA_PATH" "$MODULE_CACHE_DIR"

set +e
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme KLMSiOS \
  -configuration Debug \
  -sdk "$SDK" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${XCODEBUILD_PROVISIONING_ARGS[@]}" \
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED_VALUE" \
  "${LOCAL_SIGNING_OVERRIDES[@]}" \
  SYMROOT="$SYMROOT" \
  OBJROOT="$OBJROOT" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  build 2>&1 | tee "$BUILD_LOG"
xcodebuild_status=${pipestatus[1]}
set -e

if (( xcodebuild_status != 0 )); then
  if [[ "$CODE_SIGNING_ALLOWED_VALUE" != "NO" ]] && grep -q "No Accounts" "$BUILD_LOG"; then
    print -ru2 -- ""
    print -ru2 -- "iPhone/iPad signed build failed because Xcode has no signed-in Apple development account."
    print -ru2 -- "Open Xcode > Settings > Accounts, sign in, then rerun:"
    print -ru2 -- "  IOS_ALLOW_PROVISIONING_UPDATES=1 $0"
    print -ru2 -- "For compile-only validation without installing on a device, run:"
    print -ru2 -- "  CODE_SIGNING_ALLOWED=NO $0"
  elif [[ "$CODE_SIGNING_ALLOWED_VALUE" != "NO" ]] && grep -q "No profiles for" "$BUILD_LOG"; then
    print -ru2 -- ""
    print -ru2 -- "iPhone/iPad signed build failed because the local provisioning profile is missing."
    print -ru2 -- "If Xcode is signed in, let Xcode create/update the profile:"
    print -ru2 -- "  IOS_ALLOW_PROVISIONING_UPDATES=1 $0"
  fi
  print -ru2 -- "Full xcodebuild log: $BUILD_LOG"
  exit "$xcodebuild_status"
fi

if (( REMOVE_BUILD_LOG == 1 )); then
  rm -f "$BUILD_LOG"
fi

print -r -- "$SYMROOT/Debug-iphoneos/KLMSiOS.app"
