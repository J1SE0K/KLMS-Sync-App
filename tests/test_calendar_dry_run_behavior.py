import json
import subprocess
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


def observe_calendar_command(config: dict[str, str]) -> list[str]:
    bridge_path = PROJECT_DIR / "src" / "js" / "sync_calendar_bridge.js"
    script = f"""
const fs = require("fs");
let observed = [];
function ensureDir() {{}}
function runCommand(command) {{ observed = command; return "calendar-summary"; }}
function writeCalendarSyncResult() {{}}
function readText() {{ return "calendar-summary"; }}
function removeFileIfExists() {{}}
eval(fs.readFileSync({json.dumps(str(bridge_path))}, "utf8"));
syncCalendarsFromState(
  "/tmp/state.json",
  "/tmp/project",
  {json.dumps(config)},
  {{ examEnabled: true, helpDeskEnabled: false, tmpDir: "/tmp/run" }}
);
console.log(JSON.stringify(observed));
"""
    result = subprocess.run(
        ["node", "-e", script],
        check=True,
        capture_output=True,
        text=True,
        cwd=PROJECT_DIR,
    )
    return json.loads(result.stdout)


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
    def test_signed_calendar_binary_replaces_interpreted_swift_command(self) -> None:
        command = observe_calendar_command(
            {"KLMS_CALENDAR_BIN_PATH": "/Applications/KLMSCalendarSync.app/Contents/MacOS/KLMSCalendarSync"}
        )

        self.assertEqual(
            command[0],
            "/Applications/KLMSCalendarSync.app/Contents/MacOS/KLMSCalendarSync",
        )
        self.assertNotIn("/usr/bin/swift", command)
        self.assertIn("/tmp/state.json", command)

    def test_signed_calendar_app_uses_launch_services_and_result_file(self) -> None:
        command = observe_calendar_command(
            {"KLMS_CALENDAR_APP_PATH": "/Applications/KLMSCalendarSync.app"}
        )

        self.assertEqual(
            command[:5],
            [
                "/usr/bin/open",
                "-W",
                "-g",
                "/Applications/KLMSCalendarSync.app",
                "--args",
            ],
        )
        self.assertIn("/tmp/state.json", command)
        self.assertTrue(any(item.startswith("--result-output=") for item in command))

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
