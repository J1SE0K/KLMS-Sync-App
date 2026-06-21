#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj"
SDK="${IOS_SIMULATOR_SDK:-iphonesimulator}"
SYMROOT="${SYMROOT:-/private/tmp/klms-ios-build}"
OBJROOT="${OBJROOT:-/private/tmp/klms-ios-obj}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/klms-ios-derived}"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-/private/tmp/klms-ios-module-cache}"
LOCAL_SIGNING_OVERRIDES=(
  KLMS_IOS_DEVELOPMENT_TEAM=
  KLMS_IOS_BUNDLE_IDENTIFIER=com.local.KLMSync.iOS
)

"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null

mkdir -p "$SYMROOT" "$OBJROOT" "$DERIVED_DATA_PATH" "$MODULE_CACHE_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme KLMSiOS \
  -configuration Debug \
  -sdk "$SDK" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  "${LOCAL_SIGNING_OVERRIDES[@]}" \
  SYMROOT="$SYMROOT" \
  OBJROOT="$OBJROOT" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  build

print -r -- "$SYMROOT/Debug-iphonesimulator/KLMSiOS.app"
