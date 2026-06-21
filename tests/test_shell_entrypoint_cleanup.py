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

    def test_ios_device_installer_reports_generic_device_labels(self) -> None:
        script = (PROJECT_DIR / "tools" / "install_klms_ios_device.sh").read_text(encoding="utf-8")
        readme = (PROJECT_DIR / "apps" / "KLMSync" / "README.md").read_text(encoding="utf-8")

        self.assertIn('local device_label="${2:-device}"', script)
        self.assertIn('print -r -- "${device_label}: installed"', script)
        self.assertIn('print -r -- "${device_label}: installed-and-launched"', script)
        self.assertIn('print -ru2 -- "${device_label}: installed, but launch was denied', script)
        self.assertIn('print(f"{identifier}\\t{hardware.get(\'deviceType\', \'device\')}")', script)
        self.assertIn('target_device="${device_entry%%$\'\\t\'*}"', script)
        self.assertIn('device_label="${device_entry#*$\'\\t\'}"', script)
        self.assertNotIn("properties.get(\"name\")", script)
        self.assertIn("prints a generic `iPhone` or `iPad` label for each result", readme)

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
        kaikey = (PROJECT_DIR / "bin" / "kaikey_auto_login.sh").read_text(encoding="utf-8")

        self.assertIn('KLMS_LOGIN_ASSIST_ENABLED": runtimeBoolConfigValue(.loginAssistEnabled, default: true)', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": runtimeBoolConfigValue(.loginAssistAllowNoninteractive, default: true)', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_MODE": runtimeConfigValue(.loginAssistMode, default: "manual-digits")', app_model)
        self.assertIn('KLMS_FORCE_LOGIN_PREFLIGHT": "1"', app_model)
        self.assertIn('KLMS_LOGIN_STATUS_REUSE_SECONDS": "21600"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS": "0"', app_model)
        self.assertIn('KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED": "1"', app_model)
        self.assertIn('"OVERRIDES_JSON_PATH": paths.overridesURL.path', app_model)
        self.assertIn('KAIKEY_AUTHENTICATED_RECHECK_SECONDS": "1"', app_model)
        self.assertIn('KAIKEY_AUTH_CHECK_SECONDS": "1.2"', app_model)
        self.assertIn('KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS": "60"', app_model)
        self.assertIn('FILE_DOWNLOAD_PARALLELISM": "3"', app_model)
        self.assertIn('FILE_DIRECT_FETCH_MAX_BYTES": "26214400"', app_model)
        self.assertIn('REMINDER_RECREATE_STAGE_ALERT_LIST": "0"', app_model)
        self.assertNotIn("KLMS_LOGIN_ALWAYS_ASSIST_ENABLED", app_model)
        self.assertIn('"${KLMS_APP_RUN:-0}" == "1"', common)
        self.assertIn('"$force_login_preflight" != "1"', common)
        self.assertIn('if [[ "$fast_tab_state" == "authenticated" ]]', common)
        self.assertIn("klms_report_already_logged_in", common)
        self.assertIn("stage=already_authenticated", common)
        self.assertIn("KLMS 이미 로그인되어 있습니다.", common)
        self.assertIn("outputIndicatesAlreadyAuthenticated", app_model)
        self.assertIn('showTransientAuthStatus("이미 로그인됨")', app_model)
        self.assertIn("stage=already_authenticated source=kaikey-safari", kaikey)
        self.assertIn('klms_recent_login_status_ok', common)
        self.assertIn("KLMS_PARENT_LOGIN_ASSIST_READY", common)
        self.assertIn("KLMS_LOGIN_ASSIST_READY=1", common)
        self.assertIn('KLMS_USE_EXISTING_DASHBOARD="${KLMS_LOGIN_PREFETCH_READY:-0}"', common)
        self.assertIn('KLMS_PARENT_LOGIN_PREFLIGHT_READY="${KLMS_LOGIN_PREFETCH_READY:-0}"', common)
        self.assertIn("startRunningCommandStatusPoll", app_model)
        self.assertIn("loginStatusWasConfirmed", app_model)
        self.assertIn("configurePassiveSnapshotRefresh", app_model)
        self.assertIn("passiveSnapshotRefreshIntervalNanoseconds", app_model)
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
            helper = root / "kaikey_auto_login.sh"
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
            helper = root / "kaikey_auto_login.sh"
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

    def test_local_artifact_cleanup_preserves_private_runtime_data(self) -> None:
        script = PROJECT_DIR / "tools" / "clean_local_artifacts.sh"
        text = script.read_text(encoding="utf-8")

        self.assertIn("runtime/tmp", text)
        self.assertIn("apps/KLMSync/.build", text)
        self.assertIn("notice_native_note_timing.log", text)
        self.assertIn("runtime/state", text)
        self.assertIn("course_files", text)
        self.assertIn("manual overrides", text)
        self.assertIn("Refusing to remove protected path", text)
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
        self.assertIn("FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS", text)
        self.assertIn("seed timestamp gate active", text)
        self.assertIn("FILE_SEED_URL_LIST_CHANGED == 0", text)
        self.assertIn("file_seed_urls.next", text)
        self.assertIn("build_files_stage_timings.py", text)
        self.assertIn("klms_cleanup_runtime_tmp_if_enabled", text)
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
        self.assertIn("deep file page fetch skipped reason=seed-urls-unchanged", text)
        self.assertIn("course_changed=$COURSE_CHANGED_COUNT", text)
        self.assertIn("all_week_changed=$ALL_WEEK_COURSE_CHANGED_COUNT", text)
        self.assertIn("TRACKED_FILE_MISSING_COUNT", text)
        self.assertIn("restore-missing-files-from-manifest", text)
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
        self.assertIn('"FILE_FORCE_DOWNLOAD": "0"', model)
        self.assertIn('"FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY": runtimeBoolConfigValue(.fileSkipDownloadWhenPreviewEmpty, default: true)', model)
        self.assertIn('"FILE_KEEP_FRESH_DOWNLOADS": runtimeBoolConfigValue(.fileKeepFreshDownloads, default: false)', model)
        self.assertIn('"FILE_WEEKLY_FOLDERS_ENABLED": runtimeBoolConfigValue(.fileWeeklyFoldersEnabled, default: true)', model)
        self.assertIn('"FILE_PRESERVE_DOWNLOAD_ARCHIVE": runtimeBoolConfigValue(.filePreserveDownloadArchive, default: false)', model)
        self.assertIn('"FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS": "21600"', model)
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
        self.assertLess(mac_root.index("MacAlertBannerView("), mac_root.index("CommandPanelView(model: model)"))

        container = ios_view[
            ios_view.index("private struct CompanionScreenContainer")
            : ios_view.index("private struct CompanionScreenHeader")
        ]
        self.assertLess(container.index("RemoteAttentionStack(model: model)"), container.index("CompanionScreenHeader(title: title, model: model)"))
        self.assertEqual(ios_view.count("RemoteAttentionStack(model: model)"), 1)

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
            "시험과 헬프데스크 일정이 이미 같으면 Calendar 이벤트를 다시 쓰지 않습니다.",
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

        self.assertIn(
            'Metric("파일", snapshot.courseFileManifest.count, detail: .files)',
            menu,
        )
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
        self.assertIn('"최근"', detail)
        self.assertIn("private struct FileSortPickerView", detail)
        self.assertGreaterEqual(detail.count("FileSortPickerView(selection: $sortOption)"), 2)
        self.assertGreaterEqual(detail.count(".sorted(by: sortOption)"), 2)
        self.assertEqual(detail.count("@State private var sortOption = DashboardFileSortOption.recent"), 2)
        self.assertNotIn("@State private var sortOption = DashboardFileSortOption.course", detail)
        self.assertNotIn("@State private var sortOption = DashboardFileSortOption.name", detail)
        self.assertNotIn("@State private var sortOption = DashboardFileSortOption.path", detail)
        self.assertIn("selection = option", detail)
        self.assertIn(".id(sortOption.rawValue)", detail)
        self.assertIn("sortPath: entry.relativePath", detail)
        self.assertIn("recencyText: entry.localDownloadedAt", detail)
        self.assertIn("klmsTimestampEpoch: entry.klmsTimestampEpoch", detail)
        self.assertIn("lhs.klmsTimestampEpoch ?? Int.min", detail)
        self.assertIn("KLMS 등록 시각이 최신인 파일을 먼저 정렬", detail)
        self.assertIn("Label(item.fileKindLabel, systemImage: item.fileKindIcon)", detail)
        self.assertIn('"공지 첨부"', detail)
        self.assertIn('"과제 첨부"', detail)
        self.assertIn('"강의 자료"', detail)
        self.assertIn("localizedStandardCompare(rightRecency) == .orderedDescending", detail)
        self.assertIn("fileSortPath(from:", detail)

    def test_mac_app_integration_status_is_collapsible(self) -> None:
        menu = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('@AppStorage("KLMSMacIntegrationStatusExpanded") private var isExpanded = false', menu)
        self.assertIn('isExpanded.toggle()', menu)
        self.assertIn('help(isExpanded ? "연동 상태 접기" : "연동 상태 펼치기")', menu)
        self.assertIn("if !isExpanded", menu)
        self.assertIn("IntegrationStatusCompactStrip(statuses: statuses)", menu)
        self.assertIn("if isExpanded", menu)
        self.assertIn("IntegrationStatusTile(status: status)", menu)

    def test_mac_app_hides_zero_dashboard_metrics_and_detail(self) -> None:
        menu = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("].filter { $0.value > 0 }", menu)
        self.assertIn("presentation.activeDetail(", menu)
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
        self.assertIn("Failed to create a dedicated Safari fetch window", fetch_text)
        self.assertIn('return "minimize";', fetch_text)
        self.assertIn('if (configured === "offscreen")', fetch_text)
        self.assertIn('envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "1")', download_text)
        self.assertIn("if (!safeValue(() => safari.running()))", download_text)
        self.assertIn("reuseExistingWindowEnabled ? findKlmsWindow", download_text)
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
        self.assertIn('"KLMS_LOGIN_ASSIST_ENABLED": runtimeBoolConfigValue(.loginAssistEnabled, default: true)', app_environment)
        self.assertIn('"KLMS_LOGIN_ASSIST_MODE": runtimeConfigValue(.loginAssistMode, default: "manual-digits")', app_environment)
        self.assertIn('"KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": runtimeBoolConfigValue(.loginAssistAllowNoninteractive, default: true)', app_environment)
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
        self.assertIn("async let responseTask = serverRelayStore.fetchStatusResponse()", ios_app)
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
        self.assertIn("trackReportNotificationIfNeeded(for: command)", ios_app)
        self.assertIn("handleReportNotificationUpdates(commands)", ios_app)
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
        self.assertIn("Self.persistRelayToken(", model)
        self.assertIn("serverRelayClientToken,", model)
        self.assertIn("serverRelayWorkerToken,", model)
        self.assertIn("account: \"server-relay-client-mac\"", model)
        self.assertIn("account: \"server-relay-worker-mac\"", model)
        self.assertIn("LocalRemoteTokenStore.delete(account: \"server-relay-mac\")", model)
        self.assertIn("UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalRemoteTokenKey)", model)
        self.assertIn("pasteboardClearTask", model)
        self.assertIn("LocalRemoteTokenStore.load(account: \"server-relay-ios\")", ios_app)
        self.assertIn("persistServerToken", ios_app)
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
        self.assertIn("func cancelRunningCommand() async", model)
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
        self.assertIn("await model.cancelRunningCommand()", mac_view)
        self.assertIn('model.isCancellingCommand ? "중단 중" : "중단"', mac_view)
        self.assertIn("CompanionCompactTabBar", ios_app)
        self.assertIn("CompanionSplitRootView", ios_app)
        self.assertIn("CompanionTabRootView", ios_app)
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
        self.assertIn('requestGroupTitle("원격 실행")', ios_app)
        self.assertIn("private let secondaryCommands: [RemoteCommandKind] = [.filesSync, .coreSync, .noticeSync]", ios_app)
        self.assertIn("private let secondaryColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 7), count: 3)", ios_app)
        self.assertIn("dashboardPrimaryButton", ios_app)
        self.assertIn("dashboardSecondaryButton(command)", ios_app)
        self.assertIn("RemotePrivacyNote", ios_app)
        self.assertIn("@State private var selectedDashboardPreview", ios_app)
        self.assertIn("DashboardCategoryInlineDetailPanel(", ios_app)
        self.assertIn("ServerSyncItemInlineDetailPanel(item: item, model: model)", ios_app)
        self.assertIn("else if let category = displayedDashboardPreview", ios_app)
        self.assertIn("deferDashboardPreview(category)", ios_app)
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
        self.assertIn("displayedDashboardPreview = nil", select_category_block)
        self.assertIn("deferDashboardPreview(category)", select_category_block)
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
