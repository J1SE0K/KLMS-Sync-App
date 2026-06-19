#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PACKAGE_DIR="$ROOT_DIR/apps/KLMSync"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="${APP_NAME:-KLMS Sync}"
BUNDLE_ID="${BUNDLE_ID:-com.local.KLMSync}"
APP_ICON_SOURCE="$APP_PACKAGE_DIR/Resources/AppIcon.icns"
ENABLE_CLOUDKIT_ENTITLEMENT="${ENABLE_CLOUDKIT_ENTITLEMENT:-0}"
ICLOUD_CONTAINER_IDENTIFIER="${ICLOUD_CONTAINER_IDENTIFIER:-}"
# Keep the default outside Documents/iCloud-backed workspaces. Those locations can
# attach File Provider metadata to .app directories and make codesign reject them.
DIST_DIR="${DIST_DIR:-$HOME/Applications}"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-/private/tmp/klmsync-swiftpm-app-build}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

mkdir -p "$DIST_DIR"

swift build \
  --package-path "$APP_PACKAGE_DIR" \
  --scratch-path "$SWIFT_SCRATCH_PATH" \
  -c "$CONFIGURATION" \
  --product KLMSMac

BIN_DIR="$(swift build --package-path "$APP_PACKAGE_DIR" --scratch-path "$SWIFT_SCRATCH_PATH" -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_DIR/KLMSMac"
RESOURCE_BUNDLE_SOURCE="$BIN_DIR/KLMSync_KLMSMac.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
  print -u2 -- "Missing KLMSMac executable: $EXECUTABLE"
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_SOURCE" ]]; then
  print -u2 -- "Missing KLMSMac resource bundle: $RESOURCE_BUNDLE_SOURCE"
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Helpers"

cp -X "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/KLMSMac"
chmod +x "$APP_BUNDLE/Contents/MacOS/KLMSMac"
ditto --norsrc "$RESOURCE_BUNDLE_SOURCE" "$APP_BUNDLE/Contents/Resources/KLMSync_KLMSMac.bundle"
if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp -X "$APP_ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

HELPER_BUNDLE_ID="${BUNDLE_ID}.notice-native-note"
NATIVE_NOTICE_HELPER_APP="$APP_BUNDLE/Contents/Helpers/KLMSNoticeNativeNote.app"
NATIVE_NOTICE_HELPER="$NATIVE_NOTICE_HELPER_APP/Contents/MacOS/KLMSNoticeNativeNote"
mkdir -p "$NATIVE_NOTICE_HELPER_APP/Contents/MacOS" "$NATIVE_NOTICE_HELPER_APP/Contents/Resources"
if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp -X "$APP_ICON_SOURCE" "$NATIVE_NOTICE_HELPER_APP/Contents/Resources/AppIcon.icns"
fi
HELPER_INFO_PLIST="$NATIVE_NOTICE_HELPER_APP/Contents/Info.plist"
cat > "$HELPER_INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleExecutable</key>
  <string>KLMSNoticeNativeNote</string>
  <key>CFBundleIdentifier</key>
  <string>$HELPER_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>KLMS Notice Renderer</string>
  <key>CFBundleDisplayName</key>
  <string>KLMS 공지 메모 렌더러</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>KLMS Sync가 Notes와 System Events를 사용해 공지 메모의 체크리스트와 문단 형식을 갱신합니다.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>KLMS Sync가 Notes 편집 영역을 확인하고 공지 메모의 체크리스트와 문단 형식을 적용합니다.</string>
</dict>
</plist>
EOF
HELPER_EXECUTABLE_INFO_PLIST="$SWIFT_SCRATCH_PATH/KLMSNoticeNativeNote-Executable-Info.plist"
cp "$HELPER_INFO_PLIST" "$HELPER_EXECUTABLE_INFO_PLIST"
helper_info_plist_args=(
  -Xlinker -sectcreate
  -Xlinker __TEXT
  -Xlinker __info_plist
  -Xlinker "$HELPER_EXECUTABLE_INFO_PLIST"
)
if [[ -x "/usr/bin/xcrun" ]]; then
  /usr/bin/xcrun --sdk macosx swiftc \
    "$ROOT_DIR/src/swift/notice_native_note_support.swift" \
    "$ROOT_DIR/src/swift/update_notice_native_note.swift" \
    "${helper_info_plist_args[@]}" \
    -o "$NATIVE_NOTICE_HELPER"
else
  swiftc \
    "$ROOT_DIR/src/swift/notice_native_note_support.swift" \
    "$ROOT_DIR/src/swift/update_notice_native_note.swift" \
    "${helper_info_plist_args[@]}" \
    -o "$NATIVE_NOTICE_HELPER"
fi
chmod +x "$NATIVE_NOTICE_HELPER"

PAYLOAD_ROOT="$APP_BUNDLE/Contents/Resources/EnginePayload"
rm -rf "$PAYLOAD_ROOT"
mkdir -p "$PAYLOAD_ROOT"

for directory in src bin examples docs tools; do
  if [[ -d "$ROOT_DIR/$directory" ]]; then
    ditto --norsrc "$ROOT_DIR/$directory" "$PAYLOAD_ROOT/$directory"
  fi
done
if [[ -d "$ROOT_DIR/runtime/python-packages" ]]; then
  ditto --norsrc "$ROOT_DIR/runtime/python-packages" "$PAYLOAD_ROOT/python-packages"
fi

root_files=(
  kaikey_auto_login.sh
  kaikey_approve_number.sh
  kaikey_setup.sh
  sync_klms_core.sh
  sync_klms_notice.sh
  sync_klms_all.sh
  run_all.sh
  run_all_full.sh
  refresh_course_files.sh
  verify_sync_state.sh
  doctor.sh
  sync_report.sh
  process_klms_assignments.sh
  klms_v2_build_state.sh
  manual_assignment_overrides.json
  README.md
  LICENSE
  SECURITY.md
  THIRD_PARTY_NOTICES.md
)

for file in "${root_files[@]}"; do
  if [[ -f "$ROOT_DIR/$file" ]]; then
    mkdir -p "$PAYLOAD_ROOT/${file:h}"
    cp -X "$ROOT_DIR/$file" "$PAYLOAD_ROOT/$file"
  fi
done

find "$PAYLOAD_ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$PAYLOAD_ROOT" -name '*.pyc' -type f -delete
find "$PAYLOAD_ROOT" -name '.DS_Store' -type f -delete

find "$PAYLOAD_ROOT" -type f \
  \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' \) \
  -exec chmod +x {} +

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_head="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -n "$git_head" ]]; then
    if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]]; then
      dirty_suffix="-dirty-$(date +%Y%m%d%H%M%S)"
    else
      dirty_suffix=""
    fi
    payload_version="$git_head$dirty_suffix"
  else
    payload_version="local-$(date +%Y%m%d%H%M%S)"
  fi
else
  payload_version="local-$(date +%Y%m%d%H%M%S)"
fi
print -r -- "$payload_version" > "$PAYLOAD_ROOT/EnginePayloadVersion.txt"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleExecutable</key>
  <string>KLMSMac</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
  <key>NSAppleEventsUsageDescription</key>
  <string>KLMS Sync가 Safari, Notes, System Events, Calendar, Reminders를 사용해 개인 KLMS 동기화를 실행합니다.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>KLMS Sync가 Notes 편집 영역을 확인하고 공지 메모의 체크리스트와 문단 형식을 적용합니다.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>KLMS 시험과 헬프데스크 일정을 Calendar에 동기화합니다.</string>
  <key>NSRemindersUsageDescription</key>
  <string>KLMS 과제 알림을 Reminders에 동기화합니다.</string>
</dict>
</plist>
EOF

requested_codesign_identity="${CODE_SIGN_IDENTITY:-}"
codesign_identity="$requested_codesign_identity"
if [[ -z "$codesign_identity" ]] && command -v security >/dev/null 2>&1; then
  codesign_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/[A-F0-9]{40}/ { print $2; exit }'
  )"
fi
codesign_identity="${codesign_identity:-"-"}"
if command -v codesign >/dev/null 2>&1; then
  app_codesign_args=(--force --sign "$codesign_identity")
  if [[ "$ENABLE_CLOUDKIT_ENTITLEMENT" == "1" ]]; then
    ICLOUD_CONTAINER_IDENTIFIER="${ICLOUD_CONTAINER_IDENTIFIER:-iCloud.$BUNDLE_ID}"
    APP_ENTITLEMENTS="$SWIFT_SCRATCH_PATH/KLMSync.entitlements"
    cat > "$APP_ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>$ICLOUD_CONTAINER_IDENTIFIER</string>
  </array>
  <key>com.apple.developer.icloud-services</key>
  <array>
    <string>CloudKit</string>
  </array>
</dict>
</plist>
EOF
    app_codesign_args+=(--entitlements "$APP_ENTITLEMENTS")
  fi
  if [[ "$codesign_identity" == "-" ]]; then
    print -u2 -- "warning: KLMS Sync.app is being ad-hoc signed."
    print -u2 -- "warning: macOS may invalidate Automation/Accessibility permissions after each rebuild."
    print -u2 -- "warning: set CODE_SIGN_IDENTITY to a stable local code-signing identity to keep permissions stable."
  else
    print -u2 -- "Signing KLMS Sync.app with identity: $codesign_identity"
  fi
  if [[ "$ENABLE_CLOUDKIT_ENTITLEMENT" == "1" ]]; then
    print -u2 -- "CloudKit container entitlement: $ICLOUD_CONTAINER_IDENTIFIER"
  else
    print -u2 -- "CloudKit container entitlement: disabled (set ENABLE_CLOUDKIT_ENTITLEMENT=1 after provisioning)"
  fi
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
    while IFS= read -r bundle_path; do
      xattr -d com.apple.provenance "$bundle_path" >/dev/null 2>&1 || true
      xattr -c "$bundle_path" >/dev/null 2>&1 || true
    done < <(find "$APP_BUNDLE" -print)
  fi
  /usr/bin/codesign --force --sign "$codesign_identity" "$NATIVE_NOTICE_HELPER_APP" >/dev/null
  /usr/bin/codesign "${app_codesign_args[@]}" "$APP_BUNDLE" >/dev/null
  if ! /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null 2>&1; then
    if [[ "$codesign_identity" != "-" ]]; then
      print -u2 -- "warning: selected signing identity did not pass verification; falling back to ad-hoc signing."
      codesign_identity="-"
      app_codesign_args=(--force --sign "$codesign_identity")
      if [[ "$ENABLE_CLOUDKIT_ENTITLEMENT" == "1" ]]; then
        app_codesign_args+=(--entitlements "$APP_ENTITLEMENTS")
      fi
      /usr/bin/codesign --force --sign "$codesign_identity" "$NATIVE_NOTICE_HELPER_APP" >/dev/null
      /usr/bin/codesign "${app_codesign_args[@]}" "$APP_BUNDLE" >/dev/null
    else
      print -u2 -- "warning: ad-hoc signed app did not pass codesign verification."
    fi
  fi
fi

print -r -- "$APP_BUNDLE"
