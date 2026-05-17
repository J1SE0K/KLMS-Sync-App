import os
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

    def test_common_login_preflight_can_reuse_recent_success(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("KLMS_LOGIN_STATUS_REUSE_SECONDS", text)
        self.assertIn("klms_recent_login_status_ok", text)
        self.assertIn('[[ -s "$CACHE_DIR/dashboard.json" ]]', text)
        self.assertIn('fast_tab_state" != "login_required"', text)
        self.assertIn('KLMS_LOGIN_STATUS_REUSE_SECONDS="900"', config)

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
            self.assertIn("prepareBackgroundWindow", text)
            self.assertIn("windowRef.miniaturized = true", text)
            self.assertIn("isBackgroundWindow", text)

        self.assertIn('KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED="1"', config)

    def test_launch_agent_aborts_sync_when_user_returns(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "launch_sync_if_idle.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("SYNC_ABORT_ON_USER_ACTIVITY", text)
        self.assertIn("SYNC_ACTIVE_ABORT_IDLE_SECONDS", text)
        self.assertIn("terminate_process_tree", text)
        self.assertIn("aborted=user-activity", text)

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

    def test_notice_notes_are_existing_only(self) -> None:
        text = (PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("Refusing to create a new Notes note.", text)
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


if __name__ == "__main__":
    unittest.main()
