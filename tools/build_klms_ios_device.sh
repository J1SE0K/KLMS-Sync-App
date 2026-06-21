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

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme KLMSiOS \
  -configuration Debug \
  -sdk "$SDK" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED_VALUE" \
  "${LOCAL_SIGNING_OVERRIDES[@]}" \
  SYMROOT="$SYMROOT" \
  OBJROOT="$OBJROOT" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  build

print -r -- "$SYMROOT/Debug-iphoneos/KLMSiOS.app"
