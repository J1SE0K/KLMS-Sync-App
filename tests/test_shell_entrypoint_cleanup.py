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

        self.assertIn('KLMS_LOGIN_ASSIST_ENABLED": "1"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": "1"', app_model)
        self.assertIn('KLMS_FORCE_LOGIN_PREFLIGHT": "1"', app_model)
        self.assertIn('KLMS_LOGIN_STATUS_REUSE_SECONDS": "21600"', app_model)
        self.assertIn('KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS": "0"', app_model)
        self.assertIn('KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED": "1"', app_model)
        self.assertIn('"OVERRIDES_JSON_PATH": paths.overridesURL.path', app_model)
        self.assertIn('KAIKEY_AUTHENTICATED_RECHECK_SECONDS": "1"', app_model)
        self.assertIn('KAIKEY_AUTH_CHECK_SECONDS": "1.2"', app_model)
        self.assertIn('KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS": "60"', app_model)
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
        self.assertIn("EngineSnapshotStore(paths: self.paths).load()", app_model)
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
        self.assertIn("manifest_layout_matches()", text)
        self.assertIn('"${FILE_REFRESH_MODE:l}" != "full"', text)
        self.assertIn('"$COURSE_CHANGED_COUNT" == "0"', text)
        self.assertIn('"$ALL_WEEK_COURSE_CHANGED_COUNT" == "0"', text)
        self.assertIn('"$FILE_SEED_URL_LIST_CHANGED" == "0"', text)
        self.assertIn("deep file page fetch skipped reason=no-course-or-url-change", text)
        self.assertIn("TRACKED_FILE_MISSING_COUNT", text)
        self.assertIn("restore-missing-files-from-manifest", text)
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

        self.assertIn('"FILE_REFRESH_MODE": "auto"', model)
        self.assertIn('"FILE_FORCE_DOWNLOAD": "0"', model)
        self.assertIn('"FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY": "1"', model)
        self.assertIn('"FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS": "21600"', model)
        self.assertIn('Picker("파일 탐색 모드"', settings)
        self.assertIn('allowedValues: ["auto", "quick"]', settings)
        file_picker = settings.split('Picker("파일 탐색 모드"', 1)[1].split("}", 1)[0]
        self.assertNotIn('Text("전체").tag("full")', file_picker)
        self.assertNotIn('configToggle("강제 재다운로드"', settings)

    def test_mac_app_exposes_full_file_manifest_list(self) -> None:
        menu = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "MenuBarRootView.swift"
        ).read_text(encoding="utf-8")
        detail = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "DashboardDetailView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('Metric("파일 목록", snapshot.courseFileManifest.count, detail: .files)', menu)
        self.assertIn('Metric("파일 목록", preview.manifestCount, detail: .files)', menu)
        self.assertIn("@State private var selectedDetail = DashboardDetailKind.files", menu)
        self.assertIn("case files", detail)
        self.assertIn("FileManifestListView(filters: filters, model: model)", detail)
        self.assertIn("model.snapshot.courseFileManifest.compactMap", detail)
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
        self.assertGreaterEqual(detail.count("FileSortPickerView(selection: $sortOption)"), 4)
        self.assertGreaterEqual(detail.count(".sorted(by: sortOption)"), 4)
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
        self.assertIn("let activeDetail = visibleMetrics.first { $0.detail == selectedDetail }?.detail", menu)
        self.assertIn('Text("표시할 대시보드 항목이 없습니다.")', menu)
        self.assertIn("DashboardDetailPanelView(kind: activeDetail, model: model)", menu)
        self.assertRegex(
            menu,
            r'Metric\("격리됨", visibleFileCounts\.quarantine, detail: \.quarantine\),\s*\]\.filter \{ \$0\.value > 0 \}',
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
        self.assertIn("KAIST 인증 번호: ([0-9][0-9])", text)
        self.assertNotIn("digits=([0-9][0-9])", text)

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
        self.assertIn("LocalRemoteTokenStore.load(account: \"server-relay-mac\")", model)
        self.assertIn("LocalRemoteTokenStore.save(token, account: \"server-relay-mac\")", model)
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

        self.assertIn("case cancel", shared)
        self.assertIn("cancelRunningCommand() async throws", shared)
        self.assertIn("func cancelRunningCommand() async", model)
        self.assertIn("서버 릴레이에서는 아직 실행 중단을 지원하지 않습니다.", ios_app)
        self.assertIn("TabView", ios_app)
        self.assertIn("CompanionStatusScreen", ios_app)
        self.assertIn("CompanionRunScreen", ios_app)
        self.assertIn("CompanionConnectionScreen", ios_app)
        self.assertIn("CompanionHistoryScreen", ios_app)
        self.assertIn("현재 동기화 중단", ios_app)
        self.assertIn("SecureField(\"서버 토큰\"", ios_app)
        self.assertIn("clearServerRelayConnectionInfo", ios_app)
        self.assertIn("Cloudflare 서버 릴레이", ios_app)
        self.assertIn("RemotePrivacyNote", ios_app)

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
