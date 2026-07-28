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
  "KLMSiOSUITests/KLMSiOSUITests/testNavigationStagesAtExactAdaptiveBoundaries"
  "KLMSiOSUITests/KLMSiOSUITests/testCompactNavigationReservesScrollableViewport"
  "KLMSiOSUITests/KLMSiOSUITests/testKoreanGuidanceKeepsCompleteClausesContained"
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
  local result_bundle="$DERIVED_ROOT/$family/KLMSiOSUITests.xcresult"
  local result_json="$DERIVED_ROOT/$family/test-results.json"
  local summary_json="$DERIVED_ROOT/$family/test-summary.json"
  local raw_attachments="$DERIVED_ROOT/$family/attachments-raw"
  local visual_evidence="$DERIVED_ROOT/$family/visual-evidence"
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
  if [[ -e "$result_bundle" ]]; then
    find "$result_bundle" -depth -delete
  fi
  xcodebuild test \
    -quiet \
    -project "$PROJECT_PATH" \
    -scheme KLMSiOS \
    -configuration Debug \
    -destination "id=$udid" \
    -derivedDataPath "$DERIVED_ROOT/$family" \
    -resultBundlePath "$result_bundle" \
    "${test_arguments[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_ROOT/$family"
  xcrun xcresulttool get test-results tests --path "$result_bundle" > "$result_json"
  chmod 600 "$result_json"
  python3 - "$family" "$result_json" "$summary_json" "${TEST_IDENTIFIERS[@]}" <<'PY'
import json
import sys
from pathlib import Path

family = sys.argv[1]
result_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
expected = [value.rsplit("/", 1)[-1] for value in sys.argv[4:]]
allowed_skips = {
    "iphone": {
        "testWorkstationUsesVerticalFallbackAtNarrowWideBoundary",
        "testCompactNavigationReservesScrollableViewport",
    },
    "ipad": {
        "testKoreanGuidanceKeepsCompleteClausesContained",
        "testHistoryClearActionsStayCompactAndRequireConfirmation",
    },
}
warnings = []
cases = {}

def visit(value):
    if isinstance(value, dict):
        if value.get("nodeType") == "Runtime Warning":
            warnings.append(str(value.get("name") or "unknown runtime warning"))
        if value.get("nodeType") == "Test Case":
            name = str(value.get("name") or "").removesuffix("()")
            cases.setdefault(name, []).append(str(value.get("result") or "Unknown"))
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(json.loads(result_path.read_text(encoding="utf-8")))
if warnings:
    for warning in warnings:
        print(f"iOS UI runtime warning: {warning}", file=sys.stderr)
    raise SystemExit(1)
if set(cases) != set(expected):
    missing = sorted(set(expected) - set(cases))
    extra = sorted(set(cases) - set(expected))
    raise SystemExit(f"{family} iOS UI test inventory mismatch: missing={missing} extra={extra}")
if any(len(results) != 1 for results in cases.values()):
    raise SystemExit(f"{family} iOS UI test inventory contains duplicate executions")
results = {name: values[0] for name, values in cases.items()}
unexpected = {name: result for name, result in results.items() if result not in {"Passed", "Skipped"}}
if unexpected:
    raise SystemExit(f"{family} iOS UI tests did not pass: {unexpected}")
skipped = {name for name, result in results.items() if result == "Skipped"}
if skipped != allowed_skips[family]:
    raise SystemExit(
        f"{family} iOS UI skip contract changed: expected={sorted(allowed_skips[family])} actual={sorted(skipped)}"
    )
summary_path.write_text(
    json.dumps({"family": family, "results": results}, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
summary_path.chmod(0o600)
PY

  for directory in "$raw_attachments" "$visual_evidence"; do
    if [[ -e "$directory" ]]; then
      find "$directory" -depth -delete
    fi
  done
  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$raw_attachments" >/dev/null
  python3 "$ROOT_DIR/tools/normalize_klms_ios_visual_evidence.py" \
    --family "$family" \
    --source-dir "$raw_attachments" \
    --output-dir "$visual_evidence" \
    --candidate "$(git -C "$ROOT_DIR" rev-parse --verify HEAD^{commit})"
}

"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null
mkdir -p "$DERIVED_ROOT" "$MODULE_CACHE_ROOT"

run_ui_test iphone "${KLMS_IOS_UI_IPHONE_NAME:-}"
run_ui_test ipad "${KLMS_IOS_UI_IPAD_NAME:-}"

python3 - "$DERIVED_ROOT/iphone/test-summary.json" "$DERIVED_ROOT/ipad/test-summary.json" "${TEST_IDENTIFIERS[@]}" <<'PY'
import json
import sys
from pathlib import Path

summaries = [json.loads(Path(value).read_text(encoding="utf-8")) for value in sys.argv[1:3]]
expected = [value.rsplit("/", 1)[-1] for value in sys.argv[3:]]
uncovered = [
    name
    for name in expected
    if not any(summary["results"].get(name) == "Passed" for summary in summaries)
]
if uncovered:
    raise SystemExit(f"iPhone/iPad complementary UI coverage is incomplete: {uncovered}")
passed = sum(result == "Passed" for summary in summaries for result in summary["results"].values())
skipped = sum(result == "Skipped" for summary in summaries for result in summary["results"].values())
print(
    f"KLMS iOS UI aggregate: scenarios={len(expected)} covered={len(expected)} "
    f"device_passes={passed} complementary_skips={skipped} runtime_warnings=0"
)
PY

print -r -- "KLMS iPhone/iPad adaptive UI matrix passed."
