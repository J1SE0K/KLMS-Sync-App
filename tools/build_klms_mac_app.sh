#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PACKAGE_DIR="$ROOT_DIR/apps/KLMSync"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="${APP_NAME:-KLMS Sync}"
BUNDLE_ID="${BUNDLE_ID:-com.local.KLMSync}"
APP_ICON_SOURCE="$APP_PACKAGE_DIR/Resources/AppIcon.icns"
PAYLOAD_ALLOWLIST="$APP_PACKAGE_DIR/EnginePayloadAllowlist.txt"
ENABLE_CLOUDKIT_ENTITLEMENT="${ENABLE_CLOUDKIT_ENTITLEMENT:-0}"
ICLOUD_CONTAINER_IDENTIFIER="${ICLOUD_CONTAINER_IDENTIFIER:-}"
# Keep the default outside Documents/iCloud-backed workspaces. Those locations can
# attach File Provider metadata to .app directories and make codesign reject them.
DIST_DIR="${DIST_DIR:-$HOME/Applications}"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-/private/tmp/klmsync-swiftpm-app-build}"
TARGET_APP_BUNDLE="${OUTPUT_APP:-$DIST_DIR/$APP_NAME.app}"
TARGET_APP_PARENT="$(dirname "$TARGET_APP_BUNDLE")"
TARGET_APP_NAME="$(basename "$TARGET_APP_BUNDLE")"

mkdir -p "$TARGET_APP_PARENT"
STAGING_DIR="$(mktemp -d "$TARGET_APP_PARENT/.klms-sync-app-build.XXXXXX")"
APP_BUNDLE="$STAGING_DIR/$TARGET_APP_NAME"
BACKUP_APP_BUNDLE="$STAGING_DIR/previous.app"
target_app_moved=0

restore_previous_app() {
  if (( target_app_moved == 1 )) && [[ -e "$BACKUP_APP_BUNDLE" || -L "$BACKUP_APP_BUNDLE" ]]; then
    if [[ ! -e "$TARGET_APP_BUNDLE" && ! -L "$TARGET_APP_BUNDLE" ]]; then
      mv "$BACKUP_APP_BUNDLE" "$TARGET_APP_BUNDLE"
    else
      print -u2 -- "Unable to restore the previous app because the target path is occupied: $TARGET_APP_BUNDLE"
      return 1
    fi
    target_app_moved=0
  fi
}

cleanup_build() {
  local exit_status=$?
  trap - EXIT
  if (( exit_status != 0 )); then
    if ! restore_previous_app; then
      print -u2 -- "Previous app preserved at: $BACKUP_APP_BUNDLE"
      exit "$exit_status"
    fi
  fi
  rm -rf "$STAGING_DIR"
  exit "$exit_status"
}

trap cleanup_build EXIT

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

if [[ ! -f "$PAYLOAD_ALLOWLIST" ]]; then
  print -r -- "missing engine payload allowlist: $PAYLOAD_ALLOWLIST" >&2
  exit 1
fi
while IFS= read -r relative_path || [[ -n "$relative_path" ]]; do
  [[ -n "$relative_path" ]] || continue
  case "$relative_path" in
    /*|../*|*/../*|*/..|*//* )
      print -r -- "invalid engine payload allowlist path: $relative_path" >&2
      exit 1
      ;;
  esac
  source_path="$ROOT_DIR/$relative_path"
  if [[ ! -f "$source_path" || -L "$source_path" ]]; then
    print -r -- "missing or non-regular engine payload file: $relative_path" >&2
    exit 1
  fi
  mkdir -p "$PAYLOAD_ROOT/${relative_path:h}"
  cp -X "$source_path" "$PAYLOAD_ROOT/$relative_path"
done < "$PAYLOAD_ALLOWLIST"

VENDORED_PYTHON_PACKAGES="$ROOT_DIR/vendor/python-packages"
if [[ ! -d "$VENDORED_PYTHON_PACKAGES/bs4" || ! -d "$VENDORED_PYTHON_PACKAGES/soupsieve" ]]; then
  print -r -- "missing tracked Python runtime packages: $VENDORED_PYTHON_PACKAGES" >&2
  exit 1
fi
ditto --norsrc "$VENDORED_PYTHON_PACKAGES" "$PAYLOAD_ROOT/python-packages"

find "$PAYLOAD_ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$PAYLOAD_ROOT" -name '*.pyc' -type f -delete
find "$PAYLOAD_ROOT" -name '.DS_Store' -type f -delete

find "$PAYLOAD_ROOT" -type f \
  \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' \) \
  -exec chmod +x {} +

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$git_head" ]]; then
    if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]]; then
      dirty_suffix="-dirty-$(date +%Y%m%d%H%M%S)"
      payload_dirty="true"
    else
      dirty_suffix=""
      payload_dirty="false"
    fi
    payload_version="$git_head$dirty_suffix"
    source_revision="$git_head"
  else
    payload_version="local-$(date +%Y%m%d%H%M%S)"
    source_revision="$payload_version"
    payload_dirty="true"
  fi
else
  payload_version="local-$(date +%Y%m%d%H%M%S)"
  source_revision="$payload_version"
  payload_dirty="true"
fi
print -r -- "$payload_version" > "$PAYLOAD_ROOT/EnginePayloadVersion.txt"

python3 - "$PAYLOAD_ROOT" "$PAYLOAD_ALLOWLIST" "$payload_version" "$source_revision" "$payload_dirty" <<'PY'
import hashlib
import json
import pathlib
import sys

payload_root = pathlib.Path(sys.argv[1]).resolve()
allowlist_path = pathlib.Path(sys.argv[2]).resolve()
payload_version = sys.argv[3]
source_revision = sys.argv[4]
dirty = sys.argv[5] == "true"
manifest_path = payload_root / "EnginePayloadManifest.json"

files = []
for candidate in sorted(payload_root.rglob("*")):
    if candidate == manifest_path:
        continue
    if candidate.is_symlink():
        raise SystemExit(f"engine payload must not contain symlinks: {candidate}")
    if not candidate.is_file():
        continue
    relative = candidate.relative_to(payload_root).as_posix()
    data = candidate.read_bytes()
    files.append({
        "path": relative,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    })

manifest = {
    "schemaVersion": 1,
    "payloadVersion": payload_version,
    "sourceRevision": source_revision,
    "dirty": dirty,
    "allowlistSHA256": hashlib.sha256(allowlist_path.read_bytes()).hexdigest(),
    "fileCount": len(files),
    "totalBytes": sum(item["bytes"] for item in files),
    "files": files,
}
manifest_path.write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

payload_verify_args=(
  "$ROOT_DIR/tools/verify_klms_engine_payload.py"
  "$PAYLOAD_ROOT"
  --allowlist "$PAYLOAD_ALLOWLIST"
  --expected-revision "$source_revision"
)
if [[ "${KLMS_PAYLOAD_REQUIRE_CLEAN:-0}" == "1" ]]; then
  payload_verify_args+=(--require-clean)
fi
python3 "${payload_verify_args[@]}"

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
    print -u2 -- "Signing KLMS Sync.app with identity: configured local identity."
  fi
  if [[ "$ENABLE_CLOUDKIT_ENTITLEMENT" == "1" ]]; then
    print -u2 -- "CloudKit container entitlement: enabled"
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
    fi
  fi
  if ! /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null 2>&1; then
    print -u2 -- "Built app failed code-signature verification; the installed app was not replaced."
    exit 1
  fi
fi

if [[ -e "$TARGET_APP_BUNDLE" || -L "$TARGET_APP_BUNDLE" ]]; then
  mv "$TARGET_APP_BUNDLE" "$BACKUP_APP_BUNDLE"
  target_app_moved=1
fi

if ! mv "$APP_BUNDLE" "$TARGET_APP_BUNDLE"; then
  print -u2 -- "Unable to install the newly built app; restoring the previous app."
  restore_previous_app
  exit 1
fi
target_app_moved=0

trap - EXIT
rm -rf "$STAGING_DIR"
print -r -- "$TARGET_APP_BUNDLE"
