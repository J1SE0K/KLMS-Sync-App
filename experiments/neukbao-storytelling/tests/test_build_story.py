"""Unit and integration tests for build_story.py.

Run from experiments/neukbao-storytelling:
    python3 -m unittest discover -s tests -v
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))

import build_story as bs  # noqa: E402


def _git(repo: Path, *args: str, env: dict | None = None) -> str:
    base_env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Tester",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "Tester",
        "GIT_COMMITTER_EMAIL": "t@example.com",
    }
    if env:
        base_env.update(env)
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True, env=base_env)
    return out.stdout.decode("utf-8", "replace").strip()


def _commit(repo: Path, message: str, files: dict[str, str], when: str, delete: list[str] | None = None) -> str:
    for rel, content in files.items():
        p = repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
    for rel in delete or []:
        (repo / rel).unlink()
    _git(repo, "add", "-A")
    env = {"GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when}
    _git(repo, "commit", "-q", "-m", message, env=env)
    return _git(repo, "rev-parse", "HEAD")


class FixtureRepo:
    """Small synthetic repository with a rename, a revert, a tag, a long gap and a merge."""

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "repo"
        self.path.mkdir()
        _git(self.path, "init", "-q", "-b", "main")
        self.hashes: dict[str, str] = {}
        p = self.path
        self.hashes["init"] = _commit(p, "Initial tooling", {"sync.py": "print(1)\n", "README.md": "# x\n"}, "2026-05-01T10:00:00+09:00")
        self.hashes["fix1"] = _commit(p, "Fix notice parsing", {"sync.py": "print(2)\n"}, "2026-05-01T11:00:00+09:00")
        self.hashes["fix2"] = _commit(p, "Fix notice paragraph breaks", {"sync.py": "print(3)\n", "tests/test_notice.py": "ok\n"}, "2026-05-01T12:00:00+09:00")
        # rename
        (p / "src").mkdir()
        _git(p, "mv", "sync.py", "src/sync.py")
        _git(p, "commit", "-q", "-m", "Organize source tree", env={"GIT_AUTHOR_DATE": "2026-05-01T13:00:00+09:00", "GIT_COMMITTER_DATE": "2026-05-01T13:00:00+09:00"})
        self.hashes["rename"] = _git(p, "rev-parse", "HEAD")
        _git(p, "tag", "v0.1")
        # long gap + new platform dir
        self.hashes["app"] = _commit(p, "Add Mac app", {"apps/Mac/App.swift": "struct A {}\n", "apps/Mac/Package.swift": "// pkg\n"}, "2026-05-20T10:00:00+09:00")
        self.hashes["app2"] = _commit(p, "Show Mac app status", {"apps/Mac/App.swift": "struct A { var s = 1 }\n"}, "2026-05-20T10:30:00+09:00")
        self.hashes["wd"] = _commit(p, "add watchdog", {"apps/Mac/App.swift": "struct A { var s = 2 }\n"}, "2026-05-20T11:00:00+09:00")
        self.hashes["revert"] = _commit(p, 'Revert "add watchdog"', {"apps/Mac/App.swift": "struct A { var s = 1 }\n"}, "2026-05-20T11:10:00+09:00")
        # side branch + merge
        _git(p, "checkout", "-q", "-b", "fix/side")
        self.hashes["side"] = _commit(p, "fix: accept empty dashboard", {"src/sync.py": "print(4)\n"}, "2026-06-01T10:00:00+09:00")
        _git(p, "checkout", "-q", "main")
        _git(p, "merge", "-q", "--no-ff", "-m", "Merge branch 'fix/side'", "fix/side", env={"GIT_AUTHOR_DATE": "2026-06-01T11:00:00+09:00", "GIT_COMMITTER_DATE": "2026-06-01T11:00:00+09:00"})
        self.hashes["merge"] = _git(p, "rev-parse", "HEAD")
        self.hashes["last"] = _commit(p, "fix: keep identifiers stable", {"src/sync.py": "print(5)\n"}, "2026-06-01T12:00:00+09:00")

    def cleanup(self) -> None:
        self.tmp.cleanup()


class PureFunctionTests(unittest.TestCase):
    def test_classify_conventional_and_verb_types(self):
        self.assertEqual(bs.classify_type("feat(ios): add thing"), ("feat", "ios", "feat"))
        self.assertEqual(bs.classify_type("Fix notice parsing")[2], "fix")
        self.assertEqual(bs.classify_type("Add Mac app")[2], "feat")
        self.assertEqual(bs.classify_type('Revert "add watchdog"')[2], "fix")
        self.assertEqual(bs.classify_type("Something unusual")[2], "other")

    def test_numstat_rename_forms(self):
        self.assertEqual(bs.parse_numstat_path("a/{old => new}/f.py"), ("a/new/f.py", "a/old/f.py"))
        self.assertEqual(bs.parse_numstat_path("old.py => src/new.py"), ("src/new.py", "old.py"))
        self.assertEqual(bs.parse_numstat_path("plain.py"), ("plain.py", None))

    def test_scope_and_subsystem(self):
        self.assertEqual(bs.top_level_scope("apps/KLMSync/Sources/x.swift"), "apps/KLMSync")
        self.assertEqual(bs.top_level_scope("README.md"), "(root)")
        self.assertEqual(bs.subsystem_for("deploy/relay/Dockerfile"), "relay")
        self.assertEqual(bs.subsystem_for("src/python/x.py"), "sync-engine")

    def test_tokenize_drops_stopwords_and_prefix(self):
        self.assertEqual(bs.tokenize("fix(mac): Fix the notice paragraph breaks"), ["notice", "paragraph", "breaks"])

    def test_temporal_score_shape(self):
        self.assertEqual(bs.temporal_score(0.5), 1.0)
        self.assertEqual(bs.temporal_score(100), 0.0)
        self.assertTrue(0 < bs.temporal_score(24) < 1)


class FixtureRepoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = FixtureRepo()
        cls.commits, cls.meta = bs.collect_commits(str(cls.repo.path), "HEAD")
        cls.by_hash = cls.meta["by_hash"]

    @classmethod
    def tearDownClass(cls):
        cls.repo.cleanup()

    def test_collects_all_commits_in_order(self):
        h = self.repo.hashes
        hashes = [c["hash"] for c in self.commits]
        self.assertEqual(len(hashes), 11)
        self.assertEqual(hashes[0], h["init"])
        self.assertEqual(hashes[-1], h["last"])
        self.assertEqual(self.meta["source"]["head_commit"], h["last"])

    def test_rename_tag_merge_and_revert_metadata(self):
        h = self.repo.hashes
        rename = self.by_hash[h["rename"]]
        self.assertEqual(rename["rename_candidates"], [{"from": "sync.py", "to": "src/sync.py"}])
        self.assertEqual(rename["tags"], ["v0.1"])
        merge = self.by_hash[h["merge"]]
        self.assertTrue(merge["is_merge"])
        self.assertEqual(self.by_hash[h["side"]]["merged_by"], h["merge"])
        self.assertIsNone(self.by_hash[h["side"]]["first_parent_order"])
        self.assertEqual(self.by_hash[h["revert"]]["reverts_commit"], h["wd"])
        self.assertEqual(self.by_hash[h["app"]]["new_top_dirs"], ["apps/Mac"])

    def test_clustering_boundaries(self):
        h = self.repo.hashes
        clusters = bs.cluster_commits(self.commits, dict(bs.DEFAULT_WEIGHTS), bs.DEFAULT_THRESHOLD, 1)
        groups = [[c["hash"] for c in cl["commits"]] for cl in clusters]
        # tag + long gap + new platform separate the early scripts from the app
        first = next(g for g in groups if h["init"] in g)
        self.assertIn(h["fix1"], first)
        self.assertNotIn(h["app"], first)
        # revert stays with the reverted commit
        wd = next(g for g in groups if h["wd"] in g)
        self.assertIn(h["revert"], wd)
        # side branch commit stays with its merge commit; commit after merge starts a new cluster
        side = next(g for g in groups if h["side"] in g)
        self.assertIn(h["merge"], side)
        self.assertNotIn(h["last"], side)
        reasons = [cl["boundary_reasons"] for cl in clusters]
        flat = [r.split(":")[0] for rs in reasons for r in rs]
        # rename commit carries tag v0.1 and is followed by a 19-day gap; hard_boundary reports long_gap first
        self.assertIn("long_gap", flat)
        self.assertIn("merge", flat)
        # the app commit also starts a new top-level dir; hard_boundary reports the first matching reason only
        self.assertEqual(bs.hard_boundary(self.by_hash[h["app"]], self.by_hash[h["app"]]), "new_platform:apps/Mac")

    def test_auto_episodes_are_chronological_and_evidence_backed(self):
        clusters = bs.cluster_commits(self.commits, dict(bs.DEFAULT_WEIGHTS), bs.DEFAULT_THRESHOLD, bs.MIN_CLUSTER_SIZE)
        episodes = [bs.build_auto_episode(i, cl, self.meta) for i, cl in enumerate(clusters)]
        self.assertTrue(episodes)
        for i, ep in enumerate(episodes):
            self.assertEqual(ep["order"], i + 1)
            self.assertTrue(ep["claims"])
            for claim in ep["claims"]:
                self.assertIn(claim["status"], bs.CLAIM_STATUSES)
                self.assertTrue(claim["evidence_commit_ids"])
                for eh in claim["evidence_commit_ids"]:
                    self.assertIn(eh, ep["commit_ids"])
            if i:
                self.assertLessEqual(episodes[i - 1]["ended_at"], ep["started_at"])
        covered = [h for ep in episodes for h in ep["commit_ids"]]
        self.assertEqual(sorted(covered), sorted(c["hash"] for c in self.commits))
        self.assertEqual(len(covered), len(set(covered)))

    def _override(self, **extra):
        h = self.repo.hashes
        base = {
            "version": 1,
            "story": {"title": "Fixture story"},
            "episodes": [
                {
                    "id": "ep-a", "title": "Scripts", "commit_range": {"from": h["init"][:7], "to": h["rename"]},
                    "change_type": ["introduction"], "confidence": "high",
                    "summary": "s", "problem_or_context": "p", "what_changed": "w", "result": "r",
                    "claims": [{
                        "id": "a1", "text": "sync.py was renamed", "status": "observed", "confidence": "high",
                        "evidence_commit_ids": [h["rename"]], "evidence_files": ["src/sync.py"],
                    }],
                },
                {
                    "id": "ep-b", "title": "App and merge", "commit_range": {"from": h["app"], "to": h["last"]},
                    "exclude_commit_ids": [h["last"]],
                    "change_type": ["extension", "repair"], "confidence": "medium",
                    "summary": "s", "problem_or_context": "p", "what_changed": "w", "result": "r",
                    "claims": [{
                        "id": "b1", "text": "side branch fix merged", "status": "supported", "confidence": "medium",
                        "evidence_commit_ids": [h["side"], h["merge"]], "evidence_files": ["src/sync.py"],
                    }],
                },
            ],
        }
        base.update(extra)
        return base

    def _auto(self):
        clusters = bs.cluster_commits(self.commits, dict(bs.DEFAULT_WEIGHTS), bs.DEFAULT_THRESHOLD, bs.MIN_CLUSTER_SIZE)
        return [bs.build_auto_episode(i, cl, self.meta) for i, cl in enumerate(clusters)]

    def test_override_applies_ranges_exclusions_and_side_branches(self):
        h = self.repo.hashes
        curated, extra = bs.apply_override(self._override(), self._auto(), self.commits, self.meta)
        self.assertEqual([e["id"] for e in curated], ["ep-a", "ep-b"])
        self.assertEqual(curated[0]["commit_ids"], [h["init"], h["fix1"], h["fix2"], h["rename"]])
        self.assertIn(h["side"], curated[1]["commit_ids"])
        self.assertNotIn(h["last"], curated[1]["commit_ids"])
        self.assertEqual(curated[1]["auto_origin"]["excluded_commit_ids"], [h["last"]])
        self.assertEqual(extra["story"]["title"], "Fixture story")
        self.assertEqual(curated[0]["source"], "override")

    def test_override_rejects_unknown_commit(self):
        ov = self._override()
        ov["episodes"][0]["claims"][0]["evidence_commit_ids"] = ["deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"]
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)

    def test_override_rejects_evidence_outside_episode(self):
        h = self.repo.hashes
        ov = self._override()
        ov["episodes"][0]["claims"][0]["evidence_commit_ids"] = [h["last"]]
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)

    def test_override_rejects_file_not_in_commit(self):
        ov = self._override()
        ov["episodes"][0]["claims"][0]["evidence_files"] = ["not/a/file.py"]
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)

    def test_override_rejects_overlap_bad_status_and_missing_claims(self):
        h = self.repo.hashes
        # duplicate membership: ep-b range starts inside ep-a
        ov = self._override()
        ov["episodes"][1]["commit_range"]["from"] = h["rename"]
        with self.assertRaisesRegex(bs.OverrideValidationError, "already belongs"):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        # chronological overlap without shared commits: ep-a = {init, fix2}, ep-b = {fix1, rename}
        ov = self._override()
        ov["episodes"][0].pop("commit_range")
        ov["episodes"][0]["commit_ids"] = [h["init"], h["fix2"]]
        ov["episodes"][0]["claims"][0].update({"evidence_commit_ids": [h["fix2"]], "evidence_files": ["sync.py"]})
        ov["episodes"][1].pop("commit_range")
        ov["episodes"][1].pop("exclude_commit_ids")
        ov["episodes"][1]["commit_ids"] = [h["fix1"], h["rename"]]
        ov["episodes"][1]["claims"][0].update({"evidence_commit_ids": [h["rename"]], "evidence_files": ["src/sync.py"]})
        with self.assertRaisesRegex(bs.OverrideValidationError, "overlaps in time"):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        ov = self._override()
        ov["episodes"][0]["claims"][0]["status"] = "guessed"
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        ov = self._override()
        ov["episodes"][0]["claims"] = []
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        ov = self._override()
        ov["episodes"][0]["claims"][0].update({"status": "inferred", "limitations": ""})
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)

    def test_range_endpoint_and_prefix_validation(self):
        h = self.repo.hashes
        ov = self._override()
        ov["episodes"][1]["commit_range"] = {"from": h["last"], "to": h["app"]}
        with self.assertRaisesRegex(bs.OverrideValidationError, "comes after"):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        ov = self._override()
        ov["episodes"][1]["commit_range"] = {"from": h["side"], "to": h["last"]}
        with self.assertRaisesRegex(bs.OverrideValidationError, "first-parent"):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        # ambiguous prefix: build a fake by_hash where two hashes share a prefix
        fake = {"abcd1234" + "0" * 32: {}, "abcd9999" + "0" * 32: {}}
        with self.assertRaisesRegex(bs.OverrideValidationError, "ambiguous"):
            bs.resolve_hash("abcd", fake, "test")
        with self.assertRaisesRegex(bs.OverrideValidationError, "invalid commit hash"):
            bs.resolve_hash("xyz", fake, "test")

    def test_claim_patch_evidence_add_is_validated(self):
        h = self.repo.hashes
        ov = self._override()
        ov["episodes"][0]["claims"][0]["evidence_files"] = []
        with self.assertRaisesRegex(bs.OverrideValidationError, "needs at least one evidence file"):
            bs.apply_override(ov, self._auto(), self.commits, self.meta)
        ov["episodes"][0]["claims"][0]["status"] = "supported"
        curated, _ = bs.apply_override(ov, self._auto(), self.commits, self.meta)
        self.assertEqual(curated[0]["claims"][0]["evidence_files"], [])
        auto = self._auto()
        target = next(e for e in auto if h["init"] in e["commit_ids"])
        claim = target["claims"][0]
        patch = {"version": 1, "auto_patches": {target["id"]: {"claims": {claim["id"]: {
            "evidence_commit_ids_add": [h["fix1"]], "evidence_files_add": ["sync.py"]}}}}}
        bs.apply_override(patch, auto, self.commits, self.meta)
        self.assertIn(h["fix1"], target["claims"][0]["evidence_commit_ids"])
        self.assertIn("sync.py", target["claims"][0]["evidence_files"])
        bad = {"version": 1, "auto_patches": {target["id"]: {"claims": {claim["id"]: {"evidence_files_add": ["nope.txt"]}}}}}
        with self.assertRaisesRegex(bs.OverrideValidationError, "not changed by"):
            bs.apply_override(bad, self._auto(), self.commits, self.meta)

    def test_auto_claims_pass_validator(self):
        for ep in self._auto():
            members = set(ep["commit_ids"])
            for claim in ep["claims"]:
                bs.validate_claim(claim, ep["id"], members, self.by_hash)

    def test_hours_between_clamps_backward_author_dates(self):
        self.assertEqual(bs.hours_between("2026-05-02T10:00:00+09:00", "2026-05-01T10:00:00+09:00"), 0.0)
        self.assertEqual(bs.hours_between("2026-05-01T10:00:00+09:00", "2026-05-01T12:00:00+09:00"), 2.0)

    def test_auto_patch_updates_title_and_claim_status(self):
        auto = self._auto()
        target = auto[0]
        claim = target["claims"][0]
        ov = {"version": 1, "episodes": [], "auto_patches": {target["id"]: {"title": "Patched", "claims": {claim["id"]: {"status": "inferred", "limitations": "manual downgrade"}}}}}
        curated, extra = bs.apply_override(ov, auto, self.commits, self.meta)
        self.assertEqual(curated, [])
        self.assertEqual(target["title"], "Patched")
        self.assertEqual(target["claims"][0]["status"], "inferred")
        self.assertEqual(target["source"], "auto+patched")
        self.assertEqual(extra["auto_patched"], [target["id"]])
        bad = {"version": 1, "auto_patches": {"episode-auto-nope": {"title": "x"}}}
        with self.assertRaises(bs.OverrideValidationError):
            bs.apply_override(bad, self._auto(), self.commits, self.meta)

    def test_cli_end_to_end_without_override_and_excerpts(self):
        with tempfile.TemporaryDirectory() as out:
            commits_out = os.path.join(out, "commits.json")
            story_out = os.path.join(out, "story.json")
            rc = bs.main(["--repo", str(self.repo.path), "--ref", "HEAD", "--commits-output", commits_out, "--story-output", story_out, "--no-override"])
            self.assertEqual(rc, 0)
            story = json.load(open(story_out, encoding="utf-8"))
            commits = json.load(open(commits_out, encoding="utf-8"))
            self.assertEqual(story["source"]["head_commit"], self.repo.hashes["last"])
            self.assertEqual(commits["commit_count"], 11)
            self.assertFalse(story["curation"]["override_applied"])
            self.assertEqual(story["curation"]["uncovered_commit_count"], 0)
            self.assertTrue(story["evidence_excerpts"])
            some = next(iter(story["evidence_excerpts"].values()))
            self.assertTrue(any(v["lines"] for v in some.values()))

    def test_cli_returns_error_code_on_invalid_override(self):
        with tempfile.TemporaryDirectory() as out:
            ov_path = os.path.join(out, "bad.override.json")
            ov = self._override()
            ov["episodes"][0]["commit_range"]["from"] = "0000000"
            json.dump(ov, open(ov_path, "w", encoding="utf-8"))
            rc = bs.main(["--repo", str(self.repo.path), "--commits-output", os.path.join(out, "c.json"), "--story-output", os.path.join(out, "s.json"), "--override", ov_path])
            self.assertEqual(rc, 2)
            self.assertFalse(os.path.exists(os.path.join(out, "s.json")))


class RealRepositoryOutputTests(unittest.TestCase):
    """Validate the committed public/story.json against the actual KLMS-Sync-App history when available."""

    @classmethod
    def setUpClass(cls):
        cls.story_path = ROOT / "public" / "story.json"
        cls.repo_root = ROOT.parent.parent
        cls.available = cls.story_path.exists() and (cls.repo_root / ".git").exists()
        if not cls.available:
            return
        cls.story = json.loads(cls.story_path.read_text(encoding="utf-8"))
        cls.known = set(_git(cls.repo_root, "rev-list", cls.story["source"]["head_commit"]).split())

    def setUp(self):
        if not self.available:
            self.skipTest("public/story.json or repository not available")

    def test_head_is_recorded_and_episode_count_in_range(self):
        self.assertRegex(self.story["source"]["head_commit"], r"^[0-9a-f]{40}$")
        self.assertIn(self.story["source"]["head_commit"], self.known)
        self.assertTrue(4 <= len(self.story["episodes"]) <= 8)

    def test_story_json_matches_current_override(self):
        """Catch a stale public/story.json left behind after editing story.override.json without rebuilding."""
        override_path = ROOT / "story.override.json"
        if not override_path.exists():
            self.skipTest("no override present")
        override = json.loads(override_path.read_text(encoding="utf-8"))
        self.assertTrue(self.story["curation"]["override_applied"])
        self.assertEqual(self.story["title"], override["story"]["title"])
        self.assertEqual(self.story["arc_summary"], override["story"]["arc_summary"])
        self.assertEqual(self.story["arc_points"], override["story"].get("arc_points", []))
        spec_by_id = {e["id"]: e for e in override["episodes"]}
        self.assertEqual([e["id"] for e in self.story["episodes"]], list(spec_by_id))
        for ep in self.story["episodes"]:
            spec = spec_by_id[ep["id"]]
            for key in ("title", "summary", "problem_or_context", "what_changed", "result", "change_type", "confidence"):
                self.assertEqual(ep[key], spec[key], f"{ep['id']}.{key} differs from override; rerun build_story.py")
            self.assertEqual([c["id"] for c in ep["claims"]], [c["id"] for c in spec["claims"]])
            for out_claim, spec_claim in zip(ep["claims"], spec["claims"]):
                for key in ("text", "status", "confidence"):
                    self.assertEqual(out_claim[key], spec_claim[key], f"{out_claim['id']}.{key} differs from override")
        self.assertEqual(len(self.story["arc_points"]), len(self.story["episodes"]))
        # every analyzed commit must belong to an episode; a rebuild against a newer ref that
        # includes experiments/ commits would leave them uncovered and must fail here
        self.assertEqual(self.story["curation"]["uncovered_commit_count"], 0, self.story["curation"]["uncovered_commit_ids"])
        self.assertEqual(self.story["stats"]["commit_count"], sum(e["commit_count"] for e in self.story["episodes"]))

    def test_every_commit_hash_exists_and_episodes_are_chronological(self):
        prev_end = None
        for ep in self.story["episodes"]:
            for h in ep["commit_ids"]:
                self.assertIn(h, self.known)
            if prev_end is not None:
                self.assertLess(prev_end, ep["started_at"])
            prev_end = ep["ended_at"]
            self.assertLessEqual(ep["started_at"], ep["ended_at"])

    def test_every_claim_has_evidence_inside_its_episode(self):
        commits_doc = json.loads((ROOT / "public" / "commits.json").read_text(encoding="utf-8"))
        by_hash = {c["hash"]: c for c in commits_doc["commits"]}
        for ep in self.story["episodes"] + self.story["auto_episodes"]:
            self.assertTrue(ep["claims"])
            members = set(ep["commit_ids"])
            for claim in ep["claims"]:
                self.assertTrue(claim["evidence_commit_ids"], claim["id"])
                self.assertIn(claim["status"], bs.CLAIM_STATUSES)
                self.assertIn(claim["confidence"], bs.CONFIDENCES)
                for h in claim["evidence_commit_ids"]:
                    self.assertIn(h, members, f"{claim['id']} evidence {h[:7]} outside episode")
                if claim["status"] == "inferred":
                    self.assertTrue(claim["limitations"].strip(), claim["id"])
                # every evidence file must be changed (new or old path) by at least one evidence commit
                touched = set()
                for h in claim["evidence_commit_ids"]:
                    for f in by_hash[h]["files"]:
                        touched.add(f["path"])
                        if f["old_path"]:
                            touched.add(f["old_path"])
                for p in claim["evidence_files"]:
                    self.assertIn(p, touched, f"{claim['id']} file {p} not in evidence diffs")

    def test_no_private_paths_leak_into_outputs(self):
        """Outputs may quote private *path names* that appear in tracked docs/diffs, but must not
        contain private file *contents* or any path that is ignored/untracked at HEAD."""
        ignored_prefixes = ("runtime/", "course_files/", "course_transcripts/", "course_videos/", ".gstack/", ".omo/")
        ignored_names = {"config.env", "manual_assignment_overrides.json", "kaikey_state.json"}
        commits_doc = json.loads((ROOT / "public" / "commits.json").read_text(encoding="utf-8"))
        by_hash = {c["hash"]: c for c in commits_doc["commits"]}
        for c in commits_doc["commits"]:
            for f in c["files"]:
                self.assertFalse(f["path"].startswith(ignored_prefixes), f["path"])
                self.assertNotIn(f["path"], ignored_names)
        for commit_hash, per_file in self.story["evidence_excerpts"].items():
            self.assertIn(commit_hash, by_hash)
            changed = {f["path"] for f in by_hash[commit_hash]["files"]}
            for p in per_file:
                self.assertFalse(p.startswith(ignored_prefixes), p)
                self.assertNotIn(p, ignored_names)
                # excerpt path must be a path git reports as changed by that commit
                self.assertIn(p, changed, f"excerpt {commit_hash[:7]} {p} not in commit diff")
        text = self.story_path.read_text(encoding="utf-8") + (ROOT / "public" / "commits.json").read_text(encoding="utf-8")
        # markers are assembled at runtime so the test source itself never contains a secret-shaped literal
        markers = ["BEGIN " + "PRIVATE " + "KEY", "BEGIN OPENSSH " + "PRIVATE " + "KEY", "KLMS_" + "PASSWORD=", "RELAY_WORKER_" + "TOKEN=\""]
        for token in markers:
            self.assertNotIn(token, text)


if __name__ == "__main__":
    unittest.main()
