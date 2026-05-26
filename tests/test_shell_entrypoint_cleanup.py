import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class ShellEntrypointCleanupTests(unittest.TestCase):
    def test_single_scope_wrappers_use_common_entrypoint(self) -> None:
        for script_name, scope in [
            ("sync_klms_core.sh", "core"),
            ("sync_klms_notice.sh", "notice"),
        ]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / "bin" / script_name).read_text(encoding="utf-8")
                self.assertIn(f"klms_run_sync_scope_entrypoint {scope}", text)
                self.assertNotIn("sync_output=\"$(klms_run_sync_scope", text)

    def test_root_entrypoints_delegate_to_bin(self) -> None:
        for script_name in [
            "sync_klms_core.sh",
            "sync_klms_notice.sh",
            "sync_klms_all.sh",
            "refresh_course_files.sh",
            "run_all.sh",
            "run_all_full.sh",
            "run_all_parallel.sh",
            "verify_sync_state.sh",
            "doctor.sh",
            "sync_report.sh",
            "process_klms_assignments.sh",
            "klms_v2_build_state.sh",
            "kaikey_auto_login.sh",
            "kaikey_setup.sh",
            "kaikey_approve_number.sh",
        ]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / script_name).read_text(encoding="utf-8")
                self.assertIn(f'exec /bin/zsh "$SCRIPT_DIR/bin/{script_name}" "$@"', text)

    def test_serial_run_scripts_share_common_job_runner(self) -> None:
        for script_name in ["run_all.sh", "run_all_full.sh"]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / "bin" / script_name).read_text(encoding="utf-8")
                self.assertIn("klms_export_shared_sync_cache_defaults", text)
                self.assertIn("klms_prepare_prefetched_dashboard_for_namespaces", text)
                self.assertIn("klms_run_serial_child_job", text)
                self.assertNotIn("run_serial_job()", text)

    def test_full_sync_entrypoint_runs_notice_memo_sync_between_core_and_files(self) -> None:
        text = (PROJECT_DIR / "bin" / "run_all_full.sh").read_text(encoding="utf-8")

        core_index = text.index("klms_run_serial_child_job core ./sync_klms_core.sh")
        notice_index = text.index("klms_run_serial_child_job notice ./sync_klms_notice.sh")
        files_index = text.index("klms_run_serial_child_job files ./refresh_course_files.sh")

        self.assertLess(core_index, notice_index)
        self.assertLess(notice_index, files_index)

    def test_runtime_notice_environment_overrides_config_file(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "config.env"
            config.write_text(
                "\n".join(
                    [
                        'NOTICE_COLLAPSE_COURSES="0"',
                        'NOTICE_COLLAPSE_NOTICE_ITEMS="0"',
                        'NOTICE_NATIVE_ALWAYS_CAPTURE_STATE="1"',
                        'NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY="0"',
                    ]
                ),
                encoding="utf-8",
            )

            script = f"""
            source {common}
            export NOTICE_COLLAPSE_COURSES=1
            export NOTICE_COLLAPSE_NOTICE_ITEMS=1
            export NOTICE_NATIVE_ALWAYS_CAPTURE_STATE=0
            export NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY=1
            klms_init_context {root / "sync_klms_notice.sh"} {config}
            print -- "$NOTICE_COLLAPSE_COURSES:$NOTICE_COLLAPSE_NOTICE_ITEMS:$NOTICE_NATIVE_ALWAYS_CAPTURE_STATE:$NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), "1:1:0:1")

    def test_common_login_preflight_can_reuse_recent_success(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("KLMS_LOGIN_STATUS_REUSE_SECONDS", text)
        self.assertIn("klms_recent_login_status_ok", text)
        self.assertIn('[[ -s "$CACHE_DIR/dashboard.json" ]]', text)
        self.assertIn('fast_tab_state" != "login_required"', text)
        self.assertIn('KLMS_LOGIN_STATUS_REUSE_SECONDS="900"', config)

    def test_app_run_skips_redundant_login_preflight_checks(self) -> None:
        common = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")
        app_model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('KLMS_LOGIN_ASSIST_ENABLED": "1"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": "1"', app_model)
        self.assertNotIn("KLMS_LOGIN_ALWAYS_ASSIST_ENABLED", app_model)
        self.assertIn('"${KLMS_APP_RUN:-0}" == "1"', common)
        self.assertIn("KLMS_PARENT_LOGIN_ASSIST_READY", common)
        self.assertIn("KLMS_LOGIN_ASSIST_READY=1", common)
        self.assertIn('KLMS_USE_EXISTING_DASHBOARD="${KLMS_LOGIN_PREFETCH_READY:-0}"', common)
        self.assertIn('KLMS_PARENT_LOGIN_PREFLIGHT_READY="${KLMS_LOGIN_PREFETCH_READY:-0}"', common)
        self.assertNotIn("KLMS_LOGIN_ALWAYS_ASSIST_ENABLED", common)

    def test_app_run_trusts_successful_login_assist_without_dashboard_preflight(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "src" / "python").mkdir(parents=True)
            (root / "src" / "js").mkdir(parents=True)
            (root / "src" / "sh").mkdir(parents=True)
            (root / "config.env").write_text(
                "\n".join(
                    [
                        'KLMS_LOGIN_ASSIST_ENABLED="1"',
                        'KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="1"',
                    ]
                ),
                encoding="utf-8",
            )
            helper = root / "kaikey_auto_login.sh"
            helper.write_text(
                "#!/bin/zsh\nprint -- 'status=ok stage=authenticated'\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            script = f"""
            source {common}
            export PYTHONPATH={PROJECT_DIR / "src" / "python"}
            export KLMS_APP_RUN=1
            klms_init_context {root / "run_all_full.sh"} {root / "config.env"}
            klms_require_login
            print -- "$KLMS_LOGIN_PREFETCH_READY:$KLMS_LOGIN_ASSIST_READY"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("status=ok stage=authenticated", result.stdout)
            self.assertEqual(result.stdout.strip().splitlines()[-1], "0:1")
            self.assertNotIn("klms-login-preflight", result.stdout + result.stderr)
            self.assertNotIn("KLMS 로그인이 풀린", result.stdout + result.stderr)

    def test_app_run_stops_when_login_assist_fails(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "src" / "python").mkdir(parents=True)
            (root / "src" / "js").mkdir(parents=True)
            (root / "src" / "sh").mkdir(parents=True)
            (root / "config.env").write_text(
                "\n".join(
                    [
                        'KLMS_LOGIN_ASSIST_ENABLED="1"',
                        'KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="1"',
                        'KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE="0"',
                    ]
                ),
                encoding="utf-8",
            )
            helper = root / "kaikey_auto_login.sh"
            helper.write_text(
                "#!/bin/zsh\nprint -- 'KAIST 인증 번호: 42'\nprint -- 'status=timeout last_status=twofactor_digits digits=42'\nexit 1\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            script = f"""
            source {common}
            export PYTHONPATH={PROJECT_DIR / "src" / "python"}
            export KLMS_APP_RUN=1
            klms_init_context {root / "run_all_full.sh"} {root / "config.env"}
            klms_require_login
            status=$?
            print -- "status=$status ready=${{KLMS_LOGIN_PREFETCH_READY:-0}}"
            exit $status
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("KAIST 인증 번호: 42", result.stdout)
            self.assertIn("KLMS 로그인 보조 실패", result.stderr)
            self.assertNotIn("klms-login-preflight", result.stdout + result.stderr)

    def test_cleanup_script_removes_common_local_artifacts(self) -> None:
        text = (
            PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('".DS_Store"', text)
        self.assertIn('"__pycache__"', text)
        self.assertIn('"*.pyc"', text)
        self.assertIn("tmp_dir.rglob(pattern)", text)

    def test_cleanup_script_recursively_removes_file_tmp_lists(self) -> None:
        script = PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            nested = tmp_path / "files"
            nested.mkdir()
            stale_url_list = nested / "file_nested_urls_current.txt"
            stale_url_list.write_text("https://example.invalid\n", encoding="utf-8")

            env = os.environ.copy()
            env["KLMS_RUNTIME_TMP_CLEANUP_TARGET"] = str(tmp_path)
            result = subprocess.run(
                ["/bin/zsh", str(script)],
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("cleanup_runtime_tmp", result.stdout)
            self.assertFalse(stale_url_list.exists())

    def test_file_refresh_prunes_archive_and_cleans_tmp_on_success(self) -> None:
        text = (PROJECT_DIR / "bin" / "refresh_course_files.sh").read_text(encoding="utf-8")

        self.assertIn('ARCHIVE_PRUNE_RESULT_JSON="$CACHE_DIR/course_file_archive_prune_result.json"', text)
        self.assertIn('--root "$DOWNLOAD_ARCHIVE_ROOT"', text)
        self.assertIn("archive-prune-summary", text)
        self.assertIn("--backup-manifest", text)
        self.assertIn("--dry-run", text)
        self.assertIn("--preserve-destinations", text)
        self.assertIn("FILE_PRESERVE_DOWNLOAD_ARCHIVE", text)
        self.assertIn("preserve_archive=$FILE_PRESERVE_DOWNLOAD_ARCHIVE", text)
        self.assertIn('FILE_DOWNLOAD_WORK_ROOT="${FILE_DOWNLOAD_WORK_ROOT:-$TMP_DIR/downloads}"', text)
        self.assertIn("FILE_DOWNLOAD_ARCHIVE_ROOT", text)
        self.assertIn("FILE_NEW_FILES_ROOT", text)
        self.assertIn("FILE_QUARANTINE_ROOT", text)
        self.assertIn('"$NEW_FILES_ROOT"', text)
        self.assertIn('"$QUARANTINE_ROOT"', text)
        self.assertNotIn('$HOME/Downloads/KLMS Files', text)
        self.assertNotIn('$HOME/Downloads/KLMS Quarantine', text)
        self.assertIn('local preserve_download_archive="${6:-0}"', text)
        self.assertIn('"$FILE_PRESERVE_DOWNLOAD_ARCHIVE"', text)
        self.assertIn("existing_file_needs_refresh", text)
        self.assertIn('entry.get("klms_timestamp_epoch")', text)
        self.assertIn("FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS", text)
        self.assertIn("--always-fetch-min-interval-seconds=$FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS", text)
        self.assertIn("FILE_TIMESTAMP_GATED_SEED_REFRESH_ENABLED", text)
        self.assertIn("FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS", text)
        self.assertIn("seed timestamp gate active", text)
        self.assertIn("FILE_SEED_URL_LIST_CHANGED == 0", text)
        self.assertIn("file_seed_urls.next", text)
        self.assertIn("build_files_stage_timings.py", text)
        self.assertIn("klms_cleanup_runtime_tmp_if_enabled", text)
        self.assertIn('if is_truthy "${KLMS_APP_RUN:-0}"; then', text)
        self.assertIn('FILE_REFRESH_MODE="auto"', text)
        self.assertIn('FILE_FORCE_DOWNLOAD="0"', text)
        self.assertIn('FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY="1"', text)

    def test_mac_app_files_sync_is_incremental_by_default(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        settings = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "SettingsView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('"FILE_REFRESH_MODE": "auto"', model)
        self.assertIn('"FILE_FORCE_DOWNLOAD": "0"', model)
        self.assertIn('"FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY": "1"', model)
        self.assertIn('Picker("파일 탐색 모드"', settings)
        self.assertIn('allowedValues: ["auto", "quick"]', settings)
        file_picker = settings.split('Picker("파일 탐색 모드"', 1)[1].split("}", 1)[0]
        self.assertNotIn('Text("전체").tag("full")', file_picker)
        self.assertNotIn('configToggle("강제 재다운로드"', settings)

    def test_safari_automation_uses_background_windows_by_default(self) -> None:
        fetch_text = (PROJECT_DIR / "src" / "js" / "fetch_pages_with_safari.js").read_text(
            encoding="utf-8"
        )
        download_text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        for text in [fetch_text, download_text]:
            self.assertIn("KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED", text)
            self.assertIn("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", text)
            self.assertIn("prepareBackgroundWindow", text)
            self.assertIn("windowRef.miniaturized = true", text)
            self.assertIn("isBackgroundWindow", text)

        self.assertIn('KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED="1"', config)
        self.assertIn('KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED="0"', config)

    def test_safari_automation_defaults_to_dedicated_windows(self) -> None:
        fetch_text = (PROJECT_DIR / "src" / "js" / "fetch_pages_with_safari.js").read_text(
            encoding="utf-8"
        )
        download_text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        login_text = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")

        self.assertIn('envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "0")', fetch_text)
        self.assertIn("if (reuseExistingWindowEnabled)", fetch_text)
        self.assertIn("Failed to create a dedicated Safari fetch window", fetch_text)
        self.assertIn('envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "0")', download_text)
        self.assertIn("reuseExistingWindowEnabled ? findKlmsWindow", download_text)
        self.assertIn('make new document with properties {URL:targetUrl}', login_text)
        self.assertNotIn('repeat with w in windows', login_text)

    def test_launch_agent_aborts_sync_when_user_returns(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "launch_sync_if_idle.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("SYNC_ABORT_ON_USER_ACTIVITY", text)
        self.assertIn("SYNC_ACTIVE_ABORT_IDLE_SECONDS", text)
        self.assertIn("terminate_process_tree", text)
        self.assertIn("aborted=user-activity", text)

    def test_launch_agent_notifies_new_auth_digits_despite_cooldown(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "launch_sync_if_idle.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("LOGIN_PROMPT_DIGITS_FILE", text)
        self.assertIn('[[ "$auth_digits" == "$last_auth_digits" ]]', text)
        self.assertIn("login-prompt suppressed cooldown=%ss digits=%s", text)

    def test_cleanup_tracked_downloads_can_preserve_archive_destinations(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "cleanup_tracked_downloads.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("--preserve-destinations", text)
        self.assertIn("preserveDestinations", text)
        self.assertIn('action: fileExists(destinationPath) ? "preserved" : "already-missing"', text)
        self.assertIn('action: "not-tracked"', text)
        self.assertIn('return "";', text)

    def test_cleanup_tracked_downloads_does_not_keep_historical_fresh_files(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "cleanup_tracked_downloads.js").read_text(
            encoding="utf-8"
        )

        skipped_index = text.index("entry.skipped_existing")
        fresh_basis_index = text.index('String(entry.local_downloaded_basis || "") === "fresh-download"')
        self.assertLess(skipped_index, fresh_basis_index)

    def test_download_step_accepts_local_staging_roots(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "run_download_files_step.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('NEW_FILES_ROOT="${12:-}"', text)
        self.assertIn('QUARANTINE_ROOT="${13:-}"', text)
        self.assertIn("--new-files-root=$NEW_FILES_ROOT", text)
        self.assertIn("--quarantine-root=$QUARANTINE_ROOT", text)

    def test_launch_agent_install_copies_bin_implementations(self) -> None:
        text = (PROJECT_DIR / "install_launch_agent.sh").read_text(encoding="utf-8")

        self.assertIn('mkdir -p "$INSTALL_DIR/src" "$INSTALL_DIR/bin"', text)
        self.assertIn('cp -R "$SCRIPT_DIR/bin/." "$INSTALL_DIR/bin/"', text)
        self.assertIn('find "$INSTALL_DIR/bin" -type f -name', text)
        self.assertIn('cp "$SCRIPT_DIR/doctor.sh" "$INSTALL_DIR/"', text)
        self.assertIn('cp "$SCRIPT_DIR/sync_report.sh" "$INSTALL_DIR/"', text)
        self.assertIn('cp "$SCRIPT_DIR/process_klms_assignments.sh" "$INSTALL_DIR/"', text)
        self.assertIn('cp "$SCRIPT_DIR/klms_v2_build_state.sh" "$INSTALL_DIR/"', text)

    def test_assignment_processor_is_not_part_of_core_sync(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")

        self.assertNotIn("process_klms_assignments", text)
        self.assertNotIn("assignment-processor", text)

    def test_core_state_build_uses_v2_engine(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")

        build_stage_index = text.index('beginStage(steps, stageTelemetry, "build-note")')
        build_stage = text[build_stage_index:text.index('debugStderr("after build-note")')]
        self.assertIn("klms_sync_v2.cli", build_stage)
        self.assertNotIn("src/python/klms_sync.py", build_stage)

    def test_sync_js_login_page_detection_covers_sso_and_password_forms(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const source = fs.readFileSync("src/js/sync_klms_notes.js", "utf8");

function extractFunction(name) {
  const marker = `function ${name}(`;
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`missing ${name}`);
  const bodyStart = source.indexOf("{", start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    if (char === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  throw new Error(`unterminated ${name}`);
}

eval(extractFunction("looksLikeLoginPage"));
const cases = [
  { url: "https://sso.kaist.ac.kr/auth/twofactor/mfa/login2factor", title: "Single Sign On", html: "" },
  { url: "https://klms.kaist.ac.kr/my/", title: "KLMS", html: "<input name=\"username\"><input type=\"password\">" },
  { url: "https://portal.kaist.ac.kr/", title: "KAIST Portal", html: "" },
];
if (!cases.every((item) => looksLikeLoginPage(item))) {
  throw new Error("login detection missed an SSO/password case");
}
if (looksLikeLoginPage({ url: "https://klms.kaist.ac.kr/my/", title: "KLMS", html: "<a href=\"/login/logout.php\">logout</a>" })) {
  throw new Error("authenticated logout page was classified as login");
}
"""
        subprocess.run(
            [node, "-e", script],
            cwd=PROJECT_DIR,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_entrypoints_do_not_call_legacy_klms_sync_directly(self) -> None:
        for path in [
            PROJECT_DIR / "src" / "js" / "sync_klms_notes.js",
            PROJECT_DIR / "src" / "sh" / "klms_common.sh",
            PROJECT_DIR / "bin" / "refresh_course_files.sh",
        ]:
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("klms_sync.py", text)
                self.assertIn("klms_sync_v2.cli", text)

    def test_reminders_hash_uses_desired_payload_not_generated_state_text(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")

        self.assertIn("function buildRemindersDesiredHash", text)
        self.assertIn("buildDesiredReminders(normalizeSyncEntries(state.content), options)", text)
        self.assertIn("completedReminderRetentionDays", text)
        self.assertIn("deviceAlertMode", text)
        self.assertNotIn("readText(outputState) +", text)

    def test_default_config_keeps_assignment_note_sync_disabled(self) -> None:
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")

        self.assertIn('NOTES_SYNC_ENABLED="0"', config)
        self.assertNotIn("note-update", text)
        self.assertNotIn("config.NOTE_NAME", text)
        self.assertNotIn("ASSIGNMENT_NOTE_SYNC_ENABLED", text)

    def test_notice_managed_notes_recover_missing_note(self) -> None:
        text = (PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("func createManagedNote", text)
        self.assertIn("Could not locate or create managed Notes note", text)
        self.assertIn("Ignoring stale explicit Notes note id", text)
        self.assertNotIn("notes.make({", text)
        self.assertNotIn("new: \"note\"", text)
        self.assertNotIn("note.delete()", text)

    def test_notice_reuses_fresh_core_supplemental_primary_pages(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("NOTICE_SHARED_FALLBACK_MAX_AGE_SECONDS", text)
        self.assertIn("freshExistingFilesSinceOrWithin", text)
        self.assertIn('NOTICE_SHARED_FALLBACK_MAX_AGE_SECONDS="43200"', config)
        notice_fetch_index = text.index('context: "notice-supplemental-primary-pages"')
        next_stage_index = text.index('beginStage(steps, stageTelemetry, "notice-board-pagination-list")')
        notice_fetch_block = text[notice_fetch_index:next_stage_index]
        self.assertIn("fallbackPagePaths: paths.supplementalPrimaryFallbackPagePaths || []", notice_fetch_block)
        self.assertIn("reuseFallbackAlwaysFetch: true", notice_fetch_block)

    def test_verify_sync_state_uses_swift_calendar_counts(self) -> None:
        text = (PROJECT_DIR / "bin" / "verify_sync_state.sh").read_text(encoding="utf-8")

        self.assertIn("src/swift/verify_calendar_counts.swift", text)
        self.assertIn("verify_sync_state.py", text)
        self.assertIn("--exam-calendar=", text)
        self.assertIn("--helpdesk-calendar=", text)
        self.assertNotIn("osascript -l JavaScript", text)
        self.assertNotIn("summary of every event of calendar", text)

    def test_calendar_sync_uses_repo_swift_module_cache_and_opt_in_fallback(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("SWIFT_MODULE_CACHE_PATH=", text)
        self.assertIn("CLANG_MODULE_CACHE_PATH=", text)
        self.assertIn("-module-cache-path", text)
        self.assertIn('config.CALENDAR_SYNC_APPLESCRIPT_FALLBACK !== "1"', text)
        self.assertIn("deprecated-calendar-jxa-fallback", text)
        self.assertIn('CALENDAR_SYNC_APPLESCRIPT_FALLBACK="0"', config)

    def test_mac_app_requests_permissions_explicitly(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        view = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")
        build_script = (PROJECT_DIR / "tools" / "build_klms_mac_app.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("AXIsProcessTrustedWithOptions", model)
        self.assertIn("AXTrustedCheckOptionPrompt", model)
        self.assertIn("requestFullAccessToEvents", model)
        self.assertIn("requestFullAccessToReminders", model)
        self.assertIn("UNUserNotificationCenter.current()", model)
        self.assertIn("runAutomationPermissionProbes", model)
        self.assertIn('tell application id "com.apple.Safari"', model)
        self.assertIn('tell application id "com.apple.Notes"', model)
        self.assertIn('tell application id "com.apple.systemevents"', model)
        self.assertIn("shouldRequestPermissionsAfterInstall", model)
        self.assertIn("권한 요청", view)
        self.assertIn("System Events", build_script)
        self.assertIn("security find-identity -v -p codesigning", build_script)
        self.assertIn("Signing KLMS Sync.app with identity", build_script)

    def test_mac_app_notifies_auth_completion(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("notifiedAuthCompletionForCurrentRun", model)
        self.assertIn("lastAuthCompletionAt", model)
        self.assertIn("notifyAuthCompletionIfNeeded()", model)
        self.assertIn("currentAuthStatusMessageForRemote", model)
        self.assertIn("status.authStatusMessage = authStatusMessage", model)
        self.assertIn('phase == "running"', model)
        self.assertIn('content.title = "KLMS 인증 완료"', model)
        self.assertIn('content.body = "로그인 인증이 완료됐습니다. 동기화를 계속 진행합니다."', model)
        self.assertIn('showTransientAuthStatus("인증 완료됨")', model)
        self.assertIn("clearAuthDigitsState(showAuthenticatedMessage: true)", model)
        self.assertIn("removeDeliveredNotifications(withIdentifiers: identifiers)", model)
        self.assertNotIn("removeAllPendingNotificationRequests", model)
        self.assertNotIn("removeAllDeliveredNotifications", model)

        ios_app = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSiOS" / "KLMSiOSApp.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("status.authStatusMessage", ios_app)
        self.assertIn("shouldShowAuthCompletion", ios_app)
        self.assertIn('return "인증 완료"', ios_app)
        self.assertIn("AuthSuccessBanner", ios_app)
        self.assertIn('UserAlert(title: "인증 완료", message: authStatusMessage)', ios_app)
        self.assertNotIn("if let authStatusMessage = status.authStatusMessage {\n            return authStatusMessage\n        }\n        if status.loginRequired", ios_app)
        self.assertIn("? 2_000_000_000", ios_app)

    def test_local_remote_security_avoids_bearer_token_requests(self) -> None:
        shared = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSShared" / "RemoteCommandModels.swift"
        ).read_text(encoding="utf-8")
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        ios_app = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSiOS" / "KLMSiOSApp.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("import CryptoKit", shared)
        self.assertIn("HMAC<SHA256>", shared)
        self.assertIn("nonce", shared)
        self.assertIn("issuedAtEpochSeconds", shared)
        self.assertIn("signature", shared)
        self.assertIn("public func isAuthorized(", shared)
        self.assertIn("token: String", shared)
        self.assertNotIn("public var token: String\n    public var action", shared)
        self.assertIn("LocalRemoteTokenStore.load(account: \"mac\")", model)
        self.assertIn("LocalRemoteTokenStore.save(token, account: \"mac\")", model)
        self.assertIn("registerLocalRemoteAuthFailure", model)
        self.assertIn("localRemoteRecentNonces", model)
        self.assertIn("pasteboardClearTask", model)
        self.assertIn("LocalRemoteTokenStore.load(account: \"ios\")", ios_app)
        self.assertIn("persistLocalToken", ios_app)
        self.assertIn("UIPasteboard.general.string = \"\"", ios_app)

    def test_app_notice_renderer_uses_bundled_signed_helper(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        wrapper = (PROJECT_DIR / "src" / "sh" / "update_notice_native_note.sh").read_text(
            encoding="utf-8"
        )
        build_script = (PROJECT_DIR / "tools" / "build_klms_mac_app.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("NOTICE_NATIVE_NOTE_BIN_PATH", model)
        self.assertIn("KLMSNoticeNativeNote", model)
        self.assertIn('APP_HELPER_BIN="${NOTICE_NATIVE_NOTE_BIN_PATH:-}"', wrapper)
        self.assertIn('if [[ -n "$APP_HELPER_BIN" && -x "$APP_HELPER_BIN" ]]', wrapper)
        self.assertIn('BUILD_DIR="${NOTICE_NATIVE_NOTE_BUILD_DIR:-$SCRIPT_DIR/runtime/bin}"', wrapper)
        self.assertIn('local timeout_seconds="${TIMEOUT_SECONDS:-420}"', wrapper)
        self.assertIn('local target_pid="${!:-}"', wrapper)
        self.assertIn('if [[ -n "${target_pid:-}" ]]', wrapper)
        self.assertIn(
            'NATIVE_NOTICE_HELPER_APP="$APP_BUNDLE/Contents/Helpers/KLMSNoticeNativeNote.app"',
            build_script,
        )
        self.assertIn(
            'NATIVE_NOTICE_HELPER="$NATIVE_NOTICE_HELPER_APP/Contents/MacOS/KLMSNoticeNativeNote"',
            build_script,
        )
        self.assertIn('HELPER_BUNDLE_ID="${BUNDLE_ID}.notice-native-note"', build_script)
        self.assertIn("notice_native_note_support.swift", build_script)
        self.assertIn("update_notice_native_note.swift", build_script)


if __name__ == "__main__":
    unittest.main()
