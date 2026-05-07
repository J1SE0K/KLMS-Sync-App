import sys
import unittest
from pathlib import Path

from bs4 import BeautifulSoup


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import klms_sync  # noqa: E402


class NoticeBodyParagraphTests(unittest.TestCase):
    def test_exam_notice_labels_and_bullets_stay_separate(self) -> None:
        formatted = klms_sync.format_notice_body_text(
            "Time: April 23th (Thr), 9:00 am - 11:45 am "
            "Place: KAIST E15 Auditorium (대강당) "
            "Range: Week 1 to Week 7 lectures. "
            "⦁ Go to the restroom before coming to the exam. "
            "⦁ Bring your student ID card."
        )

        paragraphs = formatted.split("\n\n")
        self.assertEqual(
            paragraphs,
            [
                "Time: April 23th (Thr), 9:00 am - 11:45 am",
                "Place: KAIST E15 Auditorium (대강당)",
                "Range: Week 1 to Week 7 lectures.",
                "• Go to the restroom before coming to the exam.",
                "• Bring your student ID card.",
            ],
        )

    def test_courseboard_article_extraction_preserves_block_breaks(self) -> None:
        soup = BeautifulSoup(
            """
            <html><body>
              <div class="courseboard">
                <div class="content">
                  <p>Time: April 23th (Thr), 9:00 am - 11:45 am</p>
                  <p>Place: KAIST E15 Auditorium</p>
                  <p>Range: Week 1 to Week 7 lectures.</p>
                  <p>⦁ Bring your student ID card.</p>
                </div>
              </div>
            </body></html>
            """,
            "html.parser",
        )
        page = {
            "requestedUrl": "https://klms.kaist.ac.kr/courseboard/article.php?bwid=1",
            "html": str(soup),
        }

        body_text = klms_sync.extract_notice_body_text(page, soup)

        self.assertIn("Time: April 23th (Thr), 9:00 am - 11:45 am\n\nPlace:", body_text)
        self.assertIn("Range: Week 1 to Week 7 lectures.\n\n• Bring", body_text)


if __name__ == "__main__":
    unittest.main()
