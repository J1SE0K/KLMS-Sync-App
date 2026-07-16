import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
PYTHON_SUBPROCESS_ENV = {
    "PYTHONPATH": os.pathsep.join(
        (
            str(PROJECT_DIR / "src" / "python"),
            str(PROJECT_DIR / "vendor" / "python-packages"),
        )
    )
}


def extract_function(text: str, name: str) -> str:
    marker = f"function {name}("
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise AssertionError(f"Could not extract {name}")


class CoreSyncSafetyTests(unittest.TestCase):
    def test_empty_authenticated_course_list_fails_closed_before_state_changes(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            extract_function(source, name)
            for name in ("uniqueStrings", "assertNonEmptyCourseUrlSet")
        )
        script = f"""
{helpers}
function rejected(urls) {{
  try {{
    assertNonEmptyCourseUrlSet(urls);
    return false;
  }} catch (_error) {{
    return true;
  }}
}}
console.log(JSON.stringify({{
  empty: rejected([]),
  whitespace: rejected(["", "   "]),
  valid: rejected(["https://klms.kaist.ac.kr/course/view.php?id=1"])
}}));
"""
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
            cwd=PROJECT_DIR,
        )

        self.assertEqual(
            json.loads(result.stdout),
            {"empty": True, "whitespace": True, "valid": False},
        )
        gate_index = source.index("assertNonEmptyCourseUrlSet(courseUrls)")
        course_fetch_index = source.index(
            'beginStage(steps, stageTelemetry, "course-fetch")'
        )
        reminder_import_index = source.index(
            'beginStage(steps, stageTelemetry, "completed-reminders-import")'
        )
        self.assertLess(gate_index, course_fetch_index)
        self.assertLess(gate_index, reminder_import_index)

    def test_all_week_course_pages_use_independent_verification_urls(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            extract_function(source, name)
            for name in ("toAllWeekCourseUrl", "toAllWeekCourseVerificationUrl")
        )
        script = f"""
{helpers}
const sourceUrl = "https://klms.kaist.ac.kr/course/view.php?id=42";
console.log(JSON.stringify({{
  primary: toAllWeekCourseUrl(sourceUrl),
  verification: toAllWeekCourseVerificationUrl(sourceUrl),
  invalid: toAllWeekCourseVerificationUrl("https://klms.kaist.ac.kr/course/view.php")
}}));
"""
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
            cwd=PROJECT_DIR,
        )

        self.assertEqual(
            json.loads(result.stdout),
            {
                "primary": "https://klms.kaist.ac.kr/course/view.php?id=42&section=0",
                "verification": "https://klms.kaist.ac.kr/course/view.php?id=42&section=0&klms_sync_verify=1",
                "invalid": "",
            },
        )
        self.assertIn("courseUrls.flatMap((url) => [", source)
        self.assertIn("toAllWeekCourseVerificationUrl(url)", source)
        self.assertIn('alwaysFetchPatterns: ["klms_sync_verify=1"]', source)
        self.assertIn("completeReuseSeconds: 0", source)
        self.assertIn("destructiveChangePrimaryStaleSeconds", source)

    def test_authoritative_coverage_rejects_missing_empty_and_login_pages(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            extract_function(source, name)
            for name in (
                "uniqueStrings",
                "looksLikeLoginPage",
                "assertNoLoginPages",
                "assertAuthoritativePageCoverage",
            )
        )
        script = f"""
{helpers}
const urls = ["https://klms.kaist.ac.kr/a", "https://klms.kaist.ac.kr/b"];
const valid = urls.map((requestedUrl) => ({{ requestedUrl, url: requestedUrl, html: "<main>ok</main>" }}));
function rejected(pages) {{
  try {{
    assertAuthoritativePageCoverage("test", pages, urls);
    return false;
  }} catch (_error) {{
    return true;
  }}
}}
assertAuthoritativePageCoverage("test", valid, urls);
console.log(JSON.stringify({{
  missing: rejected(valid.slice(0, 1)),
  wrongRequestedUrl: rejected([valid[0], {{ requestedUrl: "https://klms.kaist.ac.kr/other", html: "ok" }}]),
  empty: rejected([valid[0], {{ requestedUrl: urls[1], html: "" }}]),
  login: rejected([valid[0], {{ requestedUrl: urls[1], url: "https://klms.kaist.ac.kr/login/index.php", html: '<input name="username">' }}])
}}));
"""
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
            cwd=PROJECT_DIR,
        )

        self.assertEqual(
            json.loads(result.stdout),
            {"missing": True, "wrongRequestedUrl": True, "empty": True, "login": True},
        )

    def test_all_state_fetch_groups_require_complete_coverage(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        compact_source = "".join(source.split())
        contexts = [
            "sync-dashboard",
            "sync-course-pages",
            "sync-all-week-course-pages",
            "sync-supplemental-primary-pages",
            "sync-supplemental-secondary-pages",
            "sync-detail-pages",
            "sync-supplemental-detail-pages",
        ]
        for context in contexts:
            with self.subTest(context=context):
                start = source.index(f'context: "{context}"')
                block = source[start : start + 900]
                self.assertIn("requireAll: true", block)
                self.assertIn(
                    f'assertAuthoritativePageCoverage("{context}"',
                    compact_source,
                )

        fetch_pages = extract_function(source, "fetchPages")
        self.assertIn("const requireAll = !options || options.requireAll !== false", fetch_pages)
        self.assertIn('command.push("--require-all")', fetch_pages)
        self.assertIn("assertAuthoritativePageCoverage(context, pages, urls)", fetch_pages)

    def test_dry_run_cannot_reach_calendar_or_reminder_side_effects(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        calendar_block = source[
            source.index('if (\n      status.status === "ok" &&\n      !dryRun') :
            source.index('if (status.status === "ok" && remindersEnabled && !dryRun)')
        ]
        self.assertIn("syncCalendarsFromState", calendar_block)
        self.assertIn("writeText(calendarDesiredHashTxt", calendar_block)
        self.assertIn('beginStage(steps, stageTelemetry, "calendar-sync-dry-run")', source)
        self.assertIn("const noticeScopeSnapshot = snapshotFiles", source)
        self.assertIn("if (dryRun || !noticeScopeSucceeded)", source)
        self.assertIn("restoreFileSnapshot(noticeScopeSnapshot)", source)
        self.assertIn("const boardArticleStatePendingJson = dryRun", source)
        self.assertIn("const outputState = dryRun", source)
        self.assertIn("const outputStatus = dryRun", source)
        self.assertIn("if (!dryRun && fileExists(boardArticleStatePendingJson))", source)
        final_notice_block = source[
            source.index('status.status === "ok" &&\n      !dryRun &&\n      noticeSummaryEnabled') :
            source.index("completeStageTelemetry(stageTelemetry", source.index('status.status === "ok" &&\n      !dryRun &&\n      noticeSummaryEnabled'))
        ]
        self.assertIn("syncNoticeSummary", final_notice_block)

        coverage_index = source.index(
            'assertAuthoritativePageCoverage(\n      "sync-supplemental-detail-pages"'
        )
        reminder_import_index = source.index(
            'beginStage(steps, stageTelemetry, "completed-reminders-import")'
        )
        self.assertLess(coverage_index, reminder_import_index)

    def test_authoritative_build_preflight_precedes_reminders_and_uses_pending_override(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        preflight_index = source.index(
            'beginStage(steps, stageTelemetry, "authoritative-build-preflight")'
        )
        import_index = source.index(
            'beginStage(steps, stageTelemetry, "completed-reminders-import")'
        )
        build_index = source.index(
            'beginStage(steps, stageTelemetry, "build-note")', import_index
        )
        status_index = source.index(
            'beginStage(steps, stageTelemetry, "status")', build_index
        )
        commit_index = source.index(
            'beginStage(steps, stageTelemetry, "completed-reminders-override-commit")'
        )
        calendar_index = source.index("syncCalendarsFromState", status_index)

        self.assertLess(preflight_index, import_index)
        self.assertLess(import_index, build_index)
        self.assertLess(status_index, commit_index)
        self.assertLess(commit_index, calendar_index)
        preflight_block = source[preflight_index:import_index]
        self.assertIn('"--validate-only"', preflight_block)
        self.assertNotIn("importCompletedRemindersToOverrides", preflight_block)
        import_and_build = source[import_index:status_index]
        self.assertIn(
            "importCompletedRemindersToOverrides(\n          stateJson,\n          completedRemindersOverridePendingJson",
            import_and_build,
        )
        self.assertIn('"--overrides-json",\n          buildOverridesJson', import_and_build)
        self.assertIn(
            'completedRemindersOverridePendingJson = `${overridesJson}.klms-sync.next`',
            source,
        )
        atomic_replace = extract_function(source, "replaceSiblingFileAtomically")
        self.assertIn('runCommand(["/bin/mv", "-f", src, dst]', atomic_replace)
        self.assertNotIn('"/bin/rm"', atomic_replace)

        dry_run_start = source.index(
            'if (remindersEnabled && dryRun) {', preflight_index
        )
        dry_run_end = source.index("\n      }", dry_run_start)
        dry_run_block = source[dry_run_start:dry_run_end]
        self.assertIn("removeFileIfExists(completedRemindersOverridePendingJson)", dry_run_block)
        self.assertNotIn("importCompletedRemindersToOverrides", dry_run_block)

    def test_validate_only_parser_failure_is_byte_identical_and_writes_no_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dashboard = root / "dashboard.json"
            details = root / "details.json"
            state = root / "state.json"
            overrides = root / "manual_assignment_overrides.json"
            output_html = root / "generated.html"
            output_state = root / "next_state.json"
            output_status = root / "status.json"

            dashboard.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "Dashboard",
                            "html": "<html><body>authenticated but structurally unknown</body></html>",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            details.write_text("[]", encoding="utf-8")
            state.write_bytes(b'{\n  "status": "ok",\n  "sentinel": "state"\n}\n')
            overrides.write_bytes(
                b'{\n  "assignments": {\n    "sentinel": "active"\n  }\n}\n'
            )
            output_html.write_bytes(b"existing html\n")
            output_state.write_bytes(b'{"sentinel":"next-state"}\n')
            output_status.write_bytes(b'{"sentinel":"status"}\n')
            tracked = [state, overrides, output_html, output_state, output_status]
            before = {path: path.read_bytes() for path in tracked}

            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--dashboard-json",
                    str(dashboard),
                    "--details-json",
                    str(details),
                    "--overrides-json",
                    str(overrides),
                    "--state-json",
                    str(state),
                    "--output-html",
                    str(output_html),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                    "--validate-only",
                ],
                cwd=PROJECT_DIR,
                env=PYTHON_SUBPROCESS_ENV,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual({path: path.read_bytes() for path in tracked}, before)

    def test_pending_completion_is_consumed_by_the_same_final_build(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dashboard = root / "dashboard.json"
            details = root / "details.json"
            state = root / "state.json"
            overrides = root / "manual_assignment_overrides.json"
            pending_overrides = root / "manual_assignment_overrides.json.klms-sync.next"
            output_state = root / "next_state.json"
            output_status = root / "status.json"

            dashboard.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "Dashboard",
                            "html": """
                            <div class="list-box assign">
                              <a href="https://klms.kaist.ac.kr/mod/assign/view.php?id=1234595">open</a>
                              <ul>
                                <li>2099.06.01~2099.06.09</li>
                                <li>Written Assignment 4</li>
                                <li>알고리즘 개론</li>
                              </ul>
                            </div>
                            """,
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            details.write_text("[]", encoding="utf-8")
            assignment = {
                "category": "assignment",
                "course": "알고리즘 개론",
                "title": "Written Assignment 4",
                "due": "2099.06.01~2099.06.09",
                "sync_due": "2099-06-09T23:59:00+09:00",
                "url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=1234595",
            }
            state.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "content": {
                            "kind": "success",
                            "assignments": [assignment],
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            overrides.write_text('{"assignments": {}}\n', encoding="utf-8")

            preflight = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--dashboard-json",
                    str(dashboard),
                    "--details-json",
                    str(details),
                    "--overrides-json",
                    str(overrides),
                    "--state-json",
                    str(state),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                    "--validate-only",
                ],
                cwd=PROJECT_DIR,
                env=PYTHON_SUBPROCESS_ENV,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(preflight.returncode, 0, preflight.stderr)
            self.assertFalse(output_state.exists())
            self.assertFalse(output_status.exists())

            reminder_import = subprocess.run(
                [
                    "node",
                    "-e",
                    r"""
const fs = require("fs");
const path = require("path");
global.ACTIVE_STAGE_TELEMETRY = null;
global.Application = () => ({});
global.fileExists = (target) => fs.existsSync(target);
global.readText = (target) => fs.readFileSync(target, "utf8");
global.writeText = (target, value) => fs.writeFileSync(target, value, "utf8");
global.ensureDir = (target) => fs.mkdirSync(target, { recursive: true });
global.parentDirectory = (target) => path.dirname(target);
global.runTelemetryEvent = (_telemetry, _group, _name, fn) => fn();
eval(fs.readFileSync("src/js/sync_reminders_bridge.js", "utf8"));

const statePath = process.argv[1];
const sourceOverridePath = process.argv[2];
const pendingOverridePath = process.argv[3];
fs.copyFileSync(sourceOverridePath, pendingOverridePath);
const entry = JSON.parse(fs.readFileSync(statePath, "utf8")).content.assignments[0];
const completedIdentifier = reminderIdentifierForItem(entry);
buildReminderAppSnapshot = () => ({});
collectCompletedReminderIdentifiers = () => [completedIdentifier];
const result = importCompletedRemindersToOverrides(
  statePath,
  pendingOverridePath,
  ["KLMS 과제"]
);
if (!result.includes("changed=3")) {
  throw new Error(`unexpected import result: ${result}`);
}
""",
                    str(state),
                    str(overrides),
                    str(pending_overrides),
                ],
                cwd=PROJECT_DIR,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(reminder_import.returncode, 0, reminder_import.stderr)
            pending_payload = json.loads(pending_overrides.read_text(encoding="utf-8"))
            self.assertEqual(
                pending_payload["assignments"][
                    "알고리즘 개론::Written Assignment 4::2099-06-09T23:59:00+09:00"
                ],
                "completed",
            )
            final_build = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--dashboard-json",
                    str(dashboard),
                    "--details-json",
                    str(details),
                    "--overrides-json",
                    str(pending_overrides),
                    "--state-json",
                    str(state),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                ],
                cwd=PROJECT_DIR,
                env=PYTHON_SUBPROCESS_ENV,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(final_build.returncode, 0, final_build.stderr)
            rendered = json.loads(output_state.read_text(encoding="utf-8"))
            self.assertEqual(rendered["content"]["assignments"], [])
            self.assertEqual(len(rendered["content"]["completed_assignments"]), 1)
            self.assertEqual(overrides.read_text(encoding="utf-8"), '{"assignments": {}}\n')

    def test_notice_prebuild_restores_error_and_warning_state(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        prebuild_start = source.index(
            'beginStage(steps, stageTelemetry, "notice-summary-prebuild")'
        )
        prebuild_end = source.index(
            'beginStage(steps, stageTelemetry, "build-note")', prebuild_start
        )
        prebuild = source[prebuild_start:prebuild_end]
        self.assertIn("noticeDigestErrorTxt", prebuild)
        self.assertIn("noticeNoteRenderWarningTxt", prebuild)
        self.assertIn("noticeRenderErrorSummaryJson", prebuild)
        catch_start = prebuild.index("} catch (noticeError) {")
        catch_block = prebuild[catch_start:]
        final_error_write = catch_block.index("noticeRenderErrorSummaryJson")
        dry_run_restore = catch_block.index(
            "if (dryRun) {\n          // A preview may report the transient error"
        )
        self.assertGreater(dry_run_restore, final_error_write)
        self.assertIn("restoreFileSnapshot(noticeSnapshot)", catch_block[dry_run_restore:])

    def test_state_commits_replace_without_deleting_the_authoritative_file_first(self) -> None:
        source = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        move_file = source[
            source.index("function moveFile(src, dst)") :
            source.index("function replaceSiblingFileAtomically", source.index("function moveFile(src, dst)"))
        ]

        self.assertIn('runCommand(["/bin/mv", "-f", src, dst]', move_file)
        self.assertNotIn('runCommand(["/bin/rm"', move_file)


if __name__ == "__main__":
    unittest.main()
