#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj"
SDK="${IOS_SIMULATOR_SDK:-iphonesimulator}"
SYMROOT="${SYMROOT:-/private/tmp/klms-ios-build}"
OBJROOT="${OBJROOT:-/private/tmp/klms-ios-obj}"

"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null

xcodebuild \
  -project "$PROJECT_PATH" \
  -target KLMSiOS \
  -configuration Debug \
  -sdk "$SDK" \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$SYMROOT" \
  OBJROOT="$OBJROOT" \
  build

print -r -- "$SYMROOT/Debug-iphonesimulator/KLMSiOS.app"
