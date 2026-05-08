import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import doctor  # noqa: E402


class DoctorTests(unittest.TestCase):
    def test_dashboard_cache_check_uses_login_analyzer_not_raw_substring_scan(self) -> None:
        result = doctor.dashboard_login_cache_check(
            [
                {
                    "requestedUrl": "https://klms.kaist.ac.kr/my/",
                    "url": "https://klms.kaist.ac.kr/my/",
                    "title": "강의 현황",
                    "html": '<a href="/login/logout.php">logout</a>',
                }
            ]
        )

        self.assertEqual(result["status"], "ok")
        self.assertIn("강의 현황", result["detail"])

    def test_dashboard_cache_check_warns_on_actual_login_page(self) -> None:
        result = doctor.dashboard_login_cache_check(
            [
                {
                    "requestedUrl": "https://klms.kaist.ac.kr/my/",
                    "url": "https://klms.kaist.ac.kr/login/index.php",
                    "title": "Single Sign On",
                    "html": '<input name="username">',
                }
            ]
        )

        self.assertEqual(result["status"], "warn")
        self.assertIn("로그인", result["detail"])


if __name__ == "__main__":
    unittest.main()
