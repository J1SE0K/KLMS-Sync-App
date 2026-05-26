import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class LoginAssistPerformanceTests(unittest.TestCase):
    def test_safari_step_advances_multiple_login_states_per_process(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "kaikey_safari_step.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("advanceUntilTerminal", text)
        self.assertIn("advanceOneStep", text)
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
        self.assertIn("klmsPageLooksAuthenticated", text)
        self.assertIn('options["force-twofactor"]', text)
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
        self.assertIn("KLMS_APP_RUN", text)
        self.assertIn('KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED="0"', text)
        self.assertIn("KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS", text)
        self.assertIn("KLMS_LOGIN_ASSIST_FORCE_TWOFACTOR", text)
        self.assertIn("--force-twofactor=$KAIKEY_FORCE_TWOFACTOR", text)
        self.assertIn("--refresh-twofactor=1", text)
        self.assertIn('KAIKEY_AUTO_LOGIN_POLL_SECONDS="${KAIKEY_AUTO_LOGIN_POLL_SECONDS:-0.2}"', text)
        self.assertIn('KAIKEY_SAFARI_STEP_POLL_MS="${KAIKEY_SAFARI_STEP_POLL_MS:-75}"', text)
        self.assertIn("--max-seconds=$KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS", text)
        self.assertIn("--poll-ms=$KAIKEY_SAFARI_STEP_POLL_MS", text)

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
