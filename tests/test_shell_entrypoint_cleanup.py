import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class ShellEntrypointCleanupTests(unittest.TestCase):
    def test_fresh_ownerless_shared_lock_gets_initialization_grace(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            lock_dir = Path(tmp) / "core-notice.lock"
            lock_dir.mkdir()
            script = f"""
            source {common}
            export KLMS_SHARED_SYNC_LOCK_DIR={lock_dir}
            export KLMS_SHARED_SYNC_LOCK_INITIALIZATION_GRACE_SECONDS=10
            klms_cleanup_stale_shared_sync_lock
            [[ -d "$KLMS_SHARED_SYNC_LOCK_DIR" ]] && print -- kept || print -- removed
            """

            fresh = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(fresh.stdout.strip(), "kept")

            # The process that won mkdir can now publish its PID without a
            # competitor having removed the directory during initialization.
            (lock_dir / "pid").write_text(str(os.getpid()), encoding="utf-8")
            self.assertTrue(lock_dir.is_dir())
            (lock_dir / "pid").unlink()
            old_epoch = 1_700_000_000
            os.utime(lock_dir, (old_epoch, old_epoch))

            stale = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(stale.stdout.strip(), "removed")
            self.assertFalse(lock_dir.exists())

    def test_core_and_notice_share_lock_without_sharing_work_cache(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        script = f"""
        source {common}
        for namespace in core notice files all; do
          print -- "$namespace:$(klms_default_sync_lock_name "$namespace")"
        done
        """
        result = subprocess.run(
            ["/bin/zsh", "-c", script],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            result.stdout.strip().splitlines(),
            ["core:core-notice", "notice:core-notice", "files:files", "all:all"],
        )

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
            "verify_sync_state.sh",
            "doctor.sh",
            "sync_report.sh",
            "process_klms_assignments.sh",
            "klms_v2_build_state.sh",
            "klms_login_assist.sh",
        ]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / script_name).read_text(encoding="utf-8")
                self.assertIn(f'exec /bin/zsh "$SCRIPT_DIR/bin/{script_name}" "$@"', text)

    def test_ios_device_installer_reports_generic_device_labels(self) -> None:
        script = (PROJECT_DIR / "tools" / "install_klms_ios_device.sh").read_text(encoding="utf-8")
        launch_script = (PROJECT_DIR / "tools" / "verify_klms_ios_device_launch.sh").read_text(encoding="utf-8")
        readiness_script = (PROJECT_DIR / "tools" / "verify_klms_app_readiness.sh").read_text(encoding="utf-8")
        readiness_workflow = (PROJECT_DIR / ".github" / "workflows" / "ui-readiness.yml").read_text(encoding="utf-8")
        readme = (PROJECT_DIR / "apps" / "KLMSync" / "README.md").read_text(encoding="utf-8")

        self.assertIn('local device_label="${2:-device}"', script)
        self.assertIn('print -r -- "${device_label}: installed"', script)
        self.assertIn('print -r -- "${device_label}: installed-and-launched"', script)
        self.assertIn('LaunchServicesDataMismatch|LaunchServices GUID', script)
        self.assertIn('print -ru2 -- "${device_label}: installed; launch-check pending', script)
        self.assertIn('print -ru2 -- "${device_label}: installed; launch-check blocked', script)
        self.assertLess(script.index("installed; launch-check blocked"), script.index("installed; launch-check pending"))
        self.assertIn("rerun this install command", script)
        self.assertIn('LAUNCH_RETRY_COUNT="${IOS_DEVICE_LAUNCH_RETRIES:-2}"', script)
        self.assertIn('LAUNCH_RETRY_DELAY_SECONDS="${IOS_DEVICE_LAUNCH_RETRY_DELAY_SECONDS:-2}"', script)
        self.assertIn('TUNNEL_WARMUP_SECONDS="${IOS_DEVICE_TUNNEL_WARMUP_SECONDS:-15}"', script)
        self.assertIn("IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED", script)
        self.assertIn("IOS_DEVICE_TRUST_RETRY_SECONDS", script)
        self.assertIn("IOS_DEVICE_TRUST_RETRY_POLL_SECONDS", script)
        self.assertIn("open_device_settings_for_trust()", script)
        self.assertIn("retry_launch_after_trust()", script)
        self.assertIn("waiting up to ${TRUST_RETRY_SECONDS}s for developer trust", script)
        self.assertIn("com.apple.Preferences", script)
        self.assertIn("opened Settings on the device for developer trust", script)
        self.assertIn("warm_device_connection()", script)
        self.assertIn('while true; do', script)
        self.assertIn('launch verification is waiting for iOS app registration', script)
        self.assertIn('launch_ready = tunnel_state == "connected"', script)
        self.assertIn('print(f"{identifier}\\t{hardware.get(\'deviceType\', \'device\')}\\t{1 if launch_ready else 0}")', script)
        self.assertIn('target_device="${device_entry%%$\'\\t\'*}"', script)
        self.assertIn('device_rest="${device_entry#*$\'\\t\'}"', script)
        self.assertIn('device_label="${device_rest%%$\'\\t\'*}"', script)
        self.assertIn("MANUAL_LAUNCH_STATUS=4", script)
        self.assertIn("BLOCKED_LAUNCH_STATUS=5", script)
        self.assertIn("installed_count=$(( installed_count + 1 ))", script)
        self.assertIn("launched_count=$(( launched_count + 1 ))", script)
        self.assertIn("installed_only_count=$(( installed_only_count + 1 ))", script)
        self.assertIn("pending_launch_count=$(( pending_launch_count + 1 ))", script)
        self.assertIn("blocked_launch_count=$(( blocked_launch_count + 1 ))", script)
        self.assertIn("manual_launch_count=$(( manual_launch_count + 1 ))", script)
        self.assertIn('print -r -- "install-summary installed=${installed_count} launched=${launched_count} installed_only=${installed_only_count} pending=${pending_launch_count} blocked=${blocked_launch_count} manual_launch_needed=${manual_launch_count} failed=${failed_count}"', script)
        self.assertNotIn("properties.get(\"name\")", script)
        self.assertIn('DEVICE_IDENTIFIER="${IOS_DEVICE_IDENTIFIER:-${1:-all}}"', launch_script)
        self.assertIn('REQUIRED_DEVICE_TYPES="${IOS_DEVICE_REQUIRE_TYPES:-}"', launch_script)
        self.assertIn('TUNNEL_WARMUP_SECONDS="${IOS_DEVICE_TUNNEL_WARMUP_SECONDS:-15}"', launch_script)
        self.assertIn("IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED", launch_script)
        self.assertIn("IOS_DEVICE_TRUST_RETRY_SECONDS", launch_script)
        self.assertIn("IOS_DEVICE_TRUST_RETRY_POLL_SECONDS", launch_script)
        self.assertIn("open_device_settings_for_trust()", launch_script)
        self.assertIn("retry_launch_after_trust()", launch_script)
        self.assertIn("waiting up to ${TRUST_RETRY_SECONDS}s for developer trust", launch_script)
        self.assertIn("com.apple.Preferences", launch_script)
        self.assertIn("opened Settings on the device for developer trust", launch_script)
        self.assertIn("warm_device_connection()", launch_script)
        self.assertIn("array_contains()", launch_script)
        self.assertIn('launch_ready = 1 if tunnel_state == "connected" else 0', launch_script)
        self.assertIn('print -r -- "${device_label}: launch-verified"', launch_script)
        self.assertIn("BLOCKED_LAUNCH_STATUS=5", launch_script)
        self.assertIn("pending_launch_count=$(( pending_launch_count + 1 ))", launch_script)
        self.assertIn("blocked_launch_count=$(( blocked_launch_count + 1 ))", launch_script)
        self.assertIn('print -r -- "launch-check-summary launched=${launched_count} launched_types=${(j:,:)launched_device_types} pending=${pending_launch_count} blocked=${blocked_launch_count} manual_launch_needed=${manual_launch_count} failed=${failed_count}"', launch_script)
        self.assertLess(launch_script.index("launch-check blocked"), launch_script.index("launch-check pending. Unlock"))
        self.assertIn("launch-check missing", launch_script)
        self.assertIn('required_device_types=("${(@s:,:)REQUIRED_DEVICE_TYPES}")', launch_script)
        self.assertIn('redact_bundle_id <"$LAUNCH_OUTPUT"', launch_script)
        self.assertIn('print(f"{identifier}\\t{hardware.get(\'deviceType\', \'device\')}\\t{launch_ready}\\t{tunnel_state}")', launch_script)
        self.assertNotIn("RequestDenied|Security", script)
        self.assertNotIn("RequestDenied|Security", launch_script)
        self.assertNotIn("properties.get(\"name\")", launch_script)
        self.assertIn("KLMS Sync readiness check", readiness_script)
        self.assertIn("sanitize_output()", readiness_script)
        self.assertIn("set -uo pipefail", readiness_script)
        self.assertNotIn("set -euo pipefail", readiness_script)
        self.assertIn('record_step "git-metadata"', readiness_script)
        self.assertIn("rev-parse --verify 'HEAD^{commit}'", readiness_script)
        self.assertIn('GIT_METADATA_STATE="invalid"', readiness_script)
        self.assertNotIn("print -r -- unknown", readiness_script)
        self.assertIn('record_step "swift-tests"', readiness_script)
        self.assertIn("--enable-xctest", readiness_script)
        self.assertIn("--disable-swift-testing", readiness_script)
        self.assertIn('record_step "mac-build"', readiness_script)
        self.assertIn('record_step "mac-relaunch"', readiness_script)
        self.assertIn("relaunch_mac_app()", readiness_script)
        self.assertIn('MAC_RELAUNCH_DELAY_SECONDS="${KLMS_READINESS_MAC_RELAUNCH_DELAY_SECONDS:-5}"', readiness_script)
        self.assertIn("/usr/bin/pkill -x KLMSMac", readiness_script)
        self.assertIn("Timed out waiting for previous KLMS Sync processes to terminate.", readiness_script)
        self.assertIn("Timed out waiting for the candidate KLMS Sync process to launch.", readiness_script)
        self.assertLess(
            readiness_script.index("/usr/bin/pkill -x KLMSMac"),
            readiness_script.index('/usr/bin/open -n "$MAC_APP_PATH"'),
        )
        self.assertIn("mac-build|mac-relaunch|mac-accessibility-smoke|mac-resize-hit-area|mac-basic-actions|mac-tab-response", readiness_script)
        self.assertIn('record_step "mac-accessibility-smoke"', readiness_script)
        self.assertIn('record_step "mac-resize-hit-area"', readiness_script)
        self.assertIn('record_step "mac-basic-actions"', readiness_script)
        self.assertIn('ALLOW_DESTRUCTIVE_ACTIONS="${KLMS_READINESS_ALLOW_DESTRUCTIVE_ACTIONS:-0}"', readiness_script)
        self.assertIn('KLMS_MAC_SMOKE_ALLOW_DESTRUCTIVE_ACTIONS="$ALLOW_DESTRUCTIVE_ACTIONS"', readiness_script)
        self.assertIn('KLMS_READINESS_ALLOW_DESTRUCTIVE_ACTIONS: "0"', readiness_workflow)
        self.assertIn("if: github.repository_visibility == 'private'", readiness_workflow)
        self.assertIn("tools/verify_klms_app_readiness.sh > ui-readiness.log 2>&1", readiness_workflow)
        self.assertNotIn("actions/upload-artifact", readiness_workflow)
        self.assertIn('record_step "mac-tab-response"', readiness_script)
        self.assertIn('record_step "ios-signed-build"', readiness_script)
        self.assertIn('record_step "ios-device-launch"', readiness_script)
        self.assertIn("IOS_DEVICE_REQUIRE_TYPES=iPhone,iPad", readiness_script)
        self.assertIn("print_failure_hint()", readiness_script)
        self.assertIn("ios-device-launch:4", readiness_script)
        self.assertIn("ios-device-launch:5", readiness_script)
        self.assertIn("iOS build and signing are ready, but device trust is blocked", readiness_script)
        self.assertIn("return 0", readiness_script)
        self.assertIn("readiness-summary status=ok candidate=${CANDIDATE_REVISION} worktree=${WORKTREE_STATE} swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state}", readiness_script)
        self.assertIn("readiness-summary status=fail candidate=${CANDIDATE_REVISION} worktree=${WORKTREE_STATE} swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state}", readiness_script)
        self.assertLess(
            readiness_script.index("record_step()"),
            readiness_script.index('record_step "clean-worktree"'),
        )
        self.assertIn('ios_launch_state="skipped"', readiness_script)
        self.assertIn('swift_state="failed"', readiness_script)
        self.assertIn('mac_state="failed"', readiness_script)
        self.assertIn('ios_build_state="failed"', readiness_script)
        self.assertIn('ios_launch_state="failed"', readiness_script)
        self.assertIn("<repo-root>", readiness_script)
        self.assertIn("<home>", readiness_script)
        self.assertIn("<bundle-id>", readiness_script)
        self.assertNotIn("local status=", readiness_script)
        self.assertIn("prints a generic `iPhone` or `iPad` label for each result", readme)
        self.assertIn("tools/verify_klms_app_readiness.sh", readme)
        self.assertIn("requires both an iPhone and an iPad", readme)
        self.assertIn("Mac accessibility smoke", readme)
        self.assertIn("Mac basic-actions smoke", readme)
        self.assertIn("Mac tab-response probe", readme)
        self.assertIn("installed; launch-check pending", readme)
        self.assertIn("installed; launch-check blocked", readme)
        self.assertIn("IOS_DEVICE_TUNNEL_WARMUP_SECONDS", readme)
        self.assertIn("IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED=0", readme)
        self.assertIn("IOS_DEVICE_OPEN_SETTINGS_TIMEOUT_SECONDS", readme)
        self.assertIn("IOS_DEVICE_TRUST_RETRY_SECONDS", readme)
        self.assertIn("IOS_DEVICE_TRUST_RETRY_POLL_SECONDS", readme)
        self.assertIn("tools/verify_klms_ios_device_launch.sh", readme)
        self.assertIn("launch-check-summary launched=... launched_types=... pending=... blocked=... manual_launch_needed=... failed=...", readme)
        self.assertIn("Xcode account login and iOS device trust are separate", readme)
        self.assertIn("IOS_DEVICE_REQUIRE_TYPES=iPhone,iPad", readme)
        self.assertIn("iOS is still refreshing app registration", readme)
        self.assertIn("IOS_DEVICE_LAUNCH_RETRIES", readme)
        self.assertIn("IOS_DEVICE_LAUNCH_RETRY_DELAY_SECONDS", readme)

    def test_ios_device_build_log_is_private_and_redacts_credential_records(self) -> None:
        script = (PROJECT_DIR / "tools" / "build_klms_ios_device.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("umask 077", script)
        self.assertIn('[[ -L "$BUILD_LOG" || -d "$BUILD_LOG" ]]', script)
        self.assertIn('chmod 600 "$BUILD_LOG"', script)
        self.assertIn("<credential-record-id>", script)

    def test_serial_run_scripts_share_common_job_runner(self) -> None:
        for script_name in ["run_all.sh", "run_all_full.sh"]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / "bin" / script_name).read_text(encoding="utf-8")
                self.assertIn("klms_export_shared_sync_cache_defaults", text)
                self.assertIn("klms_prepare_prefetched_dashboard_for_namespaces", text)
                self.assertIn("klms_run_serial_child_job", text)
                self.assertNotIn("run_serial_job()", text)

    def test_full_sync_entrypoint_runs_files_before_core_and_notice(self) -> None:
        text = (PROJECT_DIR / "bin" / "run_all_full.sh").read_text(encoding="utf-8")

        core_index = text.index("klms_run_serial_child_job core ./sync_klms_core.sh")
        notice_index = text.index("klms_run_serial_child_job notice ./sync_klms_notice.sh")
        files_index = text.index("klms_run_serial_child_job files ./refresh_course_files.sh")

        self.assertLess(files_index, core_index)
        self.assertLess(core_index, notice_index)

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
                        'NOTICE_NATIVE_POST_RENDER_VERIFY="1"',
                        'NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED="1"',
                        'NOTICE_NATIVE_SELECTION_SETTLE_SECONDS="1.0"',
                        'KLMS_LOGIN_STATUS_REUSE_SECONDS="900"',
                        'KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS="150"',
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
            export NOTICE_NATIVE_POST_RENDER_VERIFY=0
            export NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED=0
            export NOTICE_NATIVE_SELECTION_SETTLE_SECONDS=0.012
            export KLMS_LOGIN_STATUS_REUSE_SECONDS=300
            export KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS=0
            klms_init_context {root / "sync_klms_notice.sh"} {config}
            print -- "$NOTICE_COLLAPSE_COURSES:$NOTICE_COLLAPSE_NOTICE_ITEMS:$NOTICE_NATIVE_ALWAYS_CAPTURE_STATE:$NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY:$NOTICE_NATIVE_POST_RENDER_VERIFY:$NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED:$NOTICE_NATIVE_SELECTION_SETTLE_SECONDS:$KLMS_LOGIN_STATUS_REUSE_SECONDS:$KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), "1:1:0:1:0:0:0.012:300:0")

    def test_runtime_override_path_environment_overrides_config_file(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "config.env"
            config.write_text(
                'OVERRIDES_JSON_PATH="/tmp/config-manual-assignment-overrides.json"\n',
                encoding="utf-8",
            )

            app_overrides = root / "canonical" / "manual_assignment_overrides.json"
            script = f"""
            source {common}
            export OVERRIDES_JSON_PATH={app_overrides}
            klms_init_context {root / "run_all_full.sh"} {config}
            print -- "$OVERRIDES_JSON_PATH"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), str(app_overrides))

    def test_readonly_entrypoints_default_to_installed_data_dir_from_source_checkout(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            installed = Path(tmp) / "installed"
            (source / "apps" / "KLMSync").mkdir(parents=True)
            (source / "src").mkdir()
            (source / "bin").mkdir()
            (installed / "runtime").mkdir(parents=True)

            script = f"""
            source {common}
            export KLMS_INSTALLED_DATA_DIR={installed}
            print -- "$(klms_default_readonly_data_dir {source})"
            print -- "$(KLMS_DATA_DIR={source} klms_default_readonly_data_dir {installed})"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip().splitlines(), [str(installed), str(installed)])

    def test_sync_entrypoints_default_to_installed_data_dir_from_source_checkout(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            installed = Path(tmp) / "installed"
            (source / "apps" / "KLMSync").mkdir(parents=True)
            (source / "src").mkdir()
            (source / "bin").mkdir()
            (installed / "runtime").mkdir(parents=True)

            script = f"""
            source {common}
            export KLMS_INSTALLED_DATA_DIR={installed}
            export KLMS_SHARED_SYNC_LOCK_ROOT={installed}/runtime/automation
            klms_init_context {source}/refresh_course_files.sh
            print -- "$KLMS_DATA_DIR"
            print -- "$RUNTIME_DIR"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip().splitlines(), [str(installed), str(installed / "runtime")])

    def test_readonly_entrypoints_use_data_runtime_paths(self) -> None:
        for script_name in ["verify_sync_state.sh", "sync_report.sh", "doctor.sh"]:
            with self.subTest(script=script_name):
                text = (PROJECT_DIR / "bin" / script_name).read_text(encoding="utf-8")
                self.assertIn("KLMS_DATA_DIR", text)
                self.assertIn("klms_default_readonly_data_dir", text)
                self.assertIn("$RUNTIME_DIR/state/state.json", text)

    def test_common_login_preflight_can_reuse_recent_success(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("KLMS_LOGIN_STATUS_REUSE_SECONDS", text)
        self.assertIn("klms_recent_login_status_ok", text)
        self.assertIn('[[ -s "$CACHE_DIR/dashboard.json" ]]', text)
        self.assertIn('"${KLMS_APP_RUN:-0}" == "1"', text)
        self.assertIn('if klms_recent_login_status_ok; then', text)
        self.assertIn('KLMS_LOGIN_STATUS_REUSE_SECONDS="900"', config)

    def test_app_run_forces_login_preflight_for_sync_buttons(self) -> None:
        common = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")
        app_model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        app_entry = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacApp.swift"
        ).read_text(encoding="utf-8")
        login_assist = (PROJECT_DIR / "bin" / "klms_login_assist.sh").read_text(encoding="utf-8")

        self.assertIn('KLMS_LOGIN_ASSIST_ENABLED": "1"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": "1"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_MODE": "manual-digits"', app_model)
        self.assertIn('KLMS_FORCE_LOGIN_PREFLIGHT": "1"', app_model)
        self.assertIn('KLMS_LOGIN_STATUS_REUSE_SECONDS": "21600"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS": "0"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED": "1"', app_model)
        self.assertIn('"OVERRIDES_JSON_PATH": paths.overridesURL.path', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS": "1"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_AUTH_CHECK_SECONDS": "1.2"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS": "60"', app_model)
        self.assertIn('FILE_DOWNLOAD_PARALLELISM": "3"', app_model)
        self.assertIn('FILE_DIRECT_FETCH_MAX_BYTES": "26214400"', app_model)
        self.assertIn('REMINDER_RECREATE_STAGE_ALERT_LIST": "0"', app_model)
        self.assertNotIn("KLMS_LOGIN_ALWAYS_ASSIST_ENABLED", app_model)
        self.assertIn('[[ "${KLMS_APP_RUN:-0}" == "1" ]] && return 0', common)
        self.assertIn('"${KLMS_APP_RUN:-0}" == "1"', common)
        self.assertIn('"$force_login_preflight" != "1"', common)
        self.assertIn('if [[ "$fast_tab_state" == "authenticated" ]]', common)
        self.assertIn("klms_report_already_logged_in", common)
        self.assertIn("stage=already_authenticated", common)
        self.assertIn("KLMS 이미 로그인되어 있습니다.", common)
        self.assertIn("outputIndicatesAlreadyAuthenticated", app_model)
        self.assertIn('showTransientAuthStatus("이미 로그인됨")', app_model)
        self.assertIn("stage=already_authenticated source=login-assist-safari", login_assist)
        legacy_prefix = "kai" + "key"
        self.assertNotIn(legacy_prefix + "_cli.mjs", login_assist)
        self.assertNotIn("KAI" + "KEY_STATE_PATH", login_assist)
        self.assertNotIn(legacy_prefix + "-auto", login_assist)
        self.assertIn('klms_recent_login_status_ok', common)
        self.assertIn("KLMS_PARENT_LOGIN_ASSIST_READY", common)
        self.assertIn("KLMS_LOGIN_ASSIST_READY=1", common)
        self.assertIn('KLMS_USE_EXISTING_DASHBOARD="${KLMS_LOGIN_PREFETCH_READY:-0}"', common)
        self.assertIn('KLMS_PARENT_LOGIN_PREFLIGHT_READY="${KLMS_LOGIN_PREFETCH_READY:-0}"', common)
        self.assertNotIn("startRunningCommandStatusPoll", app_model)
        self.assertNotIn("runningSnapshotRefreshIntervalNanoseconds", app_model)
        self.assertIn("loginStatusWasConfirmed", app_model)
        self.assertIn("configureFileSystemEventRefresh", app_model)
        self.assertIn("KLMSFileSystemEventWatcher", app_model)
        self.assertIn("fileSystemEventDebounceNanoseconds", app_model)
        self.assertNotIn("configurePassiveSnapshotRefresh", app_model)
        self.assertNotIn("passiveSnapshotRefreshIntervalNanoseconds", app_model)
        self.assertIn("showLoginTransition: true", app_model)
        self.assertIn("EngineSnapshotStore(paths: paths).load()", app_model)
        self.assertIn("cancelCommandBeforeTermination", app_model)
        self.assertIn("applicationShouldTerminate", app_entry)
        self.assertIn(".terminateLater", app_entry)
        self.assertNotIn("KLMS_LOGIN_ALWAYS_ASSIST_ENABLED", common)

    def test_forced_app_login_preflight_ignores_recent_cache(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "fetch-called"
            (root / "src" / "python").mkdir(parents=True)
            (root / "src" / "python" / "klms_sync_v2").mkdir(parents=True)
            (root / "src" / "js").mkdir(parents=True)
            (root / "src" / "sh").mkdir(parents=True)
            (root / "config.env").write_text(
                "\n".join(
                    [
                        'KLMS_LOGIN_ASSIST_ENABLED="1"',
                        'KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="1"',
                        'KLMS_LOGIN_FAST_TAB_CHECK_ENABLED="0"',
                    ]
                ),
                encoding="utf-8",
            )
            (root / "src" / "python" / "fetch_pages_backend.py").write_text(
                f"""
import json
import sys
from pathlib import Path

Path({str(marker)!r}).write_text("1", encoding="utf-8")
out = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--out="))
with open(out, "w", encoding="utf-8") as handle:
    json.dump([{{"url": "https://klms.kaist.ac.kr/my/", "title": "강의 현황", "html": ""}}], handle)
print("fetch-ok")
""".lstrip(),
                encoding="utf-8",
            )
            (root / "src" / "python" / "klms_sync_v2" / "__init__.py").write_text("", encoding="utf-8")
            (root / "src" / "python" / "klms_sync_v2" / "cli.py").write_text(
                """
import json

print(json.dumps({"status": "ok"}))
""".lstrip(),
                encoding="utf-8",
            )

            script = f"""
            source {common}
            export PYTHONPATH={root / "src" / "python"}
            export KLMS_APP_RUN=1
            export KLMS_FORCE_LOGIN_PREFLIGHT=1
            export KLMS_LOGIN_STATUS_REUSE_SECONDS=21600
            klms_init_context {root / "run_all_full.sh"} {root / "config.env"}
            mkdir -p "$CACHE_DIR"
            print -- '{{"checked_at_epoch":'$(date +%s)',"logged_in":true}}' > "$KLMS_LOGIN_STATUS_PATH"
            print -- '[{{"url":"https://klms.kaist.ac.kr/my/","title":"강의 현황","html":""}}]' > "$CACHE_DIR/dashboard.json"
            klms_require_login
            print -- "$KLMS_LOGIN_PREFETCH_READY"
            """
            result = subprocess.run(
                ["/bin/zsh", "-c", script],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertTrue(marker.exists(), result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip().splitlines()[-1], "1")
            self.assertIn("preflight start", result.stderr)
            self.assertIn("stage=already_authenticated source=preflight", result.stderr)
            self.assertIn("KLMS 이미 로그인되어 있습니다.", result.stderr)

    def test_app_run_checks_dashboard_before_login_assist(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "src" / "python").mkdir(parents=True)
            (root / "src" / "python" / "klms_sync_v2").mkdir(parents=True)
            (root / "src" / "js").mkdir(parents=True)
            (root / "src" / "sh").mkdir(parents=True)
            (root / "config.env").write_text(
                "\n".join(
                    [
                        'KLMS_LOGIN_ASSIST_ENABLED="1"',
                        'KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="1"',
                        'KLMS_LOGIN_FAST_TAB_CHECK_ENABLED="0"',
                    ]
                ),
                encoding="utf-8",
            )
            (root / "src" / "python" / "fetch_pages_backend.py").write_text(
                """
import json
import sys

out = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--out="))
with open(out, "w", encoding="utf-8") as handle:
    json.dump([{"url": "https://klms.kaist.ac.kr/my/", "title": "강의 현황", "html": ""}], handle)
print("fetch-ok")
""".lstrip(),
                encoding="utf-8",
            )
            (root / "src" / "python" / "klms_sync_v2" / "__init__.py").write_text("", encoding="utf-8")
            (root / "src" / "python" / "klms_sync_v2" / "cli.py").write_text(
                """
import json

print(json.dumps({"status": "ok"}))
""".lstrip(),
                encoding="utf-8",
            )
            assist_marker = root / "assist-called"
            helper = root / "klms_login_assist.sh"
            helper.write_text(
                f"#!/bin/zsh\nprint -r -- called > {assist_marker}\nprint -- 'status=ok stage=authenticated'\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            script = f"""
            source {common}
            export PYTHONPATH={root / "src" / "python"}
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

            self.assertFalse(assist_marker.exists(), result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip().splitlines()[-1], "1:0")
            self.assertNotIn("KLMS 로그인이 풀린", result.stdout + result.stderr)
            self.assertIn("stage=already_authenticated source=preflight", result.stderr)
            self.assertIn("KLMS 이미 로그인되어 있습니다.", result.stderr)

    def test_app_run_stops_when_login_assist_fails(self) -> None:
        common = PROJECT_DIR / "src" / "sh" / "klms_common.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "src" / "python").mkdir(parents=True)
            (root / "src" / "python" / "klms_sync_v2").mkdir(parents=True)
            (root / "src" / "js").mkdir(parents=True)
            (root / "src" / "sh").mkdir(parents=True)
            (root / "config.env").write_text(
                "\n".join(
                    [
                        'KLMS_LOGIN_ASSIST_ENABLED="1"',
                        'KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="1"',
                        'KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE="0"',
                        'KLMS_LOGIN_FAST_TAB_CHECK_ENABLED="0"',
                    ]
                ),
                encoding="utf-8",
            )
            (root / "src" / "python" / "fetch_pages_backend.py").write_text(
                """
import json
import sys

out = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--out="))
with open(out, "w", encoding="utf-8") as handle:
    json.dump([{"url": "https://sso.kaist.ac.kr/login", "title": "Single Sign On", "html": ""}], handle)
print("fetch-login")
""".lstrip(),
                encoding="utf-8",
            )
            (root / "src" / "python" / "klms_sync_v2" / "__init__.py").write_text("", encoding="utf-8")
            (root / "src" / "python" / "klms_sync_v2" / "cli.py").write_text(
                """
import json

print(json.dumps({"status": "login_required", "message": "login required"}))
""".lstrip(),
                encoding="utf-8",
            )
            helper = root / "klms_login_assist.sh"
            helper.write_text(
                "#!/bin/zsh\nprint -- 'KAIST 인증 번호: 42'\nprint -- 'status=timeout last_status=twofactor_digits digits=42'\nexit 1\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            script = f"""
            source {common}
            export PYTHONPATH={root / "src" / "python"}
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
        self.assertIn('fnmatch.fnmatch(path.name, pattern)', text)
        self.assertIn('descendants(scan_root)', text)

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

    def test_managed_root_cleanup_preserves_unknown_namespaces(self) -> None:
        script = PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            managed = tmp_path / "core"
            unknown = tmp_path / "violence_prevention_20260605"
            managed.mkdir()
            unknown.mkdir()
            managed_file = managed / "generated.txt"
            personal_file = unknown / "result.txt"
            managed_file.write_text("generated\n", encoding="utf-8")
            personal_file.write_text("personal\n", encoding="utf-8")

            env = os.environ.copy()
            env["KLMS_RUNTIME_TMP_CLEANUP_TARGET"] = str(tmp_path)
            result = subprocess.run(
                [
                    "/bin/zsh",
                    str(script),
                    "--managed-root",
                    "--max-age-hours",
                    "0",
                ],
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertFalse(managed_file.exists())
            self.assertTrue(managed.is_dir())
            self.assertEqual(personal_file.read_text(encoding="utf-8"), "personal\n")
            self.assertIn(f"preserved_unknown {unknown.resolve()}", result.stdout)

    def test_managed_root_dry_run_reports_without_deleting(self) -> None:
        script = PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            managed_file = tmp_path / "notice" / "generated.json"
            unknown_file = tmp_path / "personal-note.txt"
            managed_file.parent.mkdir()
            managed_file.write_text("{}\n", encoding="utf-8")
            unknown_file.write_text("keep\n", encoding="utf-8")

            env = os.environ.copy()
            env["KLMS_RUNTIME_TMP_CLEANUP_TARGET"] = str(tmp_path)
            result = subprocess.run(
                [
                    "/bin/zsh",
                    str(script),
                    "--managed-root",
                    "--max-age-hours",
                    "0",
                    "--dry-run",
                ],
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertTrue(managed_file.exists())
            self.assertTrue(unknown_file.exists())
            self.assertIn(f"would_remove {managed_file.resolve()}", result.stdout)
            self.assertIn(f"preserved_unknown {unknown_file.resolve()}", result.stdout)
            self.assertIn("dry_run=1", result.stdout)

    def test_managed_root_cleanup_refuses_protected_target(self) -> None:
        script = PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        env = os.environ.copy()
        env["KLMS_RUNTIME_TMP_CLEANUP_TARGET"] = "/"
        result = subprocess.run(
            ["/bin/zsh", str(script), "--managed-root", "--max-age-hours", "0"],
            env=env,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing protected cleanup target", result.stderr)

    def test_managed_root_cleanup_refuses_broken_symlink_target(self) -> None:
        script = PROJECT_DIR / "src" / "sh" / "cleanup_runtime_tmp.sh"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            outside = tmp_path / "outside"
            symlink_target = tmp_path / "runtime-tmp-link"
            symlink_target.symlink_to(outside, target_is_directory=True)

            env = os.environ.copy()
            env["KLMS_RUNTIME_TMP_CLEANUP_TARGET"] = str(symlink_target)
            result = subprocess.run(
                ["/bin/zsh", str(script), "--managed-root", "--max-age-hours", "0"],
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid cleanup target", result.stderr)
            self.assertFalse(outside.exists())

    def test_full_run_root_cleanup_uses_managed_scope(self) -> None:
        common = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(
            encoding="utf-8"
        )
        root_cleanup = common[common.index("klms_cleanup_tmp_root_if_enabled()") :]

        self.assertIn("--managed-root", root_cleanup)

    def test_local_artifact_cleanup_preserves_private_runtime_data(self) -> None:
        script = PROJECT_DIR / "tools" / "clean_local_artifacts.sh"
        text = script.read_text(encoding="utf-8")

        self.assertIn("runtime/tmp", text)
        self.assertIn("--managed-root", text)
        self.assertIn("unknown runtime/tmp namespaces", text)
        self.assertIn("apps/KLMSync/.build", text)
        self.assertIn("apps/KLMSyncWindows/dist", text)
        self.assertIn("notice_native_note_timing.log", text)
        self.assertIn("runtime/state", text)
        self.assertIn("course_files", text)
        self.assertIn("manual overrides", text)
        self.assertIn("Refusing to remove protected path", text)
        self.assertNotIn('remove_path "$REPO_ROOT/runtime/tmp"', text)
        self.assertNotIn("git clean", text)

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
        self.assertIn('OUTPUT_ROOT="${FILE_OUTPUT_ROOT:-$KLMS_DATA_DIR/course_files}"', text)
        self.assertIn('"$NEW_FILES_ROOT"', text)
        self.assertIn('"$QUARANTINE_ROOT"', text)
        self.assertNotIn('$HOME/Downloads/KLMS Files', text)
        self.assertNotIn('$HOME/Downloads/KLMS Quarantine', text)
        self.assertIn('local preserve_download_archive="${6:-0}"', text)
        self.assertIn('"$FILE_PRESERVE_DOWNLOAD_ARCHIVE"', text)
        self.assertIn("existing_file_needs_refresh", text)
        self.assertIn("existing_file_refresh_decision", text)
        self.assertIn('entry.get("klms_timestamp_epoch")', text)
        self.assertIn("local_file_epoch", text)
        self.assertIn("epochs_match(current_epoch, previous_epoch)", text)
        self.assertIn("epochs_match(current_epoch, local_epoch)", text)
        self.assertIn("current_epoch > previous_epoch + 1", text)
        self.assertIn('"skip_reason": skip_reason', text)
        self.assertIn("FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS", text)
        self.assertIn("--always-fetch-min-interval-seconds=$FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS", text)
        self.assertIn("FILE_TIMESTAMP_GATED_SEED_REFRESH_ENABLED", text)
        self.assertIn('FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS="${FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS:-$FILE_SEED_STALE_SECONDS}"', text)
        self.assertIn('FILE_NESTED_UNCHANGED_SEED_STALE_SECONDS="${FILE_NESTED_UNCHANGED_SEED_STALE_SECONDS:-$FILE_NESTED_STALE_SECONDS}"', text)
        self.assertIn('FILE_NESTED2_UNCHANGED_NESTED_STALE_SECONDS="${FILE_NESTED2_UNCHANGED_NESTED_STALE_SECONDS:-$FILE_NESTED2_STALE_SECONDS}"', text)
        self.assertIn("seed timestamp gate active", text)
        self.assertIn("FILE_SEED_URL_LIST_CHANGED == 0", text)
        self.assertIn("file_seed_urls.next", text)
        self.assertIn('FILE_SEED_EFFECTIVE_STALE_SECONDS="$FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS"', text)
        self.assertIn('FILE_NESTED_EFFECTIVE_STALE_SECONDS="$FILE_NESTED_UNCHANGED_SEED_STALE_SECONDS"', text)
        self.assertIn('FILE_NESTED2_EFFECTIVE_STALE_SECONDS="$FILE_NESTED2_UNCHANGED_NESTED_STALE_SECONDS"', text)
        self.assertNotIn("FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS > FILE_SEED_EFFECTIVE_STALE_SECONDS", text)
        self.assertIn("build_files_stage_timings.py", text)
        self.assertIn("klms_cleanup_runtime_tmp_if_enabled", text)
        self.assertIn("download_results_are_safe_to_prune", text)
        self.assertIn("download failed; prune skipped", text)
        self.assertLess(
            text.index(
                'download_results_are_safe_to_prune "$DOWNLOAD_RESULT_JSON" "$MANIFEST_JSON"'
            ),
            text.index('log_files_timing "prune start"'),
        )
        self.assertIn('if is_truthy "${KLMS_APP_RUN:-0}"; then', text)
        app_run_block = text[
            text.index('if is_truthy "${KLMS_APP_RUN:-0}"; then')
            : text.index('if is_truthy "$FILE_DRY_RUN"; then')
        ]
        self.assertIn('FILE_FORCE_DOWNLOAD="0"', app_run_block)
        self.assertNotIn('FILE_REFRESH_MODE="auto"', app_run_block)
        self.assertNotIn("FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY=", app_run_block)
        self.assertIn("manifest_layout_matches()", text)
        self.assertIn('"${FILE_REFRESH_MODE:l}" != "full"', text)
        self.assertIn('"$FILE_SEED_URL_LIST_CHANGED" == "0"', text)
        self.assertIn("deep file page fetch continuing reason=seed-urls-unchanged", text)
        self.assertIn("course_changed=$COURSE_CHANGED_COUNT", text)
        self.assertIn("all_week_changed=$ALL_WEEK_COURSE_CHANGED_COUNT", text)
        self.assertIn("TRACKED_FILE_MISSING_COUNT", text)
        self.assertNotIn("deep file page fetch skipped", text)
        self.assertNotIn("FILE_DEEP_FETCH_SKIPPED", text)
        self.assertIn("FILE_MANIFEST_SHRINK_GUARD_PERCENT", text)
        self.assertIn("FILE_ALLOW_LARGE_MANIFEST_SHRINK", text)
        self.assertIn("FILE_REFRESH_PREVIOUS_MANIFEST_SNAPSHOT", text)
        self.assertIn("large-shrink:", text)
        self.assertIn("large manifest shrink detected; preserving previous entries and merging current manifest", text)
        self.assertIn("course_file_manifest.merged.json", text)
        self.assertIn("def manifest_key(item: dict) -> str:", text)
        self.assertIn("manifest_key(entry)", text)
        self.assertIn("large manifest shrink merged previous_entries_preserved=1", text)
        self.assertIn("Refusing to continue file refresh because manifest shrank too much", text)
        self.assertIn("cleanup_legacy_scoped_file_result_artifacts", text)
        self.assertIn('rm -f \\\n    "$scoped_cache_dir/course_file_manifest.json"', text)
        self.assertIn('"$scoped_cache_dir/course_file_download_result.json"', text)
        self.assertIn('"$scoped_cache_dir/course_file_sync_preview.json"', text)
        self.assertNotIn("EXISTING_TRACKED_FILE_COUNT >= PREVIOUS_MANIFEST_COUNT )); then\n  FILE_DEEP_FETCH_SKIPPED=1", text)

    def test_doctor_reports_app_course_files_and_runtime_download_staging(self) -> None:
        text = (PROJECT_DIR / "src" / "python" / "doctor.py").read_text(encoding="utf-8")

        self.assertIn('course_files_root = data_dir / "course_files"', text)
        self.assertIn('runtime_staging_root = runtime_dir / "tmp" / "files" / "downloads"', text)
        self.assertIn("~/Downloads is not used by default", text)
        self.assertNotIn('Path.home() / "Downloads" / "KLMS Files"', text)

    def test_mac_app_files_sync_is_incremental_by_default(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        settings = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "SettingsView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('"FILE_REFRESH_MODE": runtimeConfigValue(.fileRefreshMode, default: "auto")', model)
        self.assertIn('"FETCH_COMPLETE_REUSE_SECONDS": "0"', model)
        self.assertIn('"FILE_FORCE_DOWNLOAD": "0"', model)
        self.assertIn('"FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY": runtimeBoolConfigValue(.fileSkipDownloadWhenPreviewEmpty, default: true)', model)
        self.assertIn('"FILE_KEEP_FRESH_DOWNLOADS": runtimeBoolConfigValue(.fileKeepFreshDownloads, default: false)', model)
        self.assertIn('"FILE_WEEKLY_FOLDERS_ENABLED": runtimeBoolConfigValue(.fileWeeklyFoldersEnabled, default: true)', model)
        self.assertIn('"FILE_PRESERVE_DOWNLOAD_ARCHIVE": runtimeBoolConfigValue(.filePreserveDownloadArchive, default: false)', model)
        self.assertIn('"FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS": "0"', model)
        self.assertIn('"FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS": "1800"', model)
        self.assertIn('"FILE_NESTED_UNCHANGED_SEED_STALE_SECONDS": "1800"', model)
        self.assertIn('"FILE_NESTED2_UNCHANGED_NESTED_STALE_SECONDS": "1800"', model)
        common = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")
        self.assertIn("FETCH_COMPLETE_REUSE_SECONDS", common)
        self.assertIn("FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS", common)
        self.assertIn("FILE_NESTED_UNCHANGED_SEED_STALE_SECONDS", common)
        self.assertIn("FILE_NESTED2_UNCHANGED_NESTED_STALE_SECONDS", common)
        self.assertIn('Picker("파일 탐색 모드"', settings)
        self.assertIn('allowedValues: ["auto", "quick", "full"]', settings)
        self.assertIn('ServerRelaySettingDefinition(.fileWeeklyFoldersEnabled, title: "주차/출처 폴더 사용", valueKind: .bool, defaultValue: "1")', model)
        self.assertIn('configToggle(\n                    "주차/출처 폴더 사용",\n                    .fileWeeklyFoldersEnabled,\n                    defaultValue: true', settings)
        file_picker = settings.split('Picker("파일 탐색 모드"', 1)[1].split("}", 1)[0]
        self.assertIn('Text("전체").tag("full")', file_picker)
        self.assertNotIn('configToggle("강제 재다운로드"', settings)

    def test_app_important_sync_alerts_render_above_command_controls(self) -> None:
        mac_view = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")
        ios_view = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSiOS" / "KLMSiOSApp.swift"
        ).read_text(encoding="utf-8")

        mac_root = mac_view[
            mac_view.index("struct MenuBarRootView")
            : mac_view.index("private struct WholeScreenVerticalScrollView")
        ]
        self.assertLess(mac_root.index("MacAlertBannerView("), mac_root.index("MacStableWorkspacePane(section: selectedSection)"))

        container = ios_view[
            ios_view.index("private struct CompanionScreenContainer")
            : ios_view.index("private struct CompanionScreenHeader")
        ]
        self.assertIn(".safeAreaInset(edge: .top, spacing: 0)", container)
        self.assertIn("private var attentionInset: some View", container)
        self.assertNotIn(".overlay(alignment: .top)", container)
        self.assertNotIn(".allowsHitTesting(attentionSnapshot.hasAttention)", container)
        self.assertLess(container.index("CompanionScreenHeader(title: title, model: model)"), container.index("RemoteAttentionStack("))
        self.assertEqual(ios_view.count("RemoteAttentionStack(\n"), 1)

    def test_mac_settings_are_grouped_by_tabs_without_duplicate_file_controls(self) -> None:
        settings = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "SettingsView.swift"
        ).read_text(encoding="utf-8")
        root = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("private enum SettingsTab", settings)
        self.assertIn("settingsTabBar", settings)
        self.assertIn("settingsContentPanel", settings)
        self.assertIn("settingsTabButton", settings)
        self.assertIn("ForEach(SettingsTab.allCases)", settings)
        for label in ['"로그인"', '"동기화"', '"공지"', '"파일"', '"화면/앱"']:
            self.assertIn(label, settings)
        for symbol in [
            '"person.badge.key"',
            '"arrow.triangle.2.circlepath"',
            '"checklist"',
            '"folder"',
            '"app.badge"',
        ]:
            self.assertIn(symbol, settings)

        self.assertEqual(settings.count('Picker("파일 탐색 모드"'), 1)
        sync_settings = settings.split("private var syncSettings", 1)[1].split(
            "private var noticeSettings",
            1,
        )[0]
        file_settings = settings.split("private var fileSettings", 1)[1].split(
            "private var relaySettings",
            1,
        )[0]
        self.assertNotIn('Picker("파일 탐색 모드"', sync_settings)
        self.assertIn('Picker("파일 탐색 모드"', file_settings)
        self.assertIn("SettingsView(model: model)", root)
        self.assertIn("relaySettingsCollapsed", settings)
        self.assertIn('title: "서버 릴레이"', settings)
        self.assertIn('systemImage: "network"', settings)
        self.assertNotIn("설정 > iPhone 서버 릴레이", root)
        self.assertIn("private func described", settings)
        for description in [
            "비밀번호는 저장하지 않습니다.",
            "시험과 헬프데스크 일정이 이미 같으면 캘린더 이벤트를 다시 쓰지 않습니다.",
            "읽음/중요 표시는 항상 동기화합니다.",
            "변경량 계산에서 새 파일이나 수정된 파일이 없으면 실제 다운로드 단계를 건너뜁니다.",
            "집 주소나 로컬 IP가 아니라 공개 HTTPS 주소만 입력하세요.",
            "config.env, 인증 상태, runtime, course_files는 덮어쓰지 않습니다.",
        ]:
            self.assertIn(description, settings)

    def test_mac_settings_live_inside_main_workspace(self) -> None:
        app = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacApp.swift"
        ).read_text(encoding="utf-8")
        root = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("Settings {", app)
        self.assertNotIn("SettingsView(model: model)", app)
        self.assertNotIn("@Environment(\\.openSettings)", root)
        self.assertNotIn("openSettings()", root)
        self.assertNotIn("showingSettings", root)
        self.assertNotIn("if showingSettings", root)
        self.assertIn("SettingsView(model: model)", root)

    def test_mac_app_exposes_full_file_manifest_list(self) -> None:
        menu = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")
        detail = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "DashboardDetailView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("let fileCount = DashboardFileMetricCounter.visibleCourseFileCount(", menu)
        self.assertIn("fallback: summary.serverDashboardItemsLoaded ? summary.serverFileCount : nil", menu)
        self.assertIn('Metric("파일", fileCount, detail: .files)', menu)
        self.assertIn("@State private var selectedDetail: DashboardDetailKind?", menu)
        self.assertIn("case files", detail)
        self.assertIn("FileManifestListView(files: fileData.manifestFiles, filters: filters, model: model)", detail)
        self.assertIn("manifestFiles = snapshot.courseFileManifest.map", detail)
        self.assertIn("NoticeAttachmentDisplay", detail)
        self.assertIn('Text("첨부 파일")', detail)
        self.assertIn("notice.attachmentItems.map", detail)
        self.assertIn("NSWorkspace.shared.activateFileViewerSelecting", detail)

    def test_mac_app_file_lists_have_sort_controls(self) -> None:
        detail = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "DashboardDetailView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("private enum DashboardFileSortOption", detail)
        self.assertIn('"과목"', detail)
        self.assertIn('"종류"', detail)
        self.assertIn('"파일명"', detail)
        self.assertIn('"경로"', detail)
        self.assertIn('"최신"', detail)
        self.assertLess(
            detail.index("case recent"),
            detail.index("case course"),
            "파일 정렬 옵션은 최신이 가장 왼쪽에 오도록 recent가 첫 case여야 합니다.",
        )
        self.assertIn("private struct FileSortPickerView", detail)
        self.assertGreaterEqual(detail.count("FileSortPickerView(selection: $sortOption)"), 2)
        self.assertGreaterEqual(detail.count(".sorted(by: sortOption)"), 2)
        self.assertEqual(detail.count("@State private var sortOption = DashboardFileSortOption.recent"), 2)
        self.assertNotIn("@State private var sortOption = DashboardFileSortOption.course", detail)
        self.assertNotIn("@State private var sortOption = DashboardFileSortOption.name", detail)
        self.assertNotIn("@State private var sortOption = DashboardFileSortOption.path", detail)
        self.assertIn("selection = option", detail)
        self.assertNotIn(".id(sortOption.rawValue)", detail)
        self.assertIn("sortPath: entry.relativePath", detail)
        self.assertIn("recencyText: fileRecencyText(", detail)
        self.assertIn("usableFileTimestampText(klmsTimestampText)", detail)
        self.assertIn("usableFileTimestampText(klmsTimestamp)", detail)
        self.assertIn("usableFileTimestampText(localDownloadedAt)", detail)
        self.assertNotIn("recencyText: entry.localDownloadedAt", detail)
        self.assertNotIn('recencyText: manifest?.localDownloadedAt ?? ""', detail)
        self.assertIn("klmsTimestampEpoch: entry.klmsTimestampEpoch", detail)
        self.assertIn("fileprivate var klmsSortEpoch: Int = Int.min", detail)
        self.assertIn("klmsSortEpoch = klmsTimestampEpoch ?? ServerRelaySyncItem.dashboardTimestampEpoch(from: trimmedRecency) ?? Int.min", detail)
        self.assertIn("let leftKLMSTimestamp = lhs.klmsSortEpoch", detail)
        self.assertIn("KLMS 등록 시각이 있는 파일은 KLMS 최신순, 시각이 없는 파일은 내려받은 시각 최신순으로 정렬", detail)
        self.assertIn("Label(item.fileKindLabel, systemImage: item.fileKindIcon)", detail)
        self.assertIn('"공지 첨부"', detail)
        self.assertIn('"과제 첨부"', detail)
        self.assertIn('"과제 관련"', detail)
        self.assertIn('"시험/퀴즈"', detail)
        self.assertIn("containsTokenPrefix(in: text, prefixes: [\"hw\", \"wa\", \"pa\"])", detail)
        self.assertIn('"강의 자료"', detail)
        self.assertIn("localizedStandardCompare(rightRecency) == .orderedDescending", detail)
        self.assertIn("fileSortPath(from:", detail)

    def test_mac_app_integration_status_is_always_expanded(self) -> None:
        menu = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        external_status = menu[
            menu.index("private struct ExternalIntegrationStatusView")
            : menu.index("private enum IntegrationHealth")
        ]
        sidebar_status = menu[
            menu.index("private struct DashboardRuntimePanelView")
            : menu.index("private struct MacRailStatusLine")
        ]
        self.assertNotIn("@State private var isExpanded = false", external_status)
        self.assertNotIn("@AppStorage", external_status)
        self.assertNotIn("isExpanded.toggle()", external_status)
        self.assertNotIn('help(isExpanded ? "연동 상태 접기" : "연동 상태 펼치기")', external_status)
        self.assertNotIn("if !isExpanded", external_status)
        self.assertNotIn("IntegrationStatusCompactStrip(statuses: statuses)", external_status)
        self.assertNotIn("if isExpanded", external_status)
        self.assertIn("IntegrationStatusTile(status: status)", external_status)
        self.assertNotIn("@State private var isExpanded = false", sidebar_status)
        self.assertNotIn("if isExpanded", sidebar_status)
        self.assertIn('Label("연동 상태", systemImage: "link")', sidebar_status)

    def test_mac_app_hides_zero_dashboard_metrics_and_detail(self) -> None:
        menu = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("].filter { $0.value > 0 }", menu)
        self.assertIn("scopedPresentation.activeDetail(", menu)
        self.assertIn('Text("표시할 대시보드 항목이 없습니다.")', menu)
        self.assertIn("DashboardDetailPanelView(\n            kind: kind,\n            model: model,", menu)
        self.assertRegex(
            menu,
            r'Metric\("격리", counts\.quarantine, detail: \.quarantine\),\s*'
            r'Metric\("과제 후보", summary\.assignmentCandidateCount, detail: \.assignmentCandidates\),',
        )

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
            self.assertIn("KLMS_SAFARI_BACKGROUND_WINDOW_MODE", text)
            self.assertIn("prepareBackgroundWindow", text)
            self.assertIn("windowRef.miniaturized = true", text)
            self.assertIn("isBackgroundWindow", text)
            self.assertNotIn("moveWindowOffscreen", text)
            self.assertNotIn("windowRef.bounds", text)

        self.assertIn('KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED="1"', config)
        self.assertIn('KLMS_SAFARI_BACKGROUND_WINDOW_MODE="minimize"', config)
        self.assertIn('KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED="1"', config)

    def test_safari_automation_defaults_to_reusing_dedicated_background_windows(self) -> None:
        fetch_text = (PROJECT_DIR / "src" / "js" / "fetch_pages_with_safari.js").read_text(
            encoding="utf-8"
        )
        download_text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        login_text = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(encoding="utf-8")

        self.assertIn('envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "1")', fetch_text)
        self.assertIn("if (!safariWasRunning)", fetch_text)
        self.assertIn("if (reuseExistingWindowEnabled)", fetch_text)
        self.assertIn("!safariWasRunning\n  );", fetch_text)
        self.assertIn("findReusableEmptyWindow(safari, backgroundWindowEnabled)", fetch_text)
        self.assertIn("isEmptySafariStartPageUrl", fetch_text)
        self.assertIn("Failed to create a dedicated Safari fetch window", fetch_text)
        self.assertIn('return "minimize";', fetch_text)
        self.assertIn('if (configured === "offscreen")', fetch_text)
        self.assertIn('envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "1")', download_text)
        self.assertIn("if (!safeValue(() => safari.running()))", download_text)
        self.assertIn("let safariLaunchedByScript = false", download_text)
        self.assertIn("safariLaunchedByScript = true", download_text)
        self.assertIn("reuseExistingWindowEnabled ? findKlmsWindow", download_text)
        self.assertIn("reuseExistingWindowEnabled && safariLaunchedByScript", download_text)
        self.assertIn("findReusableEmptyWindow(safari, backgroundWindowEnabled)", download_text)
        self.assertIn("isEmptySafariStartPageUrl", download_text)
        self.assertIn('return "minimize";', download_text)
        self.assertIn('if (configured === "offscreen")', download_text)
        self.assertIn('make new document with properties {URL:targetUrl}', login_text)
        self.assertIn("reuseKlmsWindow", login_text)
        self.assertIn("repeat with candidateWindow in windows", login_text)
        self.assertIn('set URL of current tab of targetWindow to targetUrl', login_text)
        model_text = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        app_environment = model_text[
            model_text.index("var appRunEnvironment")
            : model_text.index("var serverRelayConfigured")
        ]
        self.assertIn('"KLMS_APP_NON_INTRUSIVE_SAFARI": "1"', app_environment)
        self.assertIn('"KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED": runtimeBoolConfigValue(.safariBackgroundWindowEnabled, default: true)', app_environment)
        self.assertIn('"KLMS_SAFARI_BACKGROUND_WINDOW_MODE": runtimeConfigValue(.safariBackgroundWindowMode, default: "minimize")', app_environment)
        self.assertIn('"KLMS_SAFARI_RESTORE_FRONTMOST_ENABLED": "0"', app_environment)
        self.assertIn('"KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE": "0"', app_environment)
        self.assertIn('"LOGIN_PROMPT_OPEN_SAFARI": "0"', app_environment)
        self.assertIn('"KLMS_LOGIN_ASSIST_ENABLED": "1"', app_environment)
        self.assertIn('"KLMS_LOGIN_ASSIST_MODE": "manual-digits"', app_environment)
        self.assertIn('"KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": "1"', app_environment)
        self.assertNotIn('"KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED": "1"', app_environment)
        self.assertIn('"KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED": runtimeBoolConfigValue(.safariReuseExistingWindowEnabled, default: true)', app_environment)
        self.assertIn("safariRestoreFrontmostEnabled", fetch_text)
        self.assertIn("safariRestoreFrontmostEnabled", download_text)
        self.assertIn('title: "KLMS Sync Safari 창 재사용"', model_text)
        self.assertIn('defaultValue: "1"', model_text)

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
        self.assertIn('DOWNLOAD_PARALLELISM="${16:-1}"', text)
        self.assertIn('DIRECT_FETCH_MAX_BYTES="${17:-26214400}"', text)

    def test_assignment_processor_is_not_part_of_core_sync(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_notice_bridge.js").read_text(encoding="utf-8")

        self.assertNotIn("process_klms_assignments", text)
        self.assertNotIn("assignment-processor", text)

    def test_core_state_build_uses_v2_engine(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")

        build_stage_index = text.index("const buildNoteBaseCommand = [")
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
if (looksLikeLoginPage({ url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2", title: "CS.30000_2026_1 : Notice", html: "<h2>공지</h2><div>비밀번호 입력</div><input type=\"password\">" })) {
  throw new Error("authenticated notice article password modal was classified as login");
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
        text = (PROJECT_DIR / "src" / "js" / "sync_reminders_bridge.js").read_text(encoding="utf-8")
        sync_text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("function buildRemindersDesiredHash", text)
        self.assertIn("REMINDERS_DESIRED_HASH_VERSION", text)
        self.assertIn("buildDesiredReminders(normalizeSyncEntries(state.content), options)", text)
        self.assertIn("completedReminderRetentionDays", text)
        self.assertIn("deviceAlertMode", text)
        self.assertIn("recreateStageAlertList: Boolean(options.recreateStageAlertList)", text)
        self.assertIn("{ recreateList: reminderOptions.recreateStageAlertList === true }", text)
        self.assertIn("new Set(knownIdentifiers)", text)
        self.assertIn("knownIdentifierLimit", text)
        self.assertIn('"REMINDER_RECREATE_STAGE_ALERT_LIST",\n      false', sync_text)
        self.assertIn('REMINDER_RECREATE_STAGE_ALERT_LIST="0"', config)
        self.assertNotIn("readText(outputState) +", text)

    def test_server_relay_does_not_publish_location_or_submission_detail(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("detail: serverRelayPublicText(item.coverageSummary.nilIfBlank)", model)
        self.assertIn("private func serverRelayLooksPrivate", model)
        self.assertNotIn("item.location.nilIfBlank ?? item.submission", model)

    def test_mac_log_block_uses_outer_vertical_scroll(self) -> None:
        view = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("WholeScreenVerticalScrollView", view)
        self.assertNotIn("GeometryReader { geometry in", view)
        self.assertIn("ScrollView(.vertical, showsIndicators: true)", view)
        self.assertNotIn("minHeight: geometry.size.height", view)
        self.assertNotIn("ScrollView {\n                VStack(alignment: .leading, spacing: 16)", view)
        self.assertIn("private struct LogTextBlock", view)
        self.assertNotIn("ScrollView(.horizontal)", view)
        self.assertNotIn("ScrollView([.vertical, .horizontal])", view)
        self.assertNotIn(".frame(minHeight: 120, maxHeight: 280)", view)

    def test_reminders_deduplicate_assignment_desired_items_before_sync(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const assert = require("assert");
const source = fs.readFileSync("src/js/sync_reminders_bridge.js", "utf8");
eval(source);

const entries = [
  {
    category: "assignment",
    course: "Course",
    title: "Report",
    due: "",
    sync_due: "",
    url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=42",
    instructions: "missing",
  },
  {
    category: "assignment",
    course: "Course",
    title: "Report",
    due: "2099.06.01 23:59",
    sync_due: "2099-06-01T23:59:00+09:00",
    url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=42",
    instructions: "full",
  },
  {
    category: "assignment",
    course: "Course",
    title: "Report duplicate",
    due: "2099.06.01 23:59",
    sync_due: "2099-06-01T23:59:00+09:00",
    url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=42",
    instructions: "duplicate",
  },
];

const desired = buildDesiredReminders(entries, { deviceAlertsEnabled: false });
assert.equal(desired.active.length, 1);
assert.equal(desired.issues.length, 0);
assert.ok(desired.active[0].identifier.startsWith("assignment:"));
assert.ok(desired.active[0].aliasIdentifiers.includes("42"));

const crossSourceEntries = [
  {
    category: "assignment",
    course: "알고리즘 개론",
    title: "Written Assignment 4",
    due: "2099년 6월 9일 오후 11:59",
    sync_due: "2099-06-09T23:59:00+09:00",
    url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=1234595",
    instructions: "source assignment",
  },
  {
    category: "assignment",
    course: "알고리즘 개론",
    title: "Written Assignment 4",
    due: "2099년 6월 9일 오후 11:59",
    sync_due: "2099-06-09T23:59:00+09:00",
    url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=435776",
    instructions: "notice assignment with details",
  },
];
const crossSourceDesired = buildDesiredReminders(crossSourceEntries, { deviceAlertsEnabled: false });
assert.equal(crossSourceDesired.active.length, 1);
assert.equal(crossSourceDesired.issues.length, 0);
assert.equal(
  crossSourceDesired.active[0].identifier,
  "assignment:%EC%95%8C%EA%B3%A0%EB%A6%AC%EC%A6%98%20%EA%B0%9C%EB%A1%A0:written%20assignment%204:2099-06-09t23%3A59%3A00%2B09%3A00"
);
assert.ok(crossSourceDesired.active[0].aliasIdentifiers.includes("1234595"));
assert.ok(crossSourceDesired.active[0].aliasIdentifiers.includes("435776"));
assert.ok(
  assignmentOverrideKeysForEntry(crossSourceEntries[1]).includes(
    "알고리즘 개론::Written Assignment 4::2099-06-09T23:59:00+09:00"
  )
);
assert.ok(
  !assignmentOverrideKeysForEntry(crossSourceEntries[1]).includes(
    "알고리즘 개론::Written Assignment 4"
  )
);

const distinctCourseboardEntries = [
  {
    category: "assignment",
    course: "영미 단편소설",
    title: "Written Assignment 2",
    due: "2099년 5월 20일 오후 11:59",
    sync_due: "2099-05-20T23:59:00+09:00",
    url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=432001",
  },
  {
    category: "assignment",
    course: "영미 단편소설",
    title: "Programming Assignment 2",
    due: "2099년 5월 21일 오후 11:59",
    sync_due: "2099-05-21T23:59:00+09:00",
    url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=432002",
  },
];
const distinctCourseboardDesired = buildDesiredReminders(
  distinctCourseboardEntries,
  { deviceAlertsEnabled: false }
);
assert.equal(distinctCourseboardDesired.active.length, 2);
assert.ok(distinctCourseboardDesired.active.some((item) => item.aliasIdentifiers.includes("432001")));
assert.ok(distinctCourseboardDesired.active.some((item) => item.aliasIdentifiers.includes("432002")));
"""
        subprocess.run(
            [node, "-e", script],
            cwd=PROJECT_DIR,
            check=True,
            capture_output=True,
            text=True,
        )

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
        text = "\n".join(
            [
                (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
                    encoding="utf-8"
                ),
                (PROJECT_DIR / "src" / "js" / "sync_notice_bridge.js").read_text(
                    encoding="utf-8"
                ),
            ]
        )
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
        self.assertIn("verify_reminders_counts.js", text)
        self.assertIn("--issue-list=", text)
        self.assertIn("--alert-list=", text)
        self.assertIn("--reminders-lines", text)
        self.assertNotIn("summary of every event of calendar", text)

    def test_file_refresh_cleans_old_term_manifest_entries_after_term_catalog(self) -> None:
        text = (PROJECT_DIR / "bin" / "refresh_course_files.sh").read_text(encoding="utf-8")

        self.assertIn("FILE_CLEANUP_OLD_TERM_FILES", text)
        self.assertIn("course_file_old_term_cleanup_result.json", text)
        self.assertIn("cleanup_old_term_course_files.py", text)
        self.assertIn("--academic-terms-json \"$ACADEMIC_TERM_CATALOG_JSON\"", text)
        self.assertLess(
            text.index("build-term-catalog"),
            text.index("cleanup_old_term_course_files.py"),
        )
        self.assertLess(
            text.index("cleanup_old_term_course_files.py"),
            text.index("build_course_file_sync_preview.py"),
        )

    def test_calendar_sync_uses_repo_swift_module_cache_without_deprecated_fallback(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8")
        bridge = (PROJECT_DIR / "src" / "js" / "sync_calendar_bridge.js").read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(encoding="utf-8")

        self.assertIn("sync_calendar_bridge.js", text)
        self.assertIn("SWIFT_MODULE_CACHE_PATH=", bridge)
        self.assertIn("CLANG_MODULE_CACHE_PATH=", bridge)
        self.assertIn("-module-cache-path", bridge)
        self.assertIn("sync_klms_calendar_suite.swift", bridge)
        self.assertNotIn("sync_klms_calendar_jxa.js", text)
        self.assertNotIn("sync_klms_calendar_jxa.js", bridge)
        self.assertNotIn("deprecated-calendar-jxa-fallback", text)
        self.assertNotIn("deprecated-calendar-jxa-fallback", bridge)
        self.assertNotIn("CALENDAR_SYNC_APPLESCRIPT_FALLBACK", config)

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

    def test_mac_app_build_is_staged_and_excludes_user_override_data(self) -> None:
        build_script = (PROJECT_DIR / "tools" / "build_klms_mac_app.sh").read_text(
            encoding="utf-8"
        )
        payload_allowlist = (
            PROJECT_DIR / "apps" / "KLMSync" / "EnginePayloadAllowlist.txt"
        ).read_text(encoding="utf-8").splitlines()
        python_payload_allowlist = (
            PROJECT_DIR / "apps" / "KLMSync" / "EnginePythonPayloadAllowlist.txt"
        ).read_text(encoding="utf-8").splitlines()
        relay_installer = (
            PROJECT_DIR / "tools" / "install_klms_relay_agent.sh"
        ).read_text(encoding="utf-8")
        relay_dockerfile = (
            PROJECT_DIR / "deploy" / "relay" / "Dockerfile"
        ).read_text(encoding="utf-8")

        self.assertIn('TARGET_APP_BUNDLE="${OUTPUT_APP:-$DIST_DIR/$APP_NAME.app}"', build_script)
        self.assertIn('mktemp -d "$TARGET_APP_PARENT/.klms-sync-app-build.XXXXXX"', build_script)
        self.assertIn('mv "$TARGET_APP_BUNDLE" "$BACKUP_APP_BUNDLE"', build_script)
        self.assertIn('mv "$APP_BUNDLE" "$TARGET_APP_BUNDLE"', build_script)
        self.assertIn('restore_previous_app', build_script)
        self.assertIn('if ! restore_previous_app; then', build_script)
        self.assertIn('Previous app preserved at: $BACKUP_APP_BUNDLE', build_script)
        self.assertIn("__klms_prov", build_script)
        self.assertIn("KLMSAppBuildProvenance.json", build_script)
        self.assertIn("verify_klms_app_provenance.py", build_script)
        self.assertIn("final_git_head", build_script)
        self.assertIn("final_git_tree", build_script)
        self.assertIn("final_git_status", build_script)
        self.assertIn('VENDORED_PYTHON_PACKAGES="$BUILD_ROOT/vendor/python-packages"', build_script)
        self.assertIn('source_path="$BUILD_ROOT/$relative_path"', build_script)
        self.assertIn('"$BUILD_ROOT/tools/verify_klms_engine_payload.py"', build_script)
        self.assertIn('"$BUILD_ROOT/tools/verify_klms_app_provenance.py"', build_script)
        self.assertIn('git -C "$ROOT_DIR" archive --format=tar "$source_revision"', build_script)
        self.assertIn('BUILD_ROOT="$SOURCE_SNAPSHOT_DIR"', build_script)
        self.assertGreaterEqual(build_script.count("__klms_prov"), 2)
        self.assertIn('PYTHON_PAYLOAD_ALLOWLIST="$APP_PACKAGE_DIR/EnginePythonPayloadAllowlist.txt"', build_script)
        self.assertIn('done < "$PYTHON_PAYLOAD_ALLOWLIST"', build_script)
        self.assertNotIn('ditto --norsrc "$VENDORED_PYTHON_PACKAGES"', build_script)
        self.assertNotIn(
            'ditto --norsrc "$ROOT_DIR/runtime/python-packages" "$PAYLOAD_ROOT/python-packages"',
            build_script,
        )
        self.assertNotIn("  manual_assignment_overrides.json\n", build_script)
        self.assertIn('PAYLOAD_ALLOWLIST="$APP_PACKAGE_DIR/EnginePayloadAllowlist.txt"', build_script)
        self.assertIn('done < "$PAYLOAD_ALLOWLIST"', build_script)
        self.assertIn('"schemaVersion": 2', build_script)
        self.assertIn('"sourceRevision": source_revision', build_script)
        self.assertIn('"pythonAllowlistSHA256"', build_script)
        self.assertIn("rev-parse --verify 'HEAD^{commit}'", build_script)
        self.assertIn("unable to determine the app worktree state", build_script)
        self.assertIn('verify_klms_engine_payload.py', build_script)
        self.assertNotIn('for directory in src bin examples docs tools', build_script)
        self.assertIn("tools/klms_relay_server.mjs", payload_allowlist)
        self.assertIn("tools/klms_bounded_rate_window.mjs", payload_allowlist)
        self.assertIn("tools/klms_public_log_redactor.mjs", payload_allowlist)
        self.assertIn("tools/install_klms_relay_agent.sh", payload_allowlist)
        self.assertNotIn("docs", {path.split("/", 1)[0] for path in payload_allowlist})
        self.assertNotIn("src/swift/capture_notice_native_state.swift", payload_allowlist)
        self.assertNotIn("src/swift/decode_qr_image.swift", payload_allowlist)
        for relative_path in payload_allowlist:
            self.assertTrue((PROJECT_DIR / relative_path).is_file(), relative_path)
        for relative_path in python_payload_allowlist:
            self.assertTrue(
                (PROJECT_DIR / "vendor" / "python-packages" / relative_path).is_file(),
                relative_path,
            )
        for relay_runtime_file in (
            "klms_relay_server.mjs",
            "klms_bounded_rate_window.mjs",
            "klms_public_log_redactor.mjs",
            "run_klms_relay_agent.sh",
        ):
            self.assertIn(relay_runtime_file, relay_installer)
        for relay_module in (
            "klms_relay_server.mjs",
            "klms_bounded_rate_window.mjs",
            "klms_public_log_redactor.mjs",
        ):
            self.assertIn(relay_module, relay_dockerfile)

    def test_private_readiness_builds_an_isolated_app_copy(self) -> None:
        readiness = (PROJECT_DIR / "tools" / "verify_klms_app_readiness.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("READINESS_TEMP_DIR", readiness)
        self.assertIn('OUTPUT_APP="$MAC_APP_PATH"', readiness)
        self.assertIn('rm -rf "$READINESS_TEMP_DIR"', readiness)
        self.assertGreaterEqual(readiness.count('KLMS_MAC_APP_PATH="$MAC_APP_PATH"'), 4)

    def test_readiness_fails_closed_when_git_metadata_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tools = root / "tools"
            tools.mkdir()
            readiness = tools / "verify_klms_app_readiness.sh"
            shutil.copy2(PROJECT_DIR / "tools" / "verify_klms_app_readiness.sh", readiness)
            readiness.chmod(0o755)
            environment = {
                **os.environ,
                "KLMS_MAC_APP_PATH": str(root / "KLMS Sync.app"),
                "KLMS_READINESS_SWIFT_TESTS": "0",
                "KLMS_READINESS_MAC": "0",
                "KLMS_READINESS_IOS_BUILD": "0",
                "KLMS_READINESS_IOS_LAUNCH": "0",
            }
            result = subprocess.run(
                [str(readiness)],
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("candidate=unavailable", result.stderr)
            self.assertIn("git_metadata=invalid", result.stderr)
            self.assertIn("failed=git-metadata:1", result.stderr)

    def test_quality_gate_inventory_is_complete_and_sha_bound(self) -> None:
        inventory = json.loads(
            (PROJECT_DIR / "docs" / "quality-gate-inventory.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertEqual(inventory["schemaVersion"], 1)
        self.assertEqual(sum(inventory["scoreModel"]["areas"].values()), 100)
        self.assertEqual(
            inventory["scoreModel"]["caps"]["missingMandatoryExternalEvidence"],
            94,
        )
        self.assertTrue(inventory["candidateBinding"]["cleanWorktreeRequired"])
        self.assertTrue(inventory["candidateBinding"]["fullCommitSHARequired"])
        gate_ids = [gate["id"] for gate in inventory["automatedGates"]]
        self.assertEqual(len(gate_ids), len(set(gate_ids)))
        for gate in inventory["automatedGates"]:
            self.assertGreater(gate["execution"]["timeoutSeconds"], 0)
            self.assertGreater(gate["execution"]["maxOutputBytes"], 0)
            self.assertLessEqual(gate["execution"]["maxOutputBytes"], 96 * 1024 * 1024)
        swift_gate = next(
            gate for gate in inventory["automatedGates"] if gate["id"] == "swift-clients"
        )
        self.assertIn("--enable-xctest", swift_gate["command"])
        self.assertIn("--disable-swift-testing", swift_gate["command"])
        self.assertEqual(swift_gate["execution"]["workingDirectory"], ".")
        self.assertEqual(swift_gate["execution"]["environment"], {})
        self.assertIn("<isolated-path>", swift_gate["execution"]["steps"][0]["argv"])
        mac_runtime_gate = next(
            gate for gate in inventory["automatedGates"] if gate["id"] == "mac-runtime"
        )
        self.assertEqual(
            mac_runtime_gate["execution"]["environment"]["KLMS_READINESS_IOS_BUILD"],
            "0",
        )
        self.assertEqual(
            mac_runtime_gate["execution"]["environment"]["KLMS_READINESS_IOS_LAUNCH"],
            "0",
        )
        self.assertEqual(
            inventory["releaseEvidenceReceipt"]["gateRunner"],
            "tools/run_release_gate.sh <gate-id>",
        )
        receipt = inventory["releaseEvidenceReceipt"]
        self.assertEqual(receipt["reviewRecorder"], "tools/record_release_review.py")
        self.assertTrue(receipt["exactCommitRequired"])
        self.assertTrue(receipt["cleanWorktreeRequired"])
        self.assertTrue(receipt["outputOutsideRepositoryRequired"])
        self.assertEqual(receipt["appPayloadSchemaVersion"], 2)
        self.assertEqual(
            set(inventory["independentReviewGates"]),
            {
                "goal-and-constraint",
                "code-quality",
                "security-and-privacy",
                "hands-on-runtime",
                "visual-and-accessibility",
            },
        )
        self.assertEqual(
            set(inventory["mandatoryExternalEvidence"]),
            {
                "physical-iphone-and-ipad-matrix",
                "controlled-impaired-wan-and-reconnect",
                "voiceover-switch-control-and-hardware-keyboard",
                "multi-hour-reconnect-sync-cancel-transfer-soak",
            },
        )

    def test_github_workflows_pin_actions_and_run_restore_recovery_tests(self) -> None:
        workflows = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((PROJECT_DIR / ".github" / "workflows").glob("*.yml"))
        )

        self.assertNotRegex(workflows, r"uses: actions/[^@\s]+@v\d+")
        self.assertEqual(
            workflows.count("uses: actions/checkout@"),
            workflows.count("persist-credentials: false"),
        )
        self.assertIn("node --test deploy/relay/test_restore_db.mjs", workflows)

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
        self.assertIn("status.loginRequired = false", model)
        self.assertIn('content.title = "KLMS 인증 완료"', model)
        self.assertIn('content.body = "로그인 인증이 완료됐습니다. 동기화를 계속 진행합니다."', model)
        self.assertIn('showTransientAuthStatus("인증 완료됨")', model)
        self.assertIn("notifiedAlreadyLoggedInForCurrentRun", model)
        self.assertIn("showAlreadyLoggedInStatusIfNeeded()", model)
        self.assertIn('showTransientAuthStatus("이미 로그인됨")', model)
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
        self.assertIn("configureServerRelayEventStream()", ios_app)
        self.assertIn('webSocketTask(with: store.eventStreamRequest(role: "client"))', ios_app)
        self.assertIn("task.receive()", ios_app)
        self.assertIn("RelayEndpointCompletionConsumer.consume(operations)", ios_app)
        self.assertIn("if scope.fetchesSyncData { endpoints.append(.syncData) }", ios_app)
        self.assertIn("let shouldLoadSyncData = endpoint == .syncData", ios_app)
        self.assertNotIn(".withoutSyncData", ios_app)
        self.assertIn("await model.bootstrapServerRelayFromLaunch()", ios_app)
        self.assertIn("syncDataNeedsRefresh = true", ios_app)
        self.assertNotIn("pendingCancelCommandID == nil ? 350_000_000 : 250_000_000", ios_app)

    def test_ios_companion_notifies_report_refresh_result(self) -> None:
        ios_app = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSiOS" / "KLMSiOSApp.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("import UserNotifications", ios_app)
        self.assertIn("KLMSCompanionNotificationDelegate", ios_app)
        self.assertIn("willPresent notification", ios_app)
        self.assertIn("trackedReportNotificationCommandIDs", ios_app)
        self.assertIn("KLMSTrackedReportNotificationCommandIDs", ios_app)
        self.assertIn("let savedCommand = try await serverRelayStore.createReturningCommand(command)", ios_app)
        self.assertIn("trackReportNotificationIfNeeded(for: savedCommand)", ios_app)
        self.assertNotIn("trackReportNotificationIfNeeded(for: command)", ios_app)
        self.assertIn("handleReportNotificationUpdates(overlaidCommands)", ios_app)
        self.assertIn("command.kind == .report", ios_app)
        self.assertIn("displayStatus.isTerminal", ios_app)
        self.assertIn('title = "요약 갱신 완료"', ios_app)
        self.assertIn('title = "요약 갱신 실패"', ios_app)
        self.assertIn('title = "요약 갱신 확인 지연"', ios_app)
        self.assertIn("UNUserNotificationCenter.current()", ios_app)
        self.assertIn("requestAuthorization(options: [.alert, .sound])", ios_app)
        self.assertIn("klms-report-refresh-", ios_app)

    def test_public_project_uses_generic_connection_and_signing_values(self) -> None:
        ios_project = (
            PROJECT_DIR
            / "apps"
            / "KLMSync"
            / "Xcode"
            / "KLMSiOS"
            / "KLMSiOS.xcodeproj"
            / "project.pbxproj"
        ).read_text(encoding="utf-8")
        windows_package = (
            PROJECT_DIR / "apps" / "KLMSyncWindows" / "package.json"
        ).read_text(encoding="utf-8")
        remote_models = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSShared" / "RemoteCommandModels.swift"
        ).read_text(encoding="utf-8")
        ios_defaults = (
            PROJECT_DIR / "apps" / "KLMSync" / "Config" / "KLMSiOS.defaults.xcconfig"
        ).read_text(encoding="utf-8")
        gitignore = (PROJECT_DIR / ".gitignore").read_text(encoding="utf-8")
        generator = (PROJECT_DIR / "tools" / "generate_klms_ios_xcode_project.py").read_text(
            encoding="utf-8"
        )
        combined = "\n".join([ios_project, windows_package, remote_models, ios_defaults, generator])

        self.assertIn("KLMSiOS.defaults.xcconfig", ios_project)
        self.assertIn("CredentialPersistence.swift in Sources", ios_project)
        self.assertIn("LiveStatePolicies.swift in Sources", ios_project)
        self.assertIn("RelayFileDownloadPolicy.swift in Sources", ios_project)
        self.assertIn("RelaySnapshotStream.swift in Sources", ios_project)
        self.assertIn('"CredentialPersistence.swift"', generator)
        self.assertIn('"LiveStatePolicies.swift"', generator)
        self.assertIn('"RelayFileDownloadPolicy.swift"', generator)
        self.assertIn('"RelaySnapshotStream.swift"', generator)
        self.assertIn('DEVELOPMENT_TEAM = "$(KLMS_IOS_DEVELOPMENT_TEAM)";', ios_project)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "$(KLMS_IOS_BUNDLE_IDENTIFIER)";', ios_project)
        self.assertIn("KLMS_IOS_DEVELOPMENT_TEAM =", ios_defaults)
        self.assertIn("KLMS_IOS_BUNDLE_IDENTIFIER = com.local.KLMSync.iOS", ios_defaults)
        self.assertIn('#include? "KLMSiOS.local.xcconfig"', ios_defaults)
        self.assertIn("apps/KLMSync/Config/KLMSiOS.local.xcconfig", gitignore)
        self.assertIn('"appId": "com.local.klmssync.windows"', windows_package)
        self.assertIn('"com.local.KLMSync.localRemoteToken"', remote_models)
        self.assertIn("legacyServiceByteGroups", remote_models)
        self.assertIn("backend.save(trimmedToken, account: account, service: service)", remote_models)
        self.assertIn("delete(account: account, service: legacyService)", remote_models)
        self.assertNotIn("com." + "personal", combined)
        self.assertNotIn("VCT" + "W5T" + "9B4K", combined)
        self.assertNotIn("gs" + "36212js", combined)

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
        self.assertIn("LocalRemoteTokenStore.load(account: \"server-relay-mac\")", model)
        self.assertIn("LocalRemoteTokenStore.load(account: \"server-relay-client-mac\")", model)
        self.assertIn("LocalRemoteTokenStore.load(account: \"server-relay-worker-mac\")", model)
        self.assertIn('serverRelayConnectionAccount = "server-relay-connection-mac"', model)
        self.assertIn("case let .persisted(legacyCleanupPending)", model)
        self.assertIn("serverRelayURL = nextConnection.serverURL", model)
        self.assertIn("serverRelayClientToken = nextConnection.clientToken", model)
        self.assertIn("serverRelayWorkerToken = nextConnection.workerToken", model)
        self.assertIn("serverRelayCredentialCleanupPending = legacyCleanupPending", model)
        self.assertIn("decodeServerRelayConnection(", model)
        self.assertIn("LocalRemoteTokenStore.save(payload, account: serverRelayConnectionAccount)", model)
        self.assertIn("removeLegacyServerRelayCredentials()", model)
        self.assertLess(
            model.index("LocalRemoteTokenStore.save(payload, account: serverRelayConnectionAccount)"),
            model.index("let legacyCleanupCompleted = removeLegacyServerRelayCredentials()"),
        )
        self.assertIn("func delete(account: String, service: String) -> Bool", shared)
        self.assertIn("enum LocalRemoteTokenKeychainLoadResult: Equatable", shared)
        self.assertIn("case notFound", shared)
        self.assertIn("case failure", shared)
        self.assertIn("if status == errSecItemNotFound", shared)
        self.assertIn("guard deleteLegacyServices(account: account, backend: backend) else", shared)
        self.assertIn("status == errSecSuccess || status == errSecItemNotFound", shared)
        self.assertIn("private static func deleteAllServerRelayCredentials() -> Bool", model)
        self.assertIn(
            '["server-relay-client-mac", "server-relay-worker-mac", "server-relay-mac"]',
            model,
        )
        self.assertIn("if !LocalRemoteTokenStore.delete(account: account)", model)
        self.assertIn("guard deleteLegacyServerRelayKeychainCredentials(),", model)
        self.assertIn("UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalRemoteTokenKey)", model)
        self.assertIn("pasteboardClearTask", model)
        self.assertIn('klmsServerRelayConnectionKeychainAccount = "server-relay-ios-connection-v1"', ios_app)
        self.assertIn("account: klmsServerRelayConnectionKeychainAccount", ios_app)
        self.assertIn("public enum LocalRemoteTokenLoadResult: Equatable", shared)
        self.assertIn("case readFailed", shared)
        self.assertIn("case migrationFailed", shared)
        self.assertIn("persistedConnectionLoad.requiresRecovery", model)
        self.assertIn("case let .current(storedPayload) = LocalRemoteTokenStore.load(", model)
        self.assertIn("case let .current(storedEnvelopeText) = LocalRemoteTokenStore.load(", ios_app)
        self.assertIn("if let message = persistedConnection.recoveryMessage", ios_app)
        self.assertIn("persistServerRelayConnectionEnvelope", ios_app)
        self.assertIn("removeLegacyServerRelayConnectionStorage() -> Bool", ios_app)
        self.assertIn("LegacyCredentialCleanupPolicy.perform(", ios_app)
        self.assertIn(
            "LocalRemoteTokenStore.deleteLegacyServices(\n                    account: klmsServerRelayConnectionKeychainAccount",
            ios_app,
        )
        self.assertIn(
            "account: klmsLegacyServerRelayTokenKeychainAccount",
            ios_app,
        )
        self.assertIn("UIPasteboard.general.string = \"\"", ios_app)

    def test_ios_companion_has_tabbed_remote_control_and_cancel(self) -> None:
        shared = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSShared" / "RemoteCommandModels.swift"
        ).read_text(encoding="utf-8")
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        ios_app = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSiOS" / "KLMSiOSApp.swift"
        ).read_text(encoding="utf-8")
        mac_view = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("case cancel", shared)
        self.assertIn("cancelRunningCommand() async throws", shared)
        self.assertIn("func cancelRunningCommand(", model)
        self.assertIn("expectedIdentity: KLMSMacRunningCommandIdentity? = nil", model)
        self.assertIn("expectedIdentity != runningCommandIdentity", model)
        self.assertIn("cancelRunningCommand(expectedIdentity: expectedIdentity)", mac_view)
        self.assertIn("requestCancel", shared)
        self.assertIn("fetchCancelRequest", model)
        self.assertIn("await model.cancelRunningCommand()", ios_app)
        self.assertIn("private struct RemoteRunningStatusBanner", ios_app)
        self.assertIn("shouldShowCancelControl: model.shouldShowCancelControl", ios_app)
        self.assertIn("if snapshot.shouldShowCancelControl", ios_app)
        self.assertNotIn("private struct RemoteCancelControl", ios_app)
        self.assertNotIn("RemoteCancelControl(model:", ios_app)
        self.assertIn('return "요청 중"', ios_app)
        self.assertIn('return "중단"', ios_app)
        self.assertIn("Label(cancelButtonTitle", ios_app)
        self.assertIn("let expectedIdentity = model.runningCommandIdentity", mac_view)
        self.assertIn("await model.cancelRunningCommand(expectedIdentity: expectedIdentity)", mac_view)
        self.assertIn('model.isCancellingCommand ? "hourglass" : "stop.fill"', mac_view)
        self.assertIn("KLMSMacCompactDangerIconButtonStyle", mac_view)
        self.assertIn("CompanionCompactTabBar", ios_app)
        self.assertIn("CompanionAdaptiveRootView", ios_app)
        self.assertNotIn("private struct CompanionTabRootView", ios_app)
        self.assertIn("CompanionStatusScreen", ios_app)
        self.assertIn("RemoteDashboardSyncCard", ios_app)
        self.assertIn("CompanionSettingsScreen", ios_app)
        self.assertIn("CompanionHistoryScreen", ios_app)
        self.assertIn('title: "클라이언트 토큰"', ios_app)
        self.assertIn("SecureField(\"입력\"", ios_app)
        self.assertIn("clearServerRelayConnectionInfo", ios_app)
        self.assertIn('Text("서버 릴레이")', ios_app)
        self.assertIn("연결 정보를 붙여넣어 주세요.", ios_app)
        self.assertIn('title: "연결 확인"', ios_app)
        self.assertIn('title: "복사"', ios_app)
        self.assertIn('connectionAsyncButton("연결 확인"', ios_app)
        self.assertIn('connectionAsyncButton("요약 갱신"', ios_app)
        self.assertIn('connectionButton("URL 복사"', ios_app)
        self.assertIn('connectionButton("연결 정보 복사"', ios_app)
        self.assertIn(
            "static func defaultSort(for _: DashboardMetricCategory?) -> CompanionItemSortOption",
            ios_app,
        )
        self.assertIn(
            "_sortOption = State(initialValue: CompanionItemSortOption.defaultSort(for: category))",
            ios_app,
        )
        self.assertIn('case "FILE_WEEKLY_FOLDERS_ENABLED":', ios_app)
        self.assertIn("기본값은 켜짐입니다.", ios_app)
        self.assertIn('connectionButton("클라이언트 토큰 복사"', ios_app)
        self.assertIn('Label("연결 정보 지우기", systemImage: "trash")', ios_app)
        self.assertIn("ConnectionNoticeBanner", ios_app)
        self.assertIn("diagnosticButton(.verify)", ios_app)
        self.assertIn("diagnosticButton(.v2BuildState)", ios_app)
        self.assertIn("private struct RemoteDashboardSyncCardContent", ios_app)
        self.assertIn("private struct RemoteDashboardPrimarySyncAction", ios_app)
        self.assertIn("private let secondaryCommands: [RemoteCommandKind] = [.filesSync, .coreSync, .noticeSync]", ios_app)
        compact_sections = ios_app.split(
            "static var compactTabs: [CompanionAppSection]", 1
        )[1].split("static var workstationSections", 1)[0]
        self.assertIn(
            "[.status, .files, .notices, .tasks, .calendar, .history, .settings]",
            compact_sections,
        )
        compact_tab_bar = ios_app.split(
            "private struct CompanionCompactTabBar", 1
        )[1].split("private struct CompanionStableSectionPane", 1)[0]
        self.assertIn("if dynamicTypeSize.isAccessibilitySize", compact_tab_bar)
        self.assertIn("Array(tabs.prefix(3))", compact_tab_bar)
        self.assertIn("Array(tabs.dropFirst(3).prefix(2))", compact_tab_bar)
        self.assertIn("Array(tabs.dropFirst(5))", compact_tab_bar)
        self.assertIn(
            "return [Array(tabs.prefix(4)), Array(tabs.dropFirst(4))]",
            compact_tab_bar,
        )
        self.assertIn(
            "usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize",
            ios_app,
        )
        self.assertIn("RemoteDashboardPrimarySyncAction(model: model, compact: compact)", ios_app)
        companion_header = ios_app.split(
            "private struct CompanionScreenHeader", 1
        )[1].split("private struct CompanionHeaderStatusPill", 1)[0]
        self.assertNotIn("RemoteDashboardPrimarySyncAction", companion_header)
        self.assertIn('.accessibilityIdentifier("dashboard-primary-full-sync")', ios_app)
        self.assertIn("dashboardSecondaryButton(command)", ios_app)
        self.assertIn('.accessibilityLabel(isRunning ? "전체 동기화 중단" : "전체 동기화 실행")', ios_app)
        self.assertIn('if isRunning { return "전체 동기화 중단" }', ios_app)
        sync_card_content = ios_app.split(
            "private struct RemoteDashboardSyncCardContent", 1
        )[1].split("private struct RemoteDashboardMetricOverview", 1)[0]
        self.assertNotIn(".fullSync", sync_card_content)
        self.assertIn("RemotePrivacyNote", ios_app)
        self.assertIn("@State private var selectedDashboardPreview", ios_app)
        self.assertIn("DashboardCategoryInlineDetailPanel(", ios_app)
        self.assertIn("ServerSyncItemInlineDetailPanel(item: item, model: model)", ios_app)
        self.assertIn("else if let category = displayedDashboardPreview", ios_app)
        self.assertIn("displayedDashboardPreview = category", ios_app)
        self.assertNotIn("deferDashboardPreview(category)", ios_app)
        self.assertNotIn('Label("상세 보기", systemImage: "arrow.right.circle")', ios_app)
        status_screen = ios_app.split("private struct CompanionStatusScreen", 1)[1].split(
            "private struct CompanionRunScreen",
            1,
        )[0]
        status_tap_block = status_screen.split("onCategoryTap: { category in", 1)[1].split(
            "}",
            1,
        )[0]
        select_category_block = status_screen.split("private func selectDashboardCategory(_ category: DashboardMetricCategory)", 1)[1].split(
            "private func selectChangeSummary",
            1,
        )[0]
        self.assertIn("selectDashboardCategory(category)", status_tap_block)
        self.assertIn("selectedDashboardPreview = category", select_category_block)
        self.assertIn("displayedDashboardPreview = category", select_category_block)
        self.assertNotIn("deferDashboardPreview(category)", select_category_block)
        self.assertNotIn("selectedDashboardRoute = category", status_tap_block)
        self.assertNotIn("selectedSyncItem", status_screen)
        self.assertNotIn(".navigationDestination", status_screen)
        self.assertNotIn("DashboardMetricDetailPanel(", status_screen)
        self.assertNotIn("ServerSyncDataPanel(", status_screen)
        self.assertNotIn(".sheet(item: $selectedDashboardPreview)", status_screen)
        self.assertIn("CompanionSettingHelpText", ios_app)
        for description in [
            "공개 HTTPS 주소만 넣습니다. 로컬 주소는 저장하지 않습니다.",
            "이 기기용 토큰입니다. Mac 전용 토큰은 넣지 않습니다.",
            "복사된 토큰은 보안을 위해 60초 뒤 클립보드에서 자동으로 지워집니다.",
            "연결 확인은 동기화 없이 서버 응답만 검사합니다.",
            "변경한 값은 서버에 저장되고 Mac 앱이 받아 적용합니다.",
            "읽음/중요 표시는 유지하되, 공지 내용이 그대로면 Notes 메모를 다시 쓰지 않습니다.",
            "변경량 계산에서 새 파일이나 수정된 파일이 없으면 실제 다운로드 단계를 건너뜁니다.",
        ]:
            self.assertIn(description, ios_app)

    def test_mac_dashboard_deletion_prefers_recent_local_state_over_stale_server_overlay(self) -> None:
        model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")
        mac_view = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("localDashboardMutationByItemID", model)
        self.assertIn(".filter { shouldApplyServerRelayDashboardOverlay($0) }", model)
        self.assertIn("markLocalDashboardMutation(itemIDs: serverRelayAssignmentSyncItemIDs(item))", model)
        self.assertIn("markLocalDashboardMutation(itemIDs: serverRelayExamSyncItemIDs(item))", model)
        self.assertIn("markLocalDashboardMutation(itemIDs: [serverRelayNoticeSyncItemID(notice)])", model)
        self.assertIn("markLocalDashboardMutation(itemIDs: serverRelayFileSyncItemIDs(", model)
        self.assertIn("localDashboardMutationByItemID[$0.id] != nil && !serverDashboardItemIDs.contains($0.id)", model)
        self.assertIn("await self.publishServerRelayStatusIfNeeded(force: true, publishSyncData: true)", model)
        self.assertIn("private struct RemoteActivityPanelView: View", mac_view)
        self.assertIn("@ObservedObject var model: KLMSMacModel", mac_view)

    def test_server_relay_uses_role_scoped_tokens(self) -> None:
        node_relay = (PROJECT_DIR / "tools" / "klms_relay_server.mjs").read_text(encoding="utf-8")
        worker = (PROJECT_DIR / "deploy" / "cloudflare-worker" / "src" / "worker.mjs").read_text(
            encoding="utf-8"
        )
        installer = (PROJECT_DIR / "tools" / "install_klms_relay_agent.sh").read_text(
            encoding="utf-8"
        )
        windows_main = (PROJECT_DIR / "apps" / "KLMSyncWindows" / "src" / "main.cjs").read_text(
            encoding="utf-8"
        )

        for source in (node_relay, worker):
            self.assertIn("CLIENT_TOKEN", source)
            self.assertIn("WORKER_TOKEN", source)
            self.assertIn("client", source)
            self.assertIn("worker", source)
        self.assertIn("must be different", node_relay)
        self.assertIn("client !== worker", worker)

        self.assertIn("KLMS_RELAY_CLIENT_TOKEN", installer)
        self.assertIn("KLMS_RELAY_WORKER_TOKEN", installer)
        self.assertIn("--show-token", installer)
        self.assertIn("전체 토큰을 보려면", installer)
        self.assertIn("throw new Error(\"Windows 보안 저장소를 사용할 수 없어 클라이언트 토큰을 저장하지 않았습니다.\")", windows_main)
        self.assertIn("return \"\";", windows_main)
        self.assertNotIn("return token;\n}", windows_main)

    def test_relay_deploy_tokens_never_enter_curl_process_arguments(self) -> None:
        scripts = [
            PROJECT_DIR / "deploy" / "relay" / "deploy.sh",
            PROJECT_DIR / "deploy" / "relay" / "status.sh",
            PROJECT_DIR / "deploy" / "cloudflare-worker" / "setup_cloudflare_relay.sh",
        ]

        for script in scripts:
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                self.assertIn("--header @-", source)
                self.assertNotIn('-H "Authorization: Bearer', source)

    def test_security_scanner_dependencies_are_fully_hash_locked(self) -> None:
        security_dir = PROJECT_DIR / "tools" / "security"
        lock_paths = [security_dir / "python-scanner-requirements.lock"]
        requirement_pattern = re.compile(
            r"^[A-Za-z0-9_.-]+==[^\s]+(?: --hash=sha256:[0-9a-f]{64})+$"
        )

        for lock_path in lock_paths:
            with self.subTest(lock=lock_path.name):
                requirements = [
                    line
                    for line in lock_path.read_text(encoding="utf-8").splitlines()
                    if line and not line.startswith("#")
                ]
                self.assertGreater(len(requirements), 0)
                self.assertTrue(all(requirement_pattern.fullmatch(line) for line in requirements))
                names = [line.split("==", 1)[0].casefold() for line in requirements]
                self.assertEqual(len(names), len(set(names)))

        installer = (security_dir / "install_security_scanners.sh").read_text(encoding="utf-8")
        versions = (security_dir / "security-tool-versions.env").read_text(encoding="utf-8")
        scanner_lock = (security_dir / "python-scanner-requirements.lock").read_text(
            encoding="utf-8"
        )
        self.assertIn("--require-hashes", installer)
        self.assertIn("--only-binary=:all:", installer)
        self.assertIn("--no-deps", installer)
        self.assertIn('sys.version_info[:2] == (3, 12)', installer)
        self.assertIn("MCP_VERSION=1.28.1", versions)
        self.assertIn("mcp==1.28.1 --hash=sha256:", scanner_lock)
        self.assertIn("click==8.4.2 --hash=sha256:", scanner_lock)

    def test_ios_project_has_app_icon_asset_catalog(self) -> None:
        project = (
            PROJECT_DIR
            / "apps"
            / "KLMSync"
            / "Xcode"
            / "KLMSiOS"
            / "KLMSiOS.xcodeproj"
            / "project.pbxproj"
        ).read_text(encoding="utf-8")
        generator = (PROJECT_DIR / "tools" / "generate_klms_ios_xcode_project.py").read_text(
            encoding="utf-8"
        )
        icon_generator = (PROJECT_DIR / "tools" / "generate_klms_app_icon.py").read_text(
            encoding="utf-8"
        )
        app_icon = (
            PROJECT_DIR
            / "apps"
            / "KLMSync"
            / "Xcode"
            / "KLMSiOS"
            / "KLMSiOS"
            / "Assets.xcassets"
            / "AppIcon.appiconset"
            / "Contents.json"
        ).read_text(encoding="utf-8")

        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon", project)
        self.assertIn("Assets.xcassets in Resources", project)
        self.assertIn("ASSET_CATALOG", generator)
        self.assertIn("write_ios_appiconset", icon_generator)
        self.assertIn('"Icon-60@3x.png"', app_icon)
        self.assertIn('"ios-marketing"', app_icon)

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
