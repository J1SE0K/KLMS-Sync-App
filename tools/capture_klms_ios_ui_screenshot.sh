#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj"
DEVICE_IDENTIFIER="${IOS_DEVICE_IDENTIFIER:-${1:-}}"
RESULT_ROOT="${IOS_SCREENSHOT_RESULT_ROOT:-/private/tmp/klms-ios-ui-screenshots}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/klms-ios-ui-test-derived}"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-/private/tmp/klms-ios-ui-test-module-cache}"
TIME_STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_BUNDLE="$RESULT_ROOT/KLMSiOSUITests-$TIME_STAMP.xcresult"
ATTACHMENTS_DIR="$RESULT_ROOT/KLMSiOSUITests-$TIME_STAMP-attachments"
XCODEBUILD_PROVISIONING_ARGS=()
UI_TEST_METHOD="testCaptureMainScreen"

resolve_ios_bundle_identifier() {
  local config_file
  for config_file in \
    "$ROOT_DIR/apps/KLMSync/Config/KLMSiOS.local.xcconfig" \
    "$ROOT_DIR/apps/KLMSync/Config/KLMSiOS.defaults.xcconfig"; do
    if [[ -f "$config_file" ]]; then
      local value
      value="$(/usr/bin/awk -F '=' '/^[[:space:]]*KLMS_IOS_BUNDLE_IDENTIFIER[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$config_file")"
      if [[ -n "$value" ]]; then
        print -r -- "$value"
        return 0
      fi
    fi
  done
  print -r -- "com.local.KLMSync.iOS"
}

cleanup_uitest_runner() {
  if [[ "${KLMS_KEEP_UITEST_RUNNER:-0}" == "1" || -z "${DEVICE_IDENTIFIER:-}" ]]; then
    return 0
  fi

  local app_bundle_id="$1"
  local bundle_id
  for bundle_id in \
    "${app_bundle_id}.UITests.xctrunner" \
    "${app_bundle_id}.UITests"; do
    xcrun devicectl device uninstall app \
      --device "$DEVICE_IDENTIFIER" \
      "$bundle_id" \
      --quiet \
      --timeout 15 >/dev/null 2>&1 || true
  done
}

APP_BUNDLE_IDENTIFIER="$(resolve_ios_bundle_identifier)"

trap 'cleanup_uitest_runner "$APP_BUNDLE_IDENTIFIER"' EXIT

sanitize_xcodebuild_output() {
  KLMS_REPO_ROOT="$ROOT_DIR" /usr/bin/perl -pe '
    BEGIN {
      $repo_root = $ENV{"KLMS_REPO_ROOT"} // "";
      $home_dir = $ENV{"HOME"} // "";
    }
    if ($repo_root ne "") {
      s/\Q$repo_root\E/<repo-root>/g;
    }
    if ($home_dir ne "") {
      s/\Q$home_dir\E/<home>/g;
    }
    s#/Users/[^/\s"'\''"]+#<home>#g;
    s/Apple Development: [^"\n]+ \([A-Z0-9]{10}\)/Apple Development: <redacted>/g;
    s/Signing Identity:\s+".*"/Signing Identity: "<redacted>"/g;
    s/Provisioning Profile:\s+".*"/Provisioning Profile: "<redacted>"/g;
    s/[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\.mobileprovision/<provisioning-profile>.mobileprovision/g;
    s/\([A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\)/(<provisioning-profile-id>)/g;
    s/[A-Fa-f0-9]{40}/<signing-identity-hash>/g;
    s/[A-Z0-9]{10}\.com\.[A-Za-z0-9._-]+/<app-identifier>/g;
    s/\bcom\.[A-Za-z0-9._-]*KLMSync\.iOS(\.UITests|\.UITests\.xctrunner)?\b/<bundle-id>/g;
    s/\b[A-Z0-9]{10}\b/<team-id>/g;
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g;
  '
}

if [[ -z "$DEVICE_IDENTIFIER" ]]; then
  print -ru2 -- "Usage: IOS_DEVICE_IDENTIFIER=<device-id> $0"
  print -ru2 -- "Tip: list devices with: xcrun devicectl list devices"
  exit 2
fi

if [[ "${IOS_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  XCODEBUILD_PROVISIONING_ARGS=(-allowProvisioningUpdates)
fi

if [[ "${KLMS_UI_TEST_RUNNING_STATE:-0}" == "1" ]]; then
  UI_TEST_METHOD="testCaptureRunningMainScreen"
fi

"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null

mkdir -p "$RESULT_ROOT" "$DERIVED_DATA_PATH" "$MODULE_CACHE_DIR"

set +e
xcodebuild test \
  -project "$PROJECT_PATH" \
  -scheme KLMSiOS \
  -configuration Debug \
  -destination "id=$DEVICE_IDENTIFIER" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:KLMSiOSUITests/KLMSiOSUITests/"$UI_TEST_METHOD" \
  "${XCODEBUILD_PROVISIONING_ARGS[@]}" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" 2>&1 | sanitize_xcodebuild_output
xcodebuild_status=${pipestatus[1]}
set -e

if (( xcodebuild_status != 0 )); then
  print -ru2 -- "UI screenshot test failed. Result bundle, if created: $RESULT_BUNDLE"
  exit "$xcodebuild_status"
fi

cleanup_uitest_runner "$APP_BUNDLE_IDENTIFIER"

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$ATTACHMENTS_DIR" >/dev/null

FINAL_SCREENSHOT=""
if [[ -f "$ATTACHMENTS_DIR/manifest.json" ]] && /usr/bin/grep -q "klms-ipad" "$ATTACHMENTS_DIR/manifest.json"; then
  for png in "$ATTACHMENTS_DIR"/*.png(N); do
    width="$(/usr/bin/sips -g pixelWidth "$png" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2; exit }')"
    height="$(/usr/bin/sips -g pixelHeight "$png" 2>/dev/null | /usr/bin/awk '/pixelHeight/ { print $2; exit }')"
    if [[ -n "$width" && -n "$height" && "$height" -gt "$width" ]]; then
      FINAL_SCREENSHOT="$ATTACHMENTS_DIR/klms-ipad-landscape.png"
      /usr/bin/sips -r 90 "$png" --out "$FINAL_SCREENSHOT" >/dev/null
      break
    fi
  done
elif [[ -f "$ATTACHMENTS_DIR/manifest.json" ]] && /usr/bin/grep -q "klms-iphone" "$ATTACHMENTS_DIR/manifest.json"; then
  for png in "$ATTACHMENTS_DIR"/*.png(N); do
    FINAL_SCREENSHOT="$ATTACHMENTS_DIR/klms-iphone-portrait.png"
    /bin/cp "$png" "$FINAL_SCREENSHOT"
    break
  done
fi

print -r -- "$RESULT_BUNDLE"
print -r -- "$ATTACHMENTS_DIR"
if [[ -n "$FINAL_SCREENSHOT" ]]; then
  print -r -- "$FINAL_SCREENSHOT"
fi
