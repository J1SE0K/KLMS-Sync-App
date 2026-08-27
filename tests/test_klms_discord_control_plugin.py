import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class KlmsDiscordControlPluginTests(unittest.TestCase):
    def test_plugin_only_opens_global_skill_and_cannot_execute_sync_directly(self) -> None:
        text = (
            PROJECT_DIR
            / "integrations"
            / "hermes-klms-discord-control"
            / "plugin.js"
        ).read_text(encoding="utf-8")

        self.assertIn('ctx.host.navigate("/klms-sync")', text)
        self.assertNotIn('ctx.host.request("klms.sync"', text)
        self.assertNotIn("execute-approved", text)


if __name__ == "__main__":
    unittest.main()