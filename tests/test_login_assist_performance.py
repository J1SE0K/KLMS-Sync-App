import unittest
import os
import subprocess
import tempfile
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class LoginAssistPerformanceTests(unittest.TestCase):
    def test_safari_step_advances_multiple_login_states_per_process(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "kaikey_safari_step.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("advanceUntilTerminal", text)
        self.assertIn("advanceOneStep", text)
        self.assertIn("submittedLogin", text)
        self.assertIn('payload.status === "login_submitted"', text)
        self.assertIn('options["check-authenticated"]', text)
        self.assertIn("checkAuthenticatedWithoutLeavingTwofactor", text)
        self.assertIn("authCheckMilliseconds", text)
        self.assertIn("closeWindow(checkWindow)", text)
        self.assertIn('let pendingReason = "phone-approval-pending"', text)
        self.assertIn('pendingReason = "dashboard-check-login-required"', text)
        self.assertIn('pendingReason = "dashboard-check-loading"', text)
        self.assertIn('status: "twofactor_pending"', text)
        self.assertIn('method: "dashboard-check-window"', text)
        self.assertIn("twofactorPending(sourceUrl, pendingReason)", text)
        self.assertIn("looksLikeAuthenticatedKlmsUrl", text)
        self.assertIn("readKlmsPageLoadState", text)
        self.assertIn('reason: "klms-page-loading"', text)
        self.assertIn('readyState === "interactive" || readyState === "complete"', text)
        self.assertNotIn('return twofactorPending(sourceUrl, "dashboard-check-login-required")', text)
        self.assertIn('options["max-seconds"]', text)
        self.assertIn('options["poll-ms"]', text)
        self.assertIn("isTerminalStatus", text)
        self.assertIn("readTitle(tab)", text)
        self.assertIn("sso.kaist.ac.kr/auth/kaist/user/login/view", text)
        self.assertIn("window.location.assign(link.href)", text)
        self.assertIn('options["refresh-twofactor"]', text)
        self.assertIn('method: "restart-login"', text)
        self.assertIn("KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED", text)
        self.assertIn("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", text)
        self.assertIn("createSafariWindow", text)
        self.assertIn("prepareBackgroundWindow(windowRef)", text)
        self.assertIn("windowRef.miniaturized = true", text)
        self.assertNotIn("klmsPageLooksAuthenticated", text)
        self.assertNotIn("unverified-klms-page", text)
        self.assertNotIn("const title = safeString(() => tab.name())", text)
        self.assertNotIn("delay(0.5)", text)
        self.assertNotIn("delay(0.8)", text)

    def test_shell_login_assist_uses_inner_safari_polling(self) -> None:
        text = (PROJECT_DIR / "bin" / "kaikey_auto_login.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS", text)
        self.assertIn("KAIKEY_SAFARI_STEP_POLL_MS", text)
        self.assertIn('KLMS_LOGIN_ASSIST_MODE="${KLMS_LOGIN_ASSIST_MODE:-manual-digits}"', text)
        self.assertIn("manual-digits", text)
        self.assertIn("kaikey-auto", text)
        self.assertIn('KLMS_LOGIN_ASSIST_AUTO_APPROVE_ENABLED="${KLMS_LOGIN_ASSIST_AUTO_APPROVE_ENABLED:-0}"', text)
        self.assertIn('if [[ "$KAIKEY_AUTO_APPROVE_ENABLED" == "1" && -n "$NODE_BIN" ]]', text)
        self.assertIn("KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED", text)
        self.assertIn("KLMS_SCRIPT_NOTIFICATIONS_ENABLED", text)
        self.assertIn("KAIKEY_OSASCRIPT_BIN", text)
        self.assertIn("KLMS_APP_RUN", text)
        self.assertIn('KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED="0"', text)
        self.assertIn("KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS", text)
        self.assertIn('KAIKEY_TWOFACTOR_REFRESH_SECONDS="${KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS:-${KAIKEY_TWOFACTOR_REFRESH_SECONDS:-0}}"', text)
        self.assertIn("KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED", text)
        self.assertIn("preexisting_twofactor_refresh_attempted", text)
        self.assertNotIn("KLMS_LOGIN_ASSIST_FORCE_TWOFACTOR", text)
        self.assertNotIn("--force-twofactor", text)
        self.assertIn("--refresh-twofactor=1", text)
        self.assertIn("submitted_login_this_run", text)
        self.assertIn('"$KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED" == "1"', text)
        self.assertIn('submittedLogin', text)
        self.assertIn("KAIKEY_AUTHENTICATED_RECHECK_SECONDS", text)
        self.assertIn("KAIKEY_AUTH_CHECK_SECONDS", text)
        self.assertIn("--check-authenticated=1", text)
        self.assertIn('KAIKEY_AUTO_LOGIN_POLL_SECONDS="${KAIKEY_AUTO_LOGIN_POLL_SECONDS:-0.2}"', text)
        self.assertIn('KAIKEY_SAFARI_STEP_POLL_MS="${KAIKEY_SAFARI_STEP_POLL_MS:-75}"', text)
        self.assertIn("--max-seconds=$KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS", text)
        self.assertIn("--poll-ms=$KAIKEY_SAFARI_STEP_POLL_MS", text)

    def test_shell_login_assist_reuses_preexisting_twofactor_without_refreshing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "state.txt"
            fake_osascript = root / "osascript"
            fake_osascript.write_text(
                """#!/bin/zsh
set -euo pipefail
if [[ " $* " == *" --refresh-twofactor=1 "* ]]; then
  print -- '{"status":"error","error":"unexpected-refresh"}'
  exit 1
fi
if [[ " $* " == *" --check-authenticated=1 "* ]]; then
  print -- '{"status":"authenticated","submittedLogin":false}'
  exit 0
fi
count=0
if [[ -f "$FAKE_OSASCRIPT_STATE" ]]; then
  count="$(<"$FAKE_OSASCRIPT_STATE")"
fi
count=$((count + 1))
print -r -- "$count" > "$FAKE_OSASCRIPT_STATE"
print -- '{"status":"twofactor_digits","digits":"57","submittedLogin":false}'
""",
                encoding="utf-8",
            )
            fake_osascript.chmod(0o755)

            config = root / "config.env"
            config.write_text(
                "\n".join(
                    [
                        'KLMS_SSO_LOGIN_ID="test-user"',
                        'KLMS_SCRIPT_NOTIFICATIONS_ENABLED="0"',
                        'KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="5"',
                        'KAIKEY_AUTO_LOGIN_POLL_SECONDS="0.01"',
                        'KAIKEY_AUTHENTICATED_RECHECK_SECONDS="1"',
                        'KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS="1"',
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["KAIKEY_OSASCRIPT_BIN"] = str(fake_osascript)
            env["FAKE_OSASCRIPT_STATE"] = str(state)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT_DIR / "bin" / "kaikey_auto_login.sh"), str(config)],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertNotIn("기존 KAIST 인증 화면을 새로 요청했어.", result.stdout)
            self.assertEqual(result.stdout.count("KAIST 인증 번호: 57"), 1)
            self.assertIn("status=ok stage=authenticated", result.stdout)

    def test_app_run_login_assist_refresh_setting_overrides_config_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            refresh_marker = root / "refresh-called"
            fake_osascript = root / "osascript"
            fake_osascript.write_text(
                """#!/bin/zsh
set -euo pipefail
if [[ " $* " == *" --refresh-twofactor=1 "* ]]; then
  print -r -- refresh > "$FAKE_REFRESH_MARKER"
  print -- '{"status":"twofactor_refreshed","submittedLogin":false}'
  exit 0
fi
if [[ " $* " == *" --check-authenticated=1 "* ]]; then
  print -- '{"status":"waiting","submittedLogin":false}'
  exit 0
fi
print -- '{"status":"twofactor_digits","digits":"57","submittedLogin":false}'
""",
                encoding="utf-8",
            )
            fake_osascript.chmod(0o755)

            config = root / "config.env"
            config.write_text(
                "\n".join(
                    [
                        'KLMS_SSO_LOGIN_ID="test-user"',
                        'KLMS_SCRIPT_NOTIFICATIONS_ENABLED="1"',
                        'KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS="1"',
                        'KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="2"',
                        'KAIKEY_AUTO_LOGIN_POLL_SECONDS="0.01"',
                        'KAIKEY_AUTHENTICATED_RECHECK_SECONDS="99"',
                        'KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS="1"',
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["KLMS_APP_RUN"] = "1"
            env["KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS"] = "0"
            env["KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED"] = "0"
            env["KAIKEY_OSASCRIPT_BIN"] = str(fake_osascript)
            env["FAKE_REFRESH_MARKER"] = str(refresh_marker)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT_DIR / "bin" / "kaikey_auto_login.sh"), str(config)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(refresh_marker.exists(), result.stdout + result.stderr)
            self.assertEqual(result.stdout.count("KAIST 인증 번호: 57"), 1)

    def test_shell_login_assist_refreshes_preexisting_twofactor_only_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            refresh_count = root / "refresh-count.txt"
            fake_osascript = root / "osascript"
            fake_osascript.write_text(
                """#!/bin/zsh
set -euo pipefail
if [[ " $* " == *" --refresh-twofactor=1 "* ]]; then
  count=0
  if [[ -f "$FAKE_REFRESH_COUNT" ]]; then
    count="$(<"$FAKE_REFRESH_COUNT")"
  fi
  count=$((count + 1))
  print -r -- "$count" > "$FAKE_REFRESH_COUNT"
  print -- '{"status":"twofactor_refreshed","submittedLogin":false}'
  exit 0
fi
print -- '{"status":"twofactor_digits","digits":"57","submittedLogin":false}'
""",
                encoding="utf-8",
            )
            fake_osascript.chmod(0o755)

            config = root / "config.env"
            config.write_text(
                "\n".join(
                    [
                        'KLMS_SSO_LOGIN_ID="test-user"',
                        'KLMS_SCRIPT_NOTIFICATIONS_ENABLED="0"',
                        'KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED="1"',
                        'KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="1"',
                        'KAIKEY_AUTO_LOGIN_POLL_SECONDS="0.01"',
                        'KAIKEY_AUTHENTICATED_RECHECK_SECONDS="0"',
                        'KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS="1"',
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["KAIKEY_OSASCRIPT_BIN"] = str(fake_osascript)
            env["FAKE_REFRESH_COUNT"] = str(refresh_count)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT_DIR / "bin" / "kaikey_auto_login.sh"), str(config)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(refresh_count.read_text(encoding="utf-8").strip(), "1")
            self.assertEqual(result.stdout.count("기존 KAIST 인증 화면을 새로 요청했어."), 1)
            self.assertEqual(result.stdout.count("KAIST 인증 번호: 57"), 1)

    def test_shell_login_assist_rechecks_dashboard_after_phone_approval(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "state.txt"
            fake_osascript = root / "osascript"
            fake_osascript.write_text(
                """#!/bin/zsh
set -euo pipefail
if [[ " $* " == *" --check-authenticated=1 "* ]]; then
  print -- '{"status":"authenticated","submittedLogin":true}'
  exit 0
fi
count=0
if [[ -f "$FAKE_OSASCRIPT_STATE" ]]; then
  count="$(<"$FAKE_OSASCRIPT_STATE")"
fi
count=$((count + 1))
print -r -- "$count" > "$FAKE_OSASCRIPT_STATE"
print -- '{"status":"twofactor_digits","digits":"23","submittedLogin":true}'
""",
                encoding="utf-8",
            )
            fake_osascript.chmod(0o755)

            config = root / "config.env"
            config.write_text(
                "\n".join(
                    [
                        'KLMS_SSO_LOGIN_ID="test-user"',
                        'KLMS_SCRIPT_NOTIFICATIONS_ENABLED="0"',
                        'KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="5"',
                        'KAIKEY_AUTO_LOGIN_POLL_SECONDS="0.01"',
                        'KAIKEY_AUTHENTICATED_RECHECK_SECONDS="1"',
                        'KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS="1"',
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["KAIKEY_OSASCRIPT_BIN"] = str(fake_osascript)
            env["FAKE_OSASCRIPT_STATE"] = str(state)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT_DIR / "bin" / "kaikey_auto_login.sh"), str(config)],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(result.stdout.count("KAIST 인증 번호: 23"), 1)
            self.assertIn("status=ok stage=authenticated", result.stdout)

    def test_shell_login_assist_zero_disables_authenticated_recheck(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "check-called"
            fake_osascript = root / "osascript"
            fake_osascript.write_text(
                """#!/bin/zsh
set -euo pipefail
if [[ " $* " == *" --check-authenticated=1 "* ]]; then
  print -r -- check > "$FAKE_CHECK_MARKER"
  print -- '{"status":"authenticated","submittedLogin":false}'
  exit 0
fi
print -- '{"status":"twofactor_digits","digits":"42","submittedLogin":true}'
""",
                encoding="utf-8",
            )
            fake_osascript.chmod(0o755)

            config = root / "config.env"
            config.write_text(
                "\n".join(
                    [
                        'KLMS_SSO_LOGIN_ID="test-user"',
                        'KLMS_SCRIPT_NOTIFICATIONS_ENABLED="0"',
                        'KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="1"',
                        'KAIKEY_AUTO_LOGIN_POLL_SECONDS="0.01"',
                        'KAIKEY_AUTHENTICATED_RECHECK_SECONDS="0"',
                        'KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS="1"',
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["KAIKEY_OSASCRIPT_BIN"] = str(fake_osascript)
            env["FAKE_CHECK_MARKER"] = str(marker)
            result = subprocess.run(
                ["/bin/zsh", str(PROJECT_DIR / "bin" / "kaikey_auto_login.sh"), str(config)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), result.stdout + result.stderr)
            self.assertEqual(result.stdout.count("KAIST 인증 번호: 42"), 1)
            self.assertIn("status=timeout", result.stdout)

    def test_common_login_preflight_uses_klms_login_assist(self) -> None:
        text = (PROJECT_DIR / "src" / "sh" / "klms_common.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("KLMS_LOGIN_ASSIST_ENABLED", text)
        self.assertIn("KLMS_LOGIN_ASSIST_EARLY_ENABLED", text)
        self.assertIn("KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE", text)
        self.assertIn("KLMS_LOGIN_STATUS_REUSE_SECONDS", text)
        self.assertIn("klms_recent_login_status_ok", text)
        self.assertIn("klms_try_login_assist", text)
        self.assertIn("klms_login_assist_enabled", text)
        self.assertIn('"${KLMS_APP_RUN:-0}" == "1"', text)
        self.assertIn('"$fast_tab_state" == "unknown"', text)


if __name__ == "__main__":
    unittest.main()
