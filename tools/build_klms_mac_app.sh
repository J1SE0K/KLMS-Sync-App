#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PACKAGE_DIR="$ROOT_DIR/apps/KLMSync"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="${APP_NAME:-KLMS Sync}"
BUNDLE_ID="${BUNDLE_ID:-com.local.KLMSync}"
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
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp -X "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/KLMSMac"
chmod +x "$APP_BUNDLE/Contents/MacOS/KLMSMac"
ditto --norsrc "$RESOURCE_BUNDLE_SOURCE" "$APP_BUNDLE/Contents/Resources/KLMSync_KLMSMac.bundle"

PAYLOAD_ROOT="$APP_BUNDLE/Contents/Resources/EnginePayload"
rm -rf "$PAYLOAD_ROOT"
mkdir -p "$PAYLOAD_ROOT"

for directory in src bin examples docs legacy; do
  if [[ -d "$ROOT_DIR/$directory" ]]; then
    ditto --norsrc "$ROOT_DIR/$directory" "$PAYLOAD_ROOT/$directory"
  fi
done

root_files=(
  kaikey_auto_login.sh
  kaikey_approve_number.sh
  kaikey_setup.sh
  sync_klms_core.sh
  sync_klms_notice.sh
  sync_klms_all.sh
  run_all.sh
  run_all_full.sh
  run_all_parallel.sh
  refresh_course_files.sh
  verify_sync_state.sh
  doctor.sh
  sync_report.sh
  process_klms_assignments.sh
  klms_v2_build_state.sh
  install_launch_agent.sh
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
  git_head="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    dirty_suffix="-dirty-$(date +%Y%m%d%H%M%S)"
  else
    dirty_suffix=""
  fi
  payload_version="$git_head$dirty_suffix"
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
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>KLMS Sync가 Safari, Notes, Calendar, Reminders를 사용해 개인 KLMS 동기화를 실행합니다.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>KLMS 시험과 헬프데스크 일정을 Calendar에 동기화합니다.</string>
  <key>NSRemindersUsageDescription</key>
  <string>KLMS 과제 알림을 Reminders에 동기화합니다.</string>
</dict>
</plist>
EOF

codesign_identity="${CODE_SIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
    while IFS= read -r bundle_path; do
      xattr -d com.apple.provenance "$bundle_path" >/dev/null 2>&1 || true
      xattr -c "$bundle_path" >/dev/null 2>&1 || true
    done < <(find "$APP_BUNDLE" -print)
  fi
  /usr/bin/codesign --force --deep --sign "$codesign_identity" "$APP_BUNDLE" >/dev/null
fi

print -r -- "$APP_BUNDLE"
