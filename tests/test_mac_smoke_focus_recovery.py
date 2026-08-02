import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
SMOKE_SCRIPT = PROJECT_DIR / "tools" / "smoke_klms_mac_accessibility.swift"


class MacSmokeFocusRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SMOKE_SCRIPT.read_text(encoding="utf-8")

    def test_accessibility_smoke_recovers_bounded_focus_or_window_loss(self) -> None:
        self.assertIn("try runSmokeWithFocusRecovery()", self.source)
        self.assertIn("for attempt in 0..<3", self.source)
        self.assertIn("transient focus/window loss", self.source)
        self.assertIn("NSRunningApplication(processIdentifier: targetProcessIdentifier)", self.source)
        self.assertIn("!hasVisibleDashboardWindow()", self.source)
        self.assertIn("hasMeaningfulWorkspaceAccessibilityTree(in: appElement)", self.source)
        self.assertIn("!app.isActive", self.source)
        self.assertIn("app.activate(options: [.activateAllWindows])", self.source)

    def test_accessibility_smoke_only_reopens_a_missing_candidate_window(self) -> None:
        bring_start = self.source.index("private func bringKLMSAppForward")
        bring_end = self.source.index("private func hasMeaningfulWorkspaceAccessibilityTree", bring_start)
        bring_source = self.source[bring_start:bring_end]
        reopen_start = self.source.index("private func requestDashboardWindowReopen")
        reopen_end = self.source.index("private func hasVisibleDashboardWindow", reopen_start)
        reopen_source = self.source[reopen_start:reopen_end]

        self.assertIn(
            "if !hasVisibleDashboardWindow() || !hasUsableAccessibilityWindow(in: appElement)",
            bring_source,
        )
        self.assertIn('process.executableURL = URL(fileURLWithPath: "/usr/bin/open")', reopen_source)
        self.assertIn('process.arguments = [appPath]', reopen_source)
        self.assertNotIn("tell application id", reopen_source)

    def test_resize_crossings_validate_selection_without_owning_global_focus(self) -> None:
        start = self.source.index("private func verifyRepeatedNavigationBoundaryCrossings")
        end = self.source.index("private func verifyCompactWorkspaceMenuOptions", start)
        crossing_source = self.source[start:end]

        self.assertIn("guard selectionIsPreserved else", crossing_source)
        self.assertNotIn(
            "NSWorkspace.shared.frontmostApplication?.processIdentifier",
            crossing_source,
        )


if __name__ == "__main__":
    unittest.main()
