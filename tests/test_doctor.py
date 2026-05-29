import sys
import json
import os
import tempfile
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

    def test_dashboard_cache_check_uses_namespace_cache_when_root_is_stale_login(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cache_dir = Path(tmp)
            (cache_dir / "core").mkdir()
            (cache_dir / "dashboard.json").write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/login/ssologin.php",
                            "title": "https://klms.kaist.ac.kr/login/ssologin.php",
                            "html": "",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            (cache_dir / "core" / "dashboard.json").write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "강의 현황",
                            "html": '<a href="/login/logout.php">logout</a>',
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            now = 1_780_000_000
            os.utime(cache_dir / "core" / "dashboard.json", (now, now))
            os.utime(cache_dir / "dashboard.json", (now + 20, now + 20))

            result = doctor.dashboard_login_cache_check_from_cache(cache_dir)

            self.assertEqual(result["status"], "ok")
            self.assertIn("core/dashboard.json", result["detail"])

    def test_dashboard_cache_check_prefers_namespace_cache_even_when_root_login_cache_is_newer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cache_dir = Path(tmp)
            (cache_dir / "core").mkdir()
            (cache_dir / "dashboard.json").write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/login/ssologin.php",
                            "title": "https://klms.kaist.ac.kr/login/ssologin.php",
                            "html": "",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            (cache_dir / "core" / "dashboard.json").write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "강의 현황",
                            "html": '<a href="/login/logout.php">logout</a>',
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            now = 1_780_000_000
            os.utime(cache_dir / "core" / "dashboard.json", (now, now))
            os.utime(cache_dir / "dashboard.json", (now + 300, now + 300))

            result = doctor.dashboard_login_cache_check_from_cache(cache_dir)

            self.assertEqual(result["status"], "ok")
            self.assertIn("core/dashboard.json", result["detail"])


if __name__ == "__main__":
    unittest.main()
