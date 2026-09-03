"""Unit tests for the Neukbao Visual Diagram analyzer.

Run from ``experiments/neukbao-visual-diagram``::

    python3 -m unittest discover -s tests -v

The first group builds a small synthetic git repository in a temp dir so the
tests do not depend on the host repository's contents. The second group runs
against the real repository (skipped when not inside a git worktree) and checks
the integrity guarantees listed in README.md.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROTO_DIR = HERE.parent
sys.path.insert(0, str(PROTO_DIR))

import analyze  # noqa: E402


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, encoding="utf-8"
    ).stdout


class PatternTests(unittest.TestCase):
    def test_single_star_does_not_cross_slash(self):
        self.assertTrue(analyze.match_pattern("run_all.sh", "*.sh"))
        self.assertFalse(analyze.match_pattern("bin/run_all.sh", "*.sh"))
        self.assertTrue(analyze.match_pattern("bin/run_all.sh", "bin/*.sh"))

    def test_double_star_matches_any_depth(self):
        self.assertTrue(analyze.match_pattern("src/python/klms_sync_v2/cli.py", "src/python/**"))
        self.assertTrue(analyze.match_pattern("apps/KLMSync/Package.swift", "apps/**"))
        self.assertTrue(analyze.match_pattern("anything/at/all.txt", "**"))
        self.assertFalse(analyze.match_pattern("tools/x.sh", "src/**"))

    def test_private_paths(self):
        self.assertTrue(analyze.is_private_path("config.env"))
        self.assertTrue(analyze.is_private_path("runtime/state/state.json"))
        self.assertTrue(analyze.is_private_path("course_files/x.pdf"))
        self.assertTrue(analyze.is_private_path("manual_assignment_overrides.json"))
        self.assertFalse(analyze.is_private_path("examples/config.env.example"))
        self.assertFalse(analyze.is_private_path("tools/security/security-tool-versions.env"))


class SyntheticRepoTests(unittest.TestCase):
    """Builds a mini repository resembling KLMS-Sync-App's shape."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="neukbao-test-"))
        repo = cls.tmp / "repo"
        repo.mkdir()
        files = {
            "sync_klms_core.sh": '#!/bin/zsh\nSCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"\nexec /bin/zsh "$SCRIPT_DIR/bin/sync_klms_core.sh" "$@"\n',
            "bin/sync_klms_core.sh": '#!/bin/zsh\nSCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"\nsource "$SCRIPT_DIR/src/sh/klms_common.sh"\n/usr/bin/env python3 "$KLMS_PYTHON_DIR/doctor.py"\n/usr/bin/env python3 -m klms_sync_v2.cli check\nhelper \\\n  "$KLMS_PYTHON_DIR/klms_transport.py"\n',
            "src/sh/klms_common.sh": '#!/bin/zsh\nKLMS_PYTHON_DIR="$SCRIPT_DIR/src/python"\n/usr/bin/osascript -l JavaScript "$KLMS_JS_DIR/sync_klms_notes.js"\n',
            "src/js/sync_klms_notes.js": '#!/usr/bin/osascript -l JavaScript\n// Notes runner\nconst p = `${scriptDir}/src/python/fetch_pages_backend.py`;\n',
            "src/python/doctor.py": "#!/usr/bin/env python3\nimport json\nimport klms_transport\n",
            "src/python/klms_transport.py": "#!/usr/bin/env python3\n",
            "src/python/fetch_pages_backend.py": "#!/usr/bin/env python3\nimport klms_transport\n",
            "src/python/klms_sync_v2/__init__.py": "from .models import Item\n",
            "src/python/klms_sync_v2/models.py": "class Item: pass\n",
            "src/python/klms_sync_v2/cli.py": "from .models import Item\nfrom . import models\n",
            "tests/test_doctor.py": 'import sys\nfrom pathlib import Path\nPROJECT_DIR = Path(__file__).resolve().parents[1]\nsys.path.insert(0, str(PROJECT_DIR / "src" / "python"))\nimport doctor\nFIXTURE = PROJECT_DIR / "tests" / "fixture.json"\n',
            "tests/fixture.json": "{}\n",
            "apps/KLMSync/Package.swift": (
                'let package = Package(\n  targets: [\n    .target(name: "KLMSShared"),\n'
                '    .executableTarget(name: "KLMSMac", dependencies: ["KLMSShared"]),\n'
                '    .testTarget(name: "KLMSSharedTests", dependencies: ["KLMSShared"]),\n  ]\n)\n'
            ),
            "apps/KLMSync/Sources/KLMSShared/Model.swift": "import Foundation\n",
            "apps/KLMSync/Sources/KLMSMac/App.swift": 'import KLMSShared\nlet script = "sync_klms_core.sh"\n',
            "apps/KLMSync/Tests/KLMSSharedTests/ModelTests.swift": "@testable import KLMSShared\nimport XCTest\n",
            "apps/KLMSync/EnginePayloadAllowlist.txt": "src/python/doctor.py\nbin/sync_klms_core.sh\nsync_klms_core.sh\n",
            "tools/klms_relay_server.mjs": '#!/usr/bin/env node\nimport http from "node:http";\nimport { x } from "./helper.mjs";\nimport "./side.mjs";\nimport {\n  a,\n  b,\n} from "./multi.mjs";\nconst doc = "docs/guide.md";\nconst server = http.createServer(async (request, response) => { if (request.url === "/v1/status") {} if (request.url === "/v1/commands") {} if (request.url === "/v1/logs") {} });\n',
            "tools/helper.mjs": "export const x = 1;\n",
            "tools/multi.mjs": "export const a = 1, b = 2;\n",
            "tools/side.mjs": "globalThis.side = 1;\n",
            "apps/Win/src/renderer.js": 'fetch("/v1/status");\nfetch("/v1/commands");\nfetch("/v1/logs");\n',
            "apps/Win/package.json": '{"main": "src/main.cjs", "scripts": {"test": "node --test test/relay.test.cjs"}}\n',
            "apps/Win/src/main.cjs": 'const path = require("path");\nconst preload = path.join(__dirname, "preload.cjs");\nconst entry = path.join(__dirname, "index.html");\nrequire("./relay-state.js");\n',
            "apps/Win/src/index.html": "<html></html>\n",
            "apps/Win/src/preload.cjs": "",
            "apps/Win/src/relay-state.js": "",
            "apps/Win/test/relay.test.cjs": 'require("../src/relay-state.js");\n',
            "README.md": "# demo\n",
            "docs/guide.md": "# guide\n",
            "config.env": "SECRET=1\n",
            "runtime/state.json": "{}\n",
            "vendor/python-packages/bs4/__init__.py": "",
        }
        for rel, content in files.items():
            path = repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        git(repo, "config", "commit.gpgsign", "false")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "first")
        (repo / "src/python/doctor.py").write_text("#!/usr/bin/env python3\nimport json\nimport klms_transport\n# v2\n", encoding="utf-8")
        git(repo, "commit", "-q", "-am", "second")
        cls.repo = repo
        component_map = {
            "version": 1,
            "system": {"id": "system", "label": "Demo", "description": "demo"},
            "components": [
                {"id": "tests-verification", "label": "Tests", "role": "t", "patterns": ["tests/**", "apps/KLMSync/Tests/**", "apps/Win/test/**"]},
                {"id": "relay", "label": "Relay", "role": "r", "patterns": ["tools/klms_relay_server.mjs", "tools/helper.mjs", "tools/multi.mjs", "tools/side.mjs"]},
                {"id": "windows", "label": "Windows", "role": "w", "patterns": ["apps/Win/**"]},
                {"id": "apple", "label": "Apple", "role": "a", "patterns": ["apps/KLMSync/Sources/**", "apps/KLMSync/Package.swift"]},
                {"id": "build", "label": "Build", "role": "b", "patterns": ["apps/KLMSync/EnginePayloadAllowlist.txt", "tools/**"]},
                {"id": "web", "label": "Web", "role": "web", "patterns": ["src/js/**", "src/python/fetch_pages_backend.py", "src/python/klms_transport.py"]},
                {"id": "pipeline", "label": "Pipeline", "role": "p", "patterns": ["src/python/**"]},
                {"id": "shell", "label": "Shell", "role": "s", "patterns": ["bin/*.sh", "src/sh/*.sh"]},
                {"id": "entry", "label": "Entry", "role": "e", "patterns": ["*.sh"]},
                {"id": "vendor", "label": "Vendor", "role": "v", "patterns": ["vendor/**"]},
                {"id": "docs", "label": "Docs", "role": "d", "patterns": ["*.md", "docs/**"]},
                {"id": "uncategorized", "label": "Uncategorized", "role": "u", "patterns": ["**"]},
            ],
        }
        cls.analyzer = analyze.Analyzer(repo, component_map)
        cls.graph = cls.analyzer.build()
        cls.nodes = {n["id"]: n for n in cls.graph["nodes"]}
        cls.edges = cls.graph["edges"]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def edge(self, etype, source, target):
        for e in self.edges:
            if e["type"] == etype and e["source"] == source and e["target"] == target:
                return e
        return None

    def test_private_files_not_read_even_if_tracked(self):
        self.assertNotIn("file:config.env", self.nodes)
        self.assertNotIn("file:runtime/state.json", self.nodes)
        self.assertEqual(self.graph["meta"]["tracked_file_count"], len([n for n in self.nodes.values() if n["kind"] == "file"]))

    def test_meta_commit_matches_head(self):
        self.assertEqual(self.graph["meta"]["source_commit"], git(self.repo, "rev-parse", "HEAD").strip())
        self.assertFalse(self.graph["meta"]["worktree_dirty"])

    def test_root_wrapper_invokes_bin(self):
        e = self.edge("invokes", "file:sync_klms_core.sh", "file:bin/sync_klms_core.sh")
        self.assertIsNotNone(e)
        self.assertEqual(e["confidence"], "high")
        self.assertIn("exec", e["evidence"][0]["reason"])

    def test_shell_source_and_klms_dir_vars(self):
        self.assertEqual(self.edge("imports", "file:bin/sync_klms_core.sh", "file:src/sh/klms_common.sh")["confidence"], "high")
        self.assertEqual(self.edge("invokes", "file:bin/sync_klms_core.sh", "file:src/python/doctor.py")["confidence"], "high")
        self.assertEqual(self.edge("invokes", "file:src/sh/klms_common.sh", "file:src/js/sync_klms_notes.js")["confidence"], "high")
        module_edge = self.edge("invokes", "file:bin/sync_klms_core.sh", "file:src/python/klms_sync_v2/cli.py")
        self.assertEqual(module_edge["confidence"], "medium")

    def test_python_imports(self):
        self.assertEqual(self.edge("imports", "file:src/python/doctor.py", "file:src/python/klms_transport.py")["confidence"], "high")
        self.assertIsNotNone(self.edge("imports", "file:src/python/klms_sync_v2/cli.py", "file:src/python/klms_sync_v2/models.py"))
        self.assertIsNotNone(self.edge("imports", "file:src/python/klms_sync_v2/__init__.py", "file:src/python/klms_sync_v2/models.py"))

    def test_test_file_relations_become_tests_edges(self):
        e = self.edge("tests", "file:tests/test_doctor.py", "file:src/python/doctor.py")
        self.assertIsNotNone(e)
        self.assertEqual(e["confidence"], "high")
        self.assertIsNone(self.edge("imports", "file:tests/test_doctor.py", "file:src/python/doctor.py"))

    def test_js_relations(self):
        self.assertIsNotNone(self.edge("invokes", "file:src/js/sync_klms_notes.js", "file:src/python/fetch_pages_backend.py"))
        self.assertIsNotNone(self.edge("imports", "file:tools/klms_relay_server.mjs", "file:tools/helper.mjs"))
        self.assertIsNotNone(self.edge("imports", "file:apps/Win/src/main.cjs", "file:apps/Win/src/relay-state.js"))
        self.assertEqual(self.edge("invokes", "file:apps/Win/src/main.cjs", "file:apps/Win/src/preload.cjs")["confidence"], "high")
        self.assertIsNotNone(self.edge("packages", "file:apps/Win/package.json", "file:apps/Win/src/main.cjs"))
        self.assertIsNotNone(self.edge("invokes", "file:apps/Win/package.json", "file:apps/Win/test/relay.test.cjs"))

    def test_swift_package_targets(self):
        shared_dir = "dir:apple:apps/KLMSync/Sources/KLMSShared"
        self.assertIn(shared_dir, self.nodes)
        self.assertIsNotNone(self.edge("packages", "file:apps/KLMSync/Package.swift", shared_dir))
        self.assertIsNotNone(self.edge("imports", "dir:apple:apps/KLMSync/Sources/KLMSMac", shared_dir))
        self.assertIsNotNone(self.edge("imports", "file:apps/KLMSync/Sources/KLMSMac/App.swift", shared_dir))
        self.assertIsNotNone(self.edge("tests", "file:apps/KLMSync/Tests/KLMSSharedTests/ModelTests.swift", shared_dir))
        # bare basename string in Swift -> low confidence only
        e = self.edge("invokes", "file:apps/KLMSync/Sources/KLMSMac/App.swift", "file:sync_klms_core.sh")
        self.assertEqual(e["confidence"], "low")

    def test_allowlist_packages(self):
        e = self.edge("packages", "file:apps/KLMSync/EnginePayloadAllowlist.txt", "file:src/python/doctor.py")
        self.assertEqual(e["confidence"], "high")

    def test_multiline_js_import(self):
        self.assertIsNotNone(self.edge("imports", "file:tools/klms_relay_server.mjs", "file:tools/multi.mjs"))
        self.assertIsNotNone(self.edge("imports", "file:tools/klms_relay_server.mjs", "file:tools/side.mjs"))

    def test_js_import_regex_edge_cases(self):
        text = 'const a = 1\nimport "./register.js"\n// copied from "./old.js"\nimport {\n  x,\n} from "./multi.js";\nconst y = 2\nexport { z } from "./z.js"\n'
        side = [m.group(1) for m in analyze.JS_SIDE_EFFECT_IMPORT_RE.finditer(text)]
        frm = [m.group(1) for m in analyze.JS_FROM_IMPORT_RE.finditer(text)]
        self.assertEqual(side, ["./register.js"])
        self.assertEqual(frm, ["./multi.js", "./z.js"])

    def test_test_file_reading_data_file_is_packages_not_tests(self):
        e = self.edge("packages", "file:tests/test_doctor.py", "file:tests/fixture.json")
        self.assertIsNotNone(e)
        self.assertIsNone(self.edge("tests", "file:tests/test_doctor.py", "file:tests/fixture.json"))

    def test_non_executable_load_is_never_invokes(self):
        # main.cjs loads index.html via path.join(__dirname, ...) -> packages, not invokes
        self.assertIsNone(self.edge("invokes", "file:apps/Win/src/main.cjs", "file:apps/Win/src/index.html"))
        e = self.edge("packages", "file:apps/Win/src/main.cjs", "file:apps/Win/src/index.html")
        self.assertIsNotNone(e)
        self.assertEqual(e["confidence"], "high")

    def test_non_executable_path_string_is_packages_low(self):
        e = self.edge("packages", "file:tools/klms_relay_server.mjs", "file:docs/guide.md")
        self.assertIsNotNone(e)
        self.assertEqual(e["confidence"], "low")
        self.assertIsNone(self.edge("invokes", "file:tools/klms_relay_server.mjs", "file:docs/guide.md"))

    def test_klms_dir_argument_reference_is_medium(self):
        e = self.edge("invokes", "file:bin/sync_klms_core.sh", "file:src/python/klms_transport.py")
        self.assertEqual(e["confidence"], "medium")

    def test_communicates_via_shared_routes(self):
        e = self.edge("communicates", "file:apps/Win/src/renderer.js", "file:tools/klms_relay_server.mjs")
        self.assertIsNotNone(e)
        self.assertEqual(e["confidence"], "medium")
        self.assertIn("/v1/status", e["evidence"][0]["reason"])

    def test_component_edges_aggregate_members(self):
        comp = self.edge("invokes", "component:entry", "component:shell")
        self.assertIsNotNone(comp)
        self.assertEqual(comp["level"], "component")
        self.assertEqual(comp["member_edge_count"], 1)
        self.assertIn("invokes:file:sync_klms_core.sh->file:bin/sync_klms_core.sh", comp["member_edge_ids"])

    def test_git_stats(self):
        doctor = self.nodes["file:src/python/doctor.py"]
        self.assertEqual(doctor["commit_count"], 2)
        self.assertEqual(self.nodes["file:src/python/klms_transport.py"]["commit_count"], 1)
        self.assertIsNotNone(doctor["last_changed_at"])
        pipeline = self.nodes["component:pipeline"]
        self.assertEqual(pipeline["file_count"], 4)
        self.assertEqual(pipeline["commit_count"], 2 + 1 + 1 + 1)

    def test_every_edge_has_evidence_and_confidence(self):
        for e in self.edges:
            self.assertIn(e["confidence"], ("high", "medium", "low"), e["id"])
            self.assertTrue(e["evidence"], e["id"])
            self.assertIn(e["source"], self.nodes, e["id"])
            self.assertIn(e["target"], self.nodes, e["id"])

    def test_no_uncategorized_files(self):
        self.assertNotIn("component:uncategorized", self.nodes)

    def test_language_detection(self):
        self.assertEqual(self.nodes["file:src/js/sync_klms_notes.js"]["language"], "JavaScript (JXA)")
        self.assertEqual(self.nodes["file:tools/klms_relay_server.mjs"]["language"], "JavaScript (Node)")
        self.assertEqual(self.nodes["file:sync_klms_core.sh"]["language"], "Shell (zsh)")
        self.assertEqual(self.nodes["file:src/python/doctor.py"]["language"], "Python")

    def test_cli_writes_output(self):
        out = self.tmp / "graph.json"
        component_map = self.tmp / "cm.json"
        component_map.write_text(json.dumps({
            "version": 1,
            "system": {"id": "system", "label": "Demo", "description": "demo"},
            "components": [{"id": "all", "label": "All", "role": "x", "patterns": ["**"]}],
        }), encoding="utf-8")
        code = analyze.main(["--repo", str(self.repo), "--output", str(out), "--component-map", str(component_map)])
        self.assertEqual(code, 0)
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(set(data), {"meta", "nodes", "edges"})


class RealRepositoryTests(unittest.TestCase):
    """Integrity checks against the host repository's generated graph.json."""

    @classmethod
    def setUpClass(cls):
        cls.repo = PROTO_DIR.parents[1]
        try:
            git(cls.repo, "rev-parse", "--show-toplevel")
        except (subprocess.CalledProcessError, FileNotFoundError):
            raise unittest.SkipTest("not inside a git worktree")
        cls.graph_path = PROTO_DIR / "public" / "graph.json"
        if not cls.graph_path.exists():
            raise unittest.SkipTest("public/graph.json not generated yet")
        cls.graph = json.loads(cls.graph_path.read_text(encoding="utf-8"))
        cls.tracked = set(git(cls.repo, "ls-files", "-z").split("\0")) - {""}
        cls.nodes = {n["id"]: n for n in cls.graph["nodes"]}

    def test_all_file_nodes_are_tracked(self):
        for n in self.graph["nodes"]:
            if n["kind"] == "file":
                self.assertIn(n["path"], self.tracked, n["id"])
                self.assertFalse(analyze.is_private_path(n["path"]), n["id"])

    def test_all_edges_reference_existing_nodes(self):
        for e in self.graph["edges"]:
            self.assertIn(e["source"], self.nodes, e["id"])
            self.assertIn(e["target"], self.nodes, e["id"])
            self.assertTrue(e["evidence"], e["id"])
            self.assertIn(e["confidence"], ("high", "medium", "low"))
            self.assertIn(e["type"], analyze.EDGE_TYPES)

    def test_evidence_paths_are_tracked_or_patterns(self):
        for e in self.graph["edges"]:
            for ev in e["evidence"]:
                p = ev["path"]
                ok = p in self.tracked or p == "." or "*" in p or self.repo.joinpath(p).is_dir()
                self.assertTrue(ok, f"{e['id']} evidence {p}")

    def test_source_commit_is_a_real_ancestor_of_head(self):
        """graph.json must describe a commit that is actually in this history.

        It is normally HEAD. Right after the prototype itself is committed the
        recorded commit is HEAD's parent until analyze.py is run again, so the
        assertion is "reachable from HEAD", which still fails for a fabricated,
        foreign or future commit id.

        This checks provenance, not freshness: a graph.json generated many
        commits ago still passes. Freshness is a manual step (re-run analyze.py)
        documented in README.md.
        """
        commit = self.graph["meta"]["source_commit"]
        self.assertRegex(commit, r"^[0-9a-f]{40}$")
        if git(self.repo, "rev-parse", "--is-shallow-repository").strip() == "true":
            self.skipTest("shallow clone: the recorded commit object is not present")
        kind = subprocess.run(
            ["git", "-C", str(self.repo), "cat-file", "-t", commit],
            capture_output=True, encoding="utf-8",
        )
        self.assertEqual(kind.returncode, 0, f"{commit} is not an object in this repository")
        self.assertEqual(kind.stdout.strip(), "commit")
        reachable = subprocess.run(
            ["git", "-C", str(self.repo), "merge-base", "--is-ancestor", commit, "HEAD"],
            capture_output=True,
        )
        self.assertEqual(reachable.returncode, 0, f"{commit} is not reachable from HEAD; re-run analyze.py")

    def test_every_file_node_exists_in_the_recorded_commit(self):
        """Node paths are checked against the tree of meta.source_commit, not just today's checkout."""
        commit = self.graph["meta"]["source_commit"]
        if git(self.repo, "rev-parse", "--is-shallow-repository").strip() == "true":
            self.skipTest("shallow clone: the recorded commit tree is not present")
        tree = set(git(self.repo, "ls-tree", "-r", "--name-only", "-z", commit).split("\0")) - {""}
        self.assertTrue(tree, "recorded commit has no tree")
        expected = {p for p in tree if not analyze.is_private_path(p)}
        actual = {n["path"] for n in self.graph["nodes"] if n["kind"] == "file"}
        missing = sorted(expected - actual)[:5]
        extra = sorted(actual - expected)[:5]
        self.assertFalse(missing, f"graph.json is stale: {len(expected - actual)} file(s) of {commit[:12]} are absent, e.g. {missing}")
        self.assertFalse(extra, f"graph.json has file(s) not in {commit[:12]}: {extra}")
        self.assertEqual(self.graph["meta"]["tracked_file_count"], len(actual))

    def test_expected_components_exist(self):
        labels = {n["label"] for n in self.graph["nodes"] if n["kind"] == "component"}
        for expected in ("User Entry Points", "Shell Orchestration", "KLMS Web Access", "Parsing and File Pipeline",
                         "Native macOS Integration", "Apple Applications", "Windows Companion", "Relay Infrastructure",
                         "Tests and Verification", "Build and Distribution"):
            self.assertIn(expected, labels)
        self.assertNotIn("Uncategorized", labels)

    def test_root_wrappers_all_delegate_to_bin(self):
        wrappers = [p for p in self.tracked if p.endswith(".sh") and "/" not in p]
        self.assertTrue(wrappers)
        for w in wrappers:
            eid = f"invokes:file:{w}->file:bin/{w}"
            self.assertIn(eid, {e["id"] for e in self.graph["edges"]}, w)


if __name__ == "__main__":
    unittest.main()
