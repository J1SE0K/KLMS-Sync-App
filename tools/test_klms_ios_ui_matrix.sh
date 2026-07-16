#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj"
DERIVED_ROOT="${DERIVED_DATA_PATH:-/private/tmp/klms-ios-ui-matrix-derived}"
MODULE_CACHE_ROOT="${MODULE_CACHE_DIR:-/private/tmp/klms-ios-ui-matrix-module-cache}"
TEST_IDENTIFIERS=(
  "KLMSiOSUITests/KLMSiOSUITests/testAdaptiveLayoutPreservesSectionAcrossResize"
  "KLMSiOSUITests/KLMSiOSUITests/testAllMajorSectionsRemainReachableAndHorizontallyContained"
  "KLMSiOSUITests/KLMSiOSUITests/testWorkstationUsesVerticalFallbackAtNarrowWideBoundary"
  "KLMSiOSUITests/KLMSiOSUITests/testAX5KeepsSyncActionsAndCompactNavigationReachable"
  "KLMSiOSUITests/KLMSiOSUITests/testHistoryClearActionsStayCompactAndRequireConfirmation"
  "KLMSiOSUITests/KLMSiOSUITests/testLargeDatasetPerformanceLazySearchAndSelectionPreservation"
)

select_simulator() {
  local family="$1"
  local preferred_name="$2"
  SIMCTL_DEVICES_JSON="$(xcrun simctl list devices available -j)" \
    python3 - "$family" "$preferred_name" <<'PY'
import json
import os
import re
import sys

family = sys.argv[1].lower()
preferred = sys.argv[2].strip().lower()
payload = json.loads(os.environ["SIMCTL_DEVICES_JSON"])
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    version_match = re.search(r"iOS-(\d+)(?:-(\d+))?(?:-(\d+))?", runtime)
    version = tuple(int(part or 0) for part in (version_match.groups() if version_match else (0, 0, 0)))
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = str(device.get("name", ""))
        lowered = name.lower()
        if family == "iphone" and not lowered.startswith("iphone"):
            continue
        if family == "ipad" and not lowered.startswith("ipad"):
            continue
        exact = 1 if preferred and lowered == preferred else 0
        if family == "ipad":
            form_score = 3 if "13-inch" in lowered else 2 if "12.9-inch" in lowered else 1
        else:
            form_score = 3 if "pro max" in lowered else 2 if "pro" in lowered else 1
        candidates.append((exact, version, form_score, name, device.get("udid", "")))

if not candidates:
    raise SystemExit(f"no available {family} simulator")
candidates.sort(reverse=True)
selected = candidates[0]
print(f"{selected[4]}|{selected[3]}")
PY
}

run_ui_test() {
  local family="$1"
  local preferred_name="$2"
  local selection
  selection="$(select_simulator "$family" "$preferred_name")"
  local udid="${selection%%|*}"
  local name="${selection#*|}"
  local test_arguments=()
  local identifier
  for identifier in "${TEST_IDENTIFIERS[@]}"; do
    test_arguments+=("-only-testing:${identifier}")
  done

  print -r -- "Running KLMS iOS responsive/accessibility UI matrix on ${name} (${family})"
  if ! xcrun simctl shutdown "$udid" >/dev/null 2>&1; then
    :
  fi
  if ! xcrun simctl boot "$udid" >/dev/null 2>&1; then
    :
  fi
  xcrun simctl bootstatus "$udid" -b
  xcodebuild test \
    -quiet \
    -project "$PROJECT_PATH" \
    -scheme KLMSiOS \
    -configuration Debug \
    -destination "id=$udid" \
    -derivedDataPath "$DERIVED_ROOT/$family" \
    "${test_arguments[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_ROOT/$family"
}

"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null
mkdir -p "$DERIVED_ROOT" "$MODULE_CACHE_ROOT"

run_ui_test iphone "${KLMS_IOS_UI_IPHONE_NAME:-}"
run_ui_test ipad "${KLMS_IOS_UI_IPAD_NAME:-}"

print -r -- "KLMS iPhone/iPad adaptive UI matrix passed."
