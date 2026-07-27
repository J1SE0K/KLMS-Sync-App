import json
import subprocess
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


def observe_calendar_stage(dry_run: bool) -> tuple[int, int, int, list[str]]:
    bridge_path = PROJECT_DIR / "src" / "js" / "sync_calendar_bridge.js"
    script = f"""
const fs = require("fs");
let syncCalls = 0;
let hashBuildCalls = 0;
let hashWriteCalls = 0;
const stages = [];

function beginStage(_steps, _telemetry, name) {{
  stages.push(name);
}}
function debugStderr(_message) {{}}
function buildCalendarDesiredHash() {{
  hashBuildCalls += 1;
  return "next-hash";
}}
function fileExists() {{
  return true;
}}
function readText() {{
  return "previous-hash";
}}
function writeText() {{
  hashWriteCalls += 1;
}}

eval(fs.readFileSync({json.dumps(str(bridge_path))}, "utf8"));
const realSyncCalendarsFromState = syncCalendarsFromState;
syncCalendarsFromState = function () {{
  syncCalls += 1;
}};

runCalendarSyncStage({{
  status: {{ status: "ok", changed: true }},
  dryRun: {str(dry_run).lower()},
  enabled: true,
  skipUnchangedSideEffects: false,
  skipUnchangedDesired: false,
  outputState: "/tmp/state.json",
  scriptDir: "/tmp/project",
  config: {{}},
  calendarOptions: {{}},
  desiredHashPath: "/tmp/calendar-hash.txt",
  steps: [],
  stageTelemetry: {{}}
}});

syncCalendarsFromState = realSyncCalendarsFromState;
console.log(JSON.stringify({{
  syncCalls,
  hashBuildCalls,
  hashWriteCalls,
  stages
}}));
"""

    result = subprocess.run(
        ["node", "-e", script],
        check=True,
        capture_output=True,
        text=True,
        cwd=PROJECT_DIR,
    )
    observation = json.loads(result.stdout)
    return (
        observation["syncCalls"],
        observation["hashBuildCalls"],
        observation["hashWriteCalls"],
        observation["stages"],
    )


class CalendarDryRunBehaviorTests(unittest.TestCase):
    def test_dry_run_never_invokes_calendar_bridge_or_hash_writer(self) -> None:
        # Given a successful sync result with Calendar enabled,
        # when the Calendar stage runs in dry-run mode,
        # then neither external side effect is invoked.
        self.assertEqual(
            observe_calendar_stage(dry_run=True),
            (0, 0, 0, ["calendar-sync-dry-run"]),
        )

    def test_live_run_invokes_calendar_bridge_and_hash_writer_once(self) -> None:
        # Given the same successful result,
        # when the Calendar stage runs live,
        # then the bridge and desired-hash commit each run once.
        self.assertEqual(
            observe_calendar_stage(dry_run=False),
            (1, 1, 1, ["calendar-sync"]),
        )
