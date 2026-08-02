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
        self.assertIn("!hasMeaningfulWorkspaceAccessibilityTree(in: appElement)", self.source)

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
