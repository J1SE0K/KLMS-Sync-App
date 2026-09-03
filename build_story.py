#!/usr/bin/env python3
"""Build Development Storytelling data (commits.json, story.json) from a Git repository.

Standard library only. Reads nothing except what `git` reports for the given ref:
no working-tree files, no untracked/ignored files, no runtime data.

Usage:
    python3 build_story.py --repo ../.. --ref HEAD \
        --commits-output public/commits.json --story-output public/story.json \
        [--override story.override.json] [--no-override]
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

RS = "\x1e"
US = "\x1f"

# MVP initial weights. Not research-validated; see README.
DEFAULT_WEIGHTS = {
    "path_overlap": 0.40,
    "message_tokens": 0.25,
    "subsystem": 0.15,
    "commit_type": 0.10,
    "temporal": 0.10,
}
DEFAULT_THRESHOLD = 0.35
LONG_GAP_HOURS = 24 * 7
TEMPORAL_FULL_HOURS = 1.0
TEMPORAL_ZERO_HOURS = 48.0
RECENT_WINDOW = 8
MIN_CLUSTER_SIZE = 2
PACKAGING_PATTERNS = ("package-lock.json", "Package.swift", ".pbxproj", "vendor/", "pnpm-lock.yaml", "yarn.lock", "Package.resolved")
PACKAGING_MIN_ADDITIONS = 1000
NEW_PLATFORM_PREFIXES = ("apps/", "deploy/", "integrations/", "vendor/")
HARD_BOUNDARY_KINDS = ("long_gap", "tag", "merge", "new_platform", "packaging_change")

CHANGE_TYPES = ("introduction", "extension", "migration", "repair", "refactor", "security", "test", "release")
CLAIM_STATUSES = ("observed", "supported", "inferred")
CONFIDENCES = ("high", "medium", "low")

CC_RE = re.compile(r"^(?P<type>[A-Za-z]+)(\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s+(?P<rest>.*)$")
REVERT_RE = re.compile(r'^Revert\s+"(?P<subject>.+)"\s*$')

STOPWORDS = set(
    """a an the and or of to in on for with from by at as is are be into via across
    app apps klms sync klmssync make keep show use add fix fixes fixed update improve
    refine polish align clarify stabilize reduce avoid remove restore prevent handle
    resolve tighten simplify harden cache defer optimize optimise before after when
    all only more less immediately immediate feel feels default defaults per not no
    this that these those its it""".split()
)

TYPE_ALIASES = {
    "feat": "feat", "feature": "feat", "fix": "fix", "bugfix": "fix", "hotfix": "fix",
    "perf": "perf", "style": "style", "ui": "style", "polish": "style", "refactor": "refactor",
    "chore": "chore", "docs": "docs", "doc": "docs", "test": "test", "tests": "test",
    "security": "security", "build": "build", "ci": "ci", "tools": "tools", "release": "release",
    "ios": "ios", "mac": "mac", "app": "app", "windows": "windows",
}
VERB_TYPES = [
    (re.compile(r"^(add|introduce|create|build|ship)\b", re.I), "feat"),
    (re.compile(r"^(fix|restore|prevent|avoid|handle|resolve|repair|correct|unblock|guard|fail closed|reject)\b", re.I), "fix"),
    (re.compile(r"^(harden|secure|redact|sanitize|pin)\b", re.I), "security"),
    (re.compile(r"^(refactor|organize|organise|simplify|remove|clean|split|unify|reorder|tidy|trim|separate)\b", re.I), "refactor"),
    (re.compile(r"^(migrate|move|rename|switch)\b", re.I), "migration"),
    (re.compile(r"^(test|verify|lock|cover|measure|prove)\b", re.I), "test"),
    (re.compile(r"^(document|describe|docs?)\b", re.I), "docs"),
    (re.compile(r"^(optimi[sz]e|speed up|reduce|cache|defer|debounce|prewarm|coalesce|batch|lighten|smooth)\b", re.I), "perf"),
]
TYPE_TO_CHANGE = {
    "feat": "introduction", "fix": "repair", "perf": "refactor", "style": "refactor", "refactor": "refactor",
    "chore": "refactor", "docs": None, "test": "test", "security": "security", "build": "release",
    "ci": "release", "tools": "test", "release": "release", "migration": "migration",
    "ios": None, "mac": None, "app": None, "windows": None, "other": None,
}
MAINTENANCE_GROUP = {"fix", "perf", "style", "refactor", "chore", "other", "ios", "mac", "app", "windows"}

SUBSYSTEM_RULES = [
    (re.compile(r"^apps/KLMSync/"), "apple-app"),
    (re.compile(r"^apps/KLMSyncWindows/"), "windows-app"),
    (re.compile(r"^apps/([^/]+)/"), "app:{0}"),
    (re.compile(r"^deploy/"), "relay"),
    (re.compile(r"^tools/.*relay"), "relay"),
    (re.compile(r"^tools/security/"), "security-tooling"),
    (re.compile(r"^tools/"), "tools"),
    (re.compile(r"^(src|bin|tests|legacy)/"), "sync-engine"),
    (re.compile(r"^[^/]+\.(py|js|mjs|swift|sh)$"), "sync-engine"),
    (re.compile(r"^docs/"), "docs"),
    (re.compile(r"^\.github/"), "ci"),
    (re.compile(r"^vendor/"), "vendor"),
    (re.compile(r"^integrations/"), "integrations"),
    (re.compile(r"^examples/"), "examples"),
]


class OverrideValidationError(Exception):
    pass


# --------------------------------------------------------------------------- git helpers

def run_git(repo: str, args: list[str]) -> str:
    cmd = ["git", "-C", repo, "-c", "core.quotepath=false", "-c", "core.pager=cat"] + args
    proc = subprocess.run(cmd, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:3])}... failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def parse_iso(ts: str) -> dt.datetime:
    return dt.datetime.fromisoformat(ts)


def top_level_scope(path: str) -> str:
    parts = path.split("/")
    if len(parts) == 1:
        return "(root)"
    if parts[0] in ("apps", "src", "deploy", "tools") and len(parts) > 2:
        return "/".join(parts[:2])
    return parts[0]


def dir2(path: str) -> str:
    parts = path.split("/")
    if len(parts) <= 2:
        return "/".join(parts[:-1]) or "(root)"
    if parts[0] == "apps" and len(parts) > 3:
        return "/".join(parts[:3])
    return "/".join(parts[:2])


def subsystem_for(path: str) -> str:
    for rx, name in SUBSYSTEM_RULES:
        m = rx.match(path)
        if m:
            return name.format(*m.groups()) if "{0}" in name else name
    return "other"


def tokenize(subject: str) -> list[str]:
    s = subject
    m = CC_RE.match(s)
    if m:
        s = m.group("rest")
    s = re.sub(r"[^A-Za-z0-9가-힣]+", " ", s.lower())
    out = []
    for tok in s.split():
        if len(tok) < 3 or tok in STOPWORDS or tok.isdigit():
            continue
        out.append(tok)
    return out


def classify_type(subject: str) -> tuple[str | None, str | None, str]:
    """Return (raw conventional type or None, scope or None, normalized type)."""
    m = CC_RE.match(subject)
    if m:
        raw = m.group("type").lower()
        norm = TYPE_ALIASES.get(raw, raw)
        return raw, (m.group("scope") or None), norm
    if REVERT_RE.match(subject):
        return None, None, "fix"
    for rx, norm in VERB_TYPES:
        if rx.match(subject.strip()):
            return None, None, norm
    return None, None, "other"


def parse_numstat_path(raw: str) -> tuple[str, str | None]:
    """Resolve `dir/{old => new}/file` and `old => new` numstat forms. Returns (new_path, old_path)."""
    if "=>" not in raw:
        return raw, None
    m = re.search(r"\{(.*?) => (.*?)\}", raw)
    if m:
        old = raw[: m.start()] + m.group(1) + raw[m.end():]
        new = raw[: m.start()] + m.group(2) + raw[m.end():]
        return new.replace("//", "/"), old.replace("//", "/")
    old, new = raw.split(" => ", 1)
    return new, old


def collect_commits(repo: str, ref: str) -> tuple[list[dict], dict]:
    head = run_git(repo, ["rev-parse", ref]).strip()
    try:
        branch = run_git(repo, ["rev-parse", "--abbrev-ref", ref]).strip()
    except RuntimeError:
        branch = ref
    try:
        remote = run_git(repo, ["config", "--get", "remote.origin.url"]).strip()
    except RuntimeError:
        remote = ""
    repo_slug = ""
    m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", remote)
    if m:
        repo_slug = m.group(1)

    first_parent = run_git(repo, ["rev-list", "--first-parent", "--reverse", head]).split()
    fp_index = {h: i for i, h in enumerate(first_parent)}

    tags: dict[str, list[str]] = defaultdict(list)
    ref_out = run_git(repo, ["for-each-ref", "--format=%(objectname) %(*objectname) %(refname:short)", "refs/tags"])
    for line in ref_out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 3:
            continue
        obj, peeled, name = parts
        tags[peeled or obj].append(name)

    fmt = RS + US.join(["%H", "%P", "%an", "%aI", "%cI", "%s", "%b"]) + US
    raw = run_git(repo, ["log", "--reverse", "--date-order", "--diff-merges=first-parent", "--numstat", "-M", f"--format={fmt}", head])
    status_raw = run_git(repo, ["log", "--reverse", "--date-order", "--diff-merges=first-parent", "--name-status", "-M", "--format=" + RS + "%H", head])

    status_map: dict[str, dict[str, tuple[str, str | None]]] = {}
    for rec in status_raw.split(RS):
        if not rec.strip():
            continue
        lines = rec.strip("\n").split("\n")
        h = lines[0].strip()
        entry: dict[str, tuple[str, str | None]] = {}
        for line in lines[1:]:
            if not line.strip():
                continue
            cols = line.split("\t")
            st = cols[0]
            if st[0] in ("R", "C") and len(cols) >= 3:
                entry[cols[2]] = (st, cols[1])
            elif len(cols) >= 2:
                entry[cols[1]] = (st, None)
        status_map[h] = entry

    commits: list[dict] = []
    seen_files: set[str] = set()
    for rec in raw.split(RS):
        if not rec.strip():
            continue
        fields = rec.split(US)
        if len(fields) < 8:
            print(f"warning: skipping malformed git log record: {rec[:80]!r}", file=sys.stderr)
            continue
        full, parents, author, a_iso, c_iso, subject, body, rest = fields[:8]
        parents_list = parents.split()
        files = []
        adds = dels = 0
        statuses = status_map.get(full, {})
        for line in rest.strip("\n").split("\n"):
            if not line.strip():
                continue
            cols = line.split("\t")
            if len(cols) < 3:
                continue
            a, d, p = cols[0], cols[1], "\t".join(cols[2:])
            new_path, old_path = parse_numstat_path(p)
            st, st_old = statuses.get(new_path, ("M", None))
            if st_old and not old_path:
                old_path = st_old
            binary = a == "-" or d == "-"
            ai = 0 if binary else int(a)
            di = 0 if binary else int(d)
            adds += ai
            dels += di
            files.append({
                "path": new_path,
                "old_path": old_path,
                "status": st,
                "additions": ai,
                "deletions": di,
                "binary": binary,
                "scope": top_level_scope(new_path),
                "subsystem": subsystem_for(new_path),
            })
        raw_type, cc_scope, norm_type = classify_type(subject)
        new_files = [f["path"] for f in files if f["status"].startswith("A")]
        new_top_dirs: list[str] = []
        for f in files:
            if f["status"].startswith("A") and f["path"] not in seen_files:
                for prefix in NEW_PLATFORM_PREFIXES:
                    if f["path"].startswith(prefix):
                        d = "/".join(f["path"].split("/")[:2])
                        if d not in new_top_dirs and not any(s.startswith(d + "/") for s in seen_files):
                            new_top_dirs.append(d)
        for f in files:
            seen_files.add(f["path"])
        scopes = Counter(f["scope"] for f in files)
        subsystems = Counter(f["subsystem"] for f in files)
        revert_m = REVERT_RE.match(subject)
        commits.append({
            "hash": full,
            "short_hash": full[:7],
            "parents": parents_list,
            "author": author,
            "authored_at": a_iso,
            "committed_at": c_iso,
            "subject": subject,
            "body": body.strip(),
            "is_merge": len(parents_list) > 1,
            "files": files,
            "additions": adds,
            "deletions": dels,
            "file_count": len(files),
            "rename_candidates": [{"from": f["old_path"], "to": f["path"]} for f in files if f["old_path"]],
            "scopes": [s for s, _ in scopes.most_common()],
            "subsystems": [s for s, _ in subsystems.most_common()],
            "primary_subsystem": subsystems.most_common(1)[0][0] if subsystems else "none",
            "cc_type": raw_type,
            "cc_scope": cc_scope,
            "normalized_type": norm_type,
            "tokens": tokenize(subject),
            "tags": sorted(tags.get(full, [])),
            "first_parent_order": fp_index.get(full),
            "sequence": len(commits),
            "new_files": new_files,
            "new_top_dirs": new_top_dirs,
            "reverts_subject": revert_m.group("subject") if revert_m else None,
            "is_packaging_change": any(any(pp in f["path"] for pp in PACKAGING_PATTERNS) for f in files) and adds >= PACKAGING_MIN_ADDITIONS,
            "merged_by": None,
        })

    by_hash = {c["hash"]: c for c in commits}
    for c in commits:
        if c["is_merge"] and len(c["parents"]) >= 2:
            side = run_git(repo, ["rev-list", c["parents"][1], "^" + c["parents"][0]]).split()
            for h in side:
                if h in by_hash and by_hash[h]["merged_by"] is None:
                    by_hash[h]["merged_by"] = c["hash"]
    subj_index: dict[str, list[str]] = defaultdict(list)
    for c in commits:
        subj_index[c["subject"]].append(c["hash"])
    for c in commits:
        c["reverts_commit"] = None
        if c["reverts_subject"]:
            cands = [h for h in subj_index.get(c["reverts_subject"], []) if by_hash[h]["sequence"] < c["sequence"]]
            if cands:
                c["reverts_commit"] = cands[-1]

    tree_paths = {p for p in run_git(repo, ["ls-tree", "-r", "--name-only", head]).split("\n") if p}
    source = {
        "repository": repo_slug or os.path.basename(os.path.abspath(repo)),
        "remote_url": remote,
        "ref": ref,
        "branch": branch,
        "head_commit": head,
        "head_short": head[:7],
        "first_parent_count": len(first_parent),
        "head_tracked_file_count": len(tree_paths),
    }
    meta = {"source": source, "tree_paths": tree_paths, "by_hash": by_hash}
    return commits, meta


# --------------------------------------------------------------------------- clustering

def overlap_coeff(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / min(len(a), len(b))


def hours_between(a: str, b: str) -> float:
    """Signed gap from a to b in hours, clamped at 0 so a rebased/cherry-picked commit
    authored earlier than its predecessor is treated as adjacent rather than distant."""
    return max(0.0, (parse_iso(b) - parse_iso(a)).total_seconds()) / 3600.0


def temporal_score(hours: float) -> float:
    if hours <= TEMPORAL_FULL_HOURS:
        return 1.0
    if hours >= TEMPORAL_ZERO_HOURS:
        return 0.0
    return 1.0 - (hours - TEMPORAL_FULL_HOURS) / (TEMPORAL_ZERO_HOURS - TEMPORAL_FULL_HOURS)


def similarity(commit: dict, cluster: list[dict], weights: dict) -> tuple[float, dict]:
    recent = cluster[-RECENT_WINDOW:]
    c_files = {f["path"] for f in commit["files"]}
    c_dirs = {dir2(f["path"]) for f in commit["files"]}
    r_files: set = set()
    r_dirs: set = set()
    r_tokens: set = set()
    r_subs: set = set()
    for r in recent:
        r_files |= {f["path"] for f in r["files"]}
        r_dirs |= {dir2(f["path"]) for f in r["files"]}
        r_tokens |= set(r["tokens"])
        r_subs |= set(r["subsystems"])
    path = max(overlap_coeff(c_files, r_files), 0.6 * overlap_coeff(c_dirs, r_dirs))
    msg = overlap_coeff(set(commit["tokens"]), r_tokens)
    last = recent[-1]
    if commit["primary_subsystem"] == last["primary_subsystem"]:
        sub = 1.0
    elif set(commit["subsystems"]) & r_subs:
        sub = 0.5
    else:
        sub = 0.0
    if commit["normalized_type"] == last["normalized_type"]:
        typ = 1.0
    elif commit["normalized_type"] in MAINTENANCE_GROUP and last["normalized_type"] in MAINTENANCE_GROUP:
        typ = 0.5
    else:
        typ = 0.0
    tmp = temporal_score(hours_between(last["authored_at"], commit["authored_at"]))
    parts = {"path_overlap": path, "message_tokens": msg, "subsystem": sub, "commit_type": typ, "temporal": tmp}
    score = sum(weights[k] * parts[k] for k in weights)
    return score, parts


def hard_boundary(prev: dict, commit: dict) -> str | None:
    if hours_between(prev["authored_at"], commit["authored_at"]) > LONG_GAP_HOURS:
        return "long_gap"
    if prev["tags"]:
        return "tag"
    if prev["is_merge"]:
        return "merge"
    if commit["new_top_dirs"]:
        return "new_platform:" + ",".join(commit["new_top_dirs"])
    if commit["is_packaging_change"]:
        return "packaging_change"
    return None


def _has_hard_boundary(reasons: list[str]) -> bool:
    return any(r.split(":")[0] in HARD_BOUNDARY_KINDS for r in reasons)


def cluster_commits(commits: list[dict], weights: dict, threshold: float, min_size: int) -> list[dict]:
    clusters: list[dict] = []
    current: list[dict] = []
    reasons: list[str] = []

    def close():
        nonlocal current, reasons
        if current:
            clusters.append({"commits": current, "boundary_reasons": reasons})
        current, reasons = [], []

    for c in commits:
        if not current:
            current.append(c)
            continue
        prev = current[-1]
        if c["merged_by"] and any(x["merged_by"] == c["merged_by"] for x in current):
            current.append(c)
            continue
        if c["is_merge"] and any(x["merged_by"] == c["hash"] for x in current):
            current.append(c)
            continue
        if c["reverts_commit"] and any(x["hash"] == c["reverts_commit"] for x in current):
            current.append(c)
            continue
        hb = hard_boundary(prev, c)
        if hb:
            close()
            reasons.append(hb)
            current.append(c)
            continue
        score, _ = similarity(c, current, weights)
        if score >= threshold:
            current.append(c)
        else:
            close()
            reasons.append(f"similarity_below_threshold:{score:.2f}")
            current.append(c)
    close()

    changed = True
    while changed and min_size > 1:
        changed = False
        for i, cl in enumerate(clusters):
            if len(cl["commits"]) >= min_size:
                continue
            options = []
            if i > 0 and not _has_hard_boundary(cl["boundary_reasons"]):
                s, _ = similarity(cl["commits"][0], clusters[i - 1]["commits"], weights)
                options.append((s, i - 1))
            if i + 1 < len(clusters) and not _has_hard_boundary(clusters[i + 1]["boundary_reasons"]):
                s, _ = similarity(clusters[i + 1]["commits"][0], cl["commits"], weights)
                options.append((s, i + 1))
            if not options:
                continue
            _, j = max(options)
            if j < i:
                clusters[j]["commits"].extend(cl["commits"])
                clusters[j]["boundary_reasons"] += ["merged_small_cluster"]
                del clusters[i]
            else:
                clusters[j]["commits"] = cl["commits"] + clusters[j]["commits"]
                clusters[j]["boundary_reasons"] = cl["boundary_reasons"] + ["merged_small_cluster"]
                del clusters[i]
            changed = True
            break
    return clusters


# --------------------------------------------------------------------------- episode text

def change_types_for(commits: list[dict]) -> tuple[list[str], dict]:
    kinds = Counter(c["normalized_type"] for c in commits)
    ct: Counter = Counter()
    for c in commits:
        t = TYPE_TO_CHANGE.get(c["normalized_type"])
        if c["normalized_type"] == "feat":
            t = "introduction" if c["new_files"] else "extension"
        if t:
            ct[t] += 1
    if not ct:
        ct["extension"] = 1
    ordered = [t for t, _ in ct.most_common(3)]
    return ordered, dict(kinds)


def fmt_date(iso: str) -> str:
    return iso[:10]


KIND_LABEL = {
    "feat": "도입·확장", "fix": "수정", "perf": "성능 최적화", "style": "UI 정리", "refactor": "구조 정리",
    "security": "보안 강화", "test": "검증", "docs": "문서", "build": "빌드", "ci": "CI", "tools": "도구",
    "ios": "iOS 조정", "mac": "Mac 조정", "app": "앱 조정", "windows": "Windows 조정", "other": "변경",
}


def build_auto_episode(idx: int, cluster: dict, meta: dict) -> dict:
    commits = cluster["commits"]
    start, end = commits[0], commits[-1]
    files_counter: Counter = Counter()
    scope_counter: Counter = Counter()
    adds = dels = 0
    new_files: list[tuple[str, str]] = []
    for c in commits:
        adds += c["additions"]
        dels += c["deletions"]
        for f in c["files"]:
            files_counter[f["path"]] += 1
            scope_counter[f["scope"]] += 1
            if f["status"].startswith("A"):
                new_files.append((f["path"], c["hash"]))
    tokens = Counter(t for c in commits for t in c["tokens"])
    top_tokens = [t for t, _ in tokens.most_common(4)]
    areas = [s for s, _ in scope_counter.most_common(4)]
    change_type, kinds = change_types_for(commits)
    fix_count = sum(1 for c in commits if c["normalized_type"] == "fix")
    top_files = files_counter.most_common(5)
    tree = meta["tree_paths"]
    surviving = [p for p, _ in top_files if p in tree]
    gone = [p for p, _ in top_files if p not in tree]

    dominant = Counter(c["normalized_type"] for c in commits).most_common(1)[0][0]
    label = KIND_LABEL.get(dominant, "변경")
    area_label = areas[0] if areas else "(변경 파일 없음)"
    title = f"{area_label} {label} 구간"
    if top_tokens:
        title += ": " + "·".join(top_tokens[:3])

    if fmt_date(start["authored_at"]) != fmt_date(end["authored_at"]):
        period = f"{fmt_date(start['authored_at'])}부터 {fmt_date(end['authored_at'])}까지"
    else:
        period = f"{fmt_date(start['authored_at'])} 하루 동안"
    summary = f"{period} {len(commits)}개 commit이 주로 {', '.join(areas[:3]) or '(경로 없음)'} 경로를 변경했다."
    if top_tokens:
        summary += f" commit subject에서 '{', '.join(top_tokens[:3])}' 단어가 반복된다."

    problem = "이 구간의 문제 상황은 commit 기록에서 직접 확인되지 않는다."
    if fix_count:
        problem += f" subject가 수정(fix) 계열로 분류된 commit이 {fix_count}건 있어, 앞선 변경의 결함을 바로잡는 구간이 포함된 것으로 추정된다."
    member_hashes = {c["hash"] for c in commits}
    # only reverts whose target sits in this same cluster can be cited as in-episode evidence
    reverts = [c for c in commits if c["reverts_commit"] in member_hashes]
    if reverts:
        problem += f" revert commit {len(reverts)}건이 같은 구간에 있다."

    what = f"{len(files_counter)}개 파일에서 +{adds}/-{dels} 줄이 바뀌었다."
    if top_files:
        what += " 가장 자주 변경된 파일: " + ", ".join(f"{p} ({n}회)" for p, n in top_files[:3]) + "."
    if new_files:
        what += f" 이 구간에서 새로 추가된 파일 {len(new_files)}개."

    result = ""
    if surviving:
        result += f"현재 HEAD({meta['source']['head_short']})에도 {', '.join(surviving[:3])} 경로가 남아 있다."
    if gone:
        result += f" {', '.join(gone[:3])} 경로는 이후 삭제되거나 이동되어 현재 HEAD에는 없다."
    if not result:
        result = "현재 코드에 남은 결과는 파일 경로 기준으로 확인할 수 없다."

    claims = []
    ep_id = f"episode-auto-{start['short_hash']}"
    if new_files:
        sample = new_files[:5]
        claims.append({
            "id": f"{ep_id}-claim-new-files",
            "text": f"이 구간에서 파일 {len(new_files)}개가 처음 추가됐다 (예: {', '.join(p for p, _ in sample[:3])}).",
            "status": "observed",
            "confidence": "high",
            "evidence_commit_ids": sorted({h for _, h in sample}),
            "evidence_files": [p for p, _ in sample],
            "limitations": "파일 추가 사실만 diff에서 확인된다. 추가 이유는 commit message 범위를 넘지 않는다.",
            "evidence_reason": "diff의 파일 status가 A(added)인 항목.",
        })
    if top_files and top_files[0][1] >= 2:
        p, n = top_files[0]
        ev = [c["hash"] for c in commits if any(f["path"] == p for f in c["files"])][:10]
        claims.append({
            "id": f"{ep_id}-claim-hot-file",
            "text": f"{p} 파일이 이 구간의 commit {n}개에서 반복 수정됐다.",
            "status": "observed",
            "confidence": "high",
            "evidence_commit_ids": ev,
            "evidence_files": [p],
            "limitations": "반복 수정 횟수는 numstat 기준이며, 각 수정의 목적은 subject만으로 판단했다.",
            "evidence_reason": "같은 경로가 여러 commit의 numstat에 등장.",
        })
    for tok in top_tokens:
        matching = [c for c in commits if tok in c["tokens"] and any(tok in f["path"].lower() for f in c["files"])]
        if matching:
            ev = [c["hash"] for c in matching][:8]
            files = sorted({f["path"] for c in matching[:8] for f in c["files"] if tok in f["path"].lower()})[:5]
            claims.append({
                "id": f"{ep_id}-claim-token-{tok}",
                "text": f"commit subject의 '{tok}' 언급({tokens[tok]}회)과 같은 이름을 가진 경로 변경이 함께 나타난다.",
                "status": "supported",
                "confidence": "medium",
                "evidence_commit_ids": ev,
                "evidence_files": files,
                "limitations": "subject 단어와 경로 이름의 일치는 자동 매칭 결과다.",
                "evidence_reason": "subject 토큰이 변경 파일 경로에도 포함됨.",
            })
            break
    if fix_count >= 2:
        fix_commits = [c for c in commits if c["normalized_type"] == "fix"]
        shared = Counter(f["path"] for c in fix_commits for f in c["files"])
        common = [p for p, n in shared.most_common(3) if n >= 2]
        if common:
            claims.append({
                "id": f"{ep_id}-claim-repeated-fix",
                "text": f"수정 계열 commit {fix_count}건이 {common[0]} 등 같은 파일을 다시 고친 점으로 보아, 한 문제를 여러 번에 걸쳐 바로잡은 구간으로 추정된다.",
                "status": "inferred",
                "confidence": "low",
                "evidence_commit_ids": [c["hash"] for c in fix_commits if any(f["path"] == common[0] for f in c["files"])][:8],
                "evidence_files": common[:1],
                "limitations": "동일 문제였는지는 commit 기록만으로 확인할 수 없다. issue나 PR 연결이 없다.",
                "evidence_reason": "fix 계열 subject를 가진 commit들이 같은 파일을 수정.",
            })
    for c in reverts:
        claims.append({
            "id": f"{ep_id}-claim-revert-{c['short_hash']}",
            "text": f"commit {c['short_hash']}은 이전 commit {c['reverts_commit'][:7]}(\"{c['reverts_subject']}\")를 되돌렸다.",
            "status": "observed",
            "confidence": "high",
            "evidence_commit_ids": [c["hash"], c["reverts_commit"]],
            "evidence_files": [f["path"] for f in c["files"]][:5],
            "limitations": "되돌린 이유는 commit message에 없다.",
            "evidence_reason": "subject가 Revert \"...\" 형식이고 같은 subject의 이전 commit이 존재.",
        })
    if not claims:
        claims.append({
            "id": f"{ep_id}-claim-range",
            "text": f"{start['short_hash']}부터 {end['short_hash']}까지 {len(commits)}개 commit이 연속으로 기록됐다.",
            "status": "observed",
            "confidence": "high",
            "evidence_commit_ids": [start["hash"], end["hash"]],
            "evidence_files": sorted({f["path"] for c in (start, end) for f in c["files"]})[:5],
            "limitations": "연속 기록 사실 외에 내용적 연관성은 추정이다.",
            "evidence_reason": "first-parent 순서에서 연속.",
        })

    if len(commits) >= 3 and (top_files and top_files[0][1] >= 2):
        confidence = "high"
    elif len(commits) >= 2:
        confidence = "medium"
    else:
        confidence = "low"

    # Auto claims go through the same validator as override claims so a claim can never
    # cite a commit outside its episode or a file its evidence commits did not change.
    member_ids = {c["hash"] for c in commits}
    by_hash = meta["by_hash"]
    claims = [validate_claim(c, ep_id, member_ids, by_hash) for c in claims]

    return {
        "id": ep_id,
        "order": idx + 1,
        "source": "auto",
        "title": title,
        "start_commit": start["hash"],
        "end_commit": end["hash"],
        "started_at": start["authored_at"],
        "ended_at": end["authored_at"],
        "change_type": change_type,
        "areas": areas,
        "commit_ids": [c["hash"] for c in commits],
        "commit_count": len(commits),
        "summary": summary,
        "problem_or_context": problem,
        "what_changed": what,
        "result": result,
        "confidence": confidence,
        "claims": claims,
        "unknowns": [
            "개발자의 의도, 논의 과정, 사용자 피드백은 Git 기록에 없다.",
            "PR이나 issue 연결이 없어 commit 묶음은 자동 clustering 결과다.",
        ],
        "stats": {"additions": adds, "deletions": dels, "files_changed": len(files_counter), "commit_kinds": kinds,
                  "top_files": [{"path": p, "commits": n} for p, n in top_files]},
        "boundary_reasons": cluster["boundary_reasons"],
    }


# --------------------------------------------------------------------------- override

def resolve_hash(ref_hash: str, by_hash: dict, where: str) -> str:
    if not isinstance(ref_hash, str) or not re.fullmatch(r"[0-9a-f]{4,40}", ref_hash):
        raise OverrideValidationError(f"{where}: invalid commit hash {ref_hash!r}")
    if ref_hash in by_hash:
        return ref_hash
    matches = [h for h in by_hash if h.startswith(ref_hash)]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise OverrideValidationError(f"{where}: commit {ref_hash} does not exist in the analyzed history")
    raise OverrideValidationError(f"{where}: commit prefix {ref_hash} is ambiguous")


def expand_range(from_h: str, to_h: str, commits: list[dict], by_hash: dict, where: str) -> list[dict]:
    a, b = by_hash[from_h], by_hash[to_h]
    if a["first_parent_order"] is None or b["first_parent_order"] is None:
        raise OverrideValidationError(f"{where}: commit_range endpoints must be first-parent commits")
    if a["first_parent_order"] > b["first_parent_order"]:
        raise OverrideValidationError(f"{where}: commit_range 'from' comes after 'to'")
    lo, hi = a["first_parent_order"], b["first_parent_order"]
    fp = [c for c in commits if c["first_parent_order"] is not None and lo <= c["first_parent_order"] <= hi]
    merges = {c["hash"] for c in fp if c["is_merge"]}
    side = [c for c in commits if c["merged_by"] in merges]
    return sorted(fp + side, key=lambda c: c["sequence"])


def validate_claim(claim: dict, where: str, allowed_commits: set[str], by_hash: dict) -> dict:
    for key in ("id", "text", "status", "confidence", "evidence_commit_ids"):
        if key not in claim:
            raise OverrideValidationError(f"{where}: claim missing '{key}'")
    if claim["status"] not in CLAIM_STATUSES:
        raise OverrideValidationError(f"{where}: claim {claim['id']} has invalid status {claim['status']!r}")
    if claim["confidence"] not in CONFIDENCES:
        raise OverrideValidationError(f"{where}: claim {claim['id']} has invalid confidence {claim['confidence']!r}")
    if not str(claim["text"]).strip():
        raise OverrideValidationError(f"{where}: claim {claim['id']} has empty text")
    ev = [resolve_hash(h, by_hash, f"{where} claim {claim['id']}") for h in claim["evidence_commit_ids"]]
    if not ev:
        raise OverrideValidationError(f"{where}: claim {claim['id']} has no evidence commits")
    for h in ev:
        if h not in allowed_commits:
            raise OverrideValidationError(f"{where}: claim {claim['id']} evidence commit {h[:7]} is not part of the episode")
    files = list(claim.get("evidence_files", []))
    touched = {f["path"] for h in ev for f in by_hash[h]["files"]} | {f["old_path"] for h in ev for f in by_hash[h]["files"] if f["old_path"]}
    for p in files:
        if p not in touched:
            raise OverrideValidationError(f"{where}: claim {claim['id']} evidence file {p!r} is not changed by its evidence commits")
    if claim["status"] == "observed" and not files:
        raise OverrideValidationError(f"{where}: observed claim {claim['id']} needs at least one evidence file")
    limitations = str(claim.get("limitations", "")).strip()
    if claim["status"] == "inferred" and not limitations:
        raise OverrideValidationError(f"{where}: inferred claim {claim['id']} must state its limitations")
    return {
        "id": claim["id"], "text": claim["text"], "status": claim["status"], "confidence": claim["confidence"],
        "evidence_commit_ids": ev, "evidence_files": files, "limitations": limitations,
        "evidence_reason": claim.get("evidence_reason", ""),
    }


def apply_override(override: dict, auto_episodes: list[dict], commits: list[dict], meta: dict) -> tuple[list[dict], dict]:
    by_hash = meta["by_hash"]
    if not isinstance(override, dict):
        raise OverrideValidationError("override root must be an object")
    if override.get("version") != 1:
        raise OverrideValidationError("override 'version' must be 1")
    auto_by_id = {e["id"]: e for e in auto_episodes}

    for ep_id, patch in (override.get("auto_patches") or {}).items():
        if ep_id not in auto_by_id:
            raise OverrideValidationError(f"auto_patches: unknown auto episode {ep_id}")
        ep = auto_by_id[ep_id]
        for key in ("title", "summary", "problem_or_context", "what_changed", "result"):
            if key in patch:
                ep[key] = patch[key]
        ep_commits = set(ep["commit_ids"])
        for claim_id, cpatch in (patch.get("claims") or {}).items():
            target = next((c for c in ep["claims"] if c["id"] == claim_id), None)
            if target is None:
                raise OverrideValidationError(f"auto_patches {ep_id}: unknown claim {claim_id}")
            merged = dict(target)
            for key in ("status", "confidence", "limitations", "text"):
                if key in cpatch:
                    merged[key] = cpatch[key]
            if "evidence_commit_ids_add" in cpatch:
                merged["evidence_commit_ids"] = list(merged["evidence_commit_ids"]) + list(cpatch["evidence_commit_ids_add"])
            if "evidence_files_add" in cpatch:
                merged["evidence_files"] = list(merged["evidence_files"]) + list(cpatch["evidence_files_add"])
            target.update(validate_claim(merged, f"auto_patches {ep_id}", ep_commits, by_hash))
        ep["source"] = "auto+patched"

    curated: list[dict] = []
    used: set[str] = set()
    for i, spec in enumerate(override.get("episodes") or []):
        where = f"episodes[{i}]"
        for key in ("id", "title"):
            if not spec.get(key):
                raise OverrideValidationError(f"{where}: missing '{key}'")
        members: list[dict] = []
        if "commit_range" in spec:
            rng = spec["commit_range"]
            fr = resolve_hash(rng.get("from", ""), by_hash, where + " commit_range.from")
            to = resolve_hash(rng.get("to", ""), by_hash, where + " commit_range.to")
            members = expand_range(fr, to, commits, by_hash, where)
        elif "auto_episode_ids" in spec:
            for aid in spec["auto_episode_ids"]:
                if aid not in auto_by_id:
                    raise OverrideValidationError(f"{where}: unknown auto episode {aid}")
                members += [by_hash[h] for h in auto_by_id[aid]["commit_ids"]]
        elif "commit_ids" in spec:
            members = [by_hash[resolve_hash(h, by_hash, where + " commit_ids")] for h in spec["commit_ids"]]
        else:
            raise OverrideValidationError(f"{where}: needs commit_range, auto_episode_ids or commit_ids")
        excluded = {resolve_hash(h, by_hash, where + " exclude_commit_ids") for h in spec.get("exclude_commit_ids", [])}
        members = [c for c in members if c["hash"] not in excluded]
        members = sorted({c["hash"]: c for c in members}.values(), key=lambda c: c["sequence"])
        if not members:
            raise OverrideValidationError(f"{where}: episode has no commits after exclusion")
        member_ids = {c["hash"] for c in members}
        dup = member_ids & used
        if dup:
            raise OverrideValidationError(f"{where}: commit {sorted(dup)[0][:7]} already belongs to another curated episode")
        used |= member_ids
        for key in ("summary", "problem_or_context", "what_changed", "result"):
            if not str(spec.get(key, "")).strip():
                raise OverrideValidationError(f"{where}: missing narrative field '{key}'")
        ct = spec.get("change_type") or []
        if not ct or any(t not in CHANGE_TYPES for t in ct):
            raise OverrideValidationError(f"{where}: change_type must be a non-empty subset of {CHANGE_TYPES}")
        if spec.get("confidence") not in CONFIDENCES:
            raise OverrideValidationError(f"{where}: confidence must be one of {CONFIDENCES}")
        claims_in = spec.get("claims") or []
        if not claims_in:
            raise OverrideValidationError(f"{where}: at least one claim with commit evidence is required")
        claims = [validate_claim(c, where, member_ids, by_hash) for c in claims_in]
        seen_claim_ids: set[str] = set()
        for c in claims:
            if c["id"] in seen_claim_ids:
                raise OverrideValidationError(f"{where}: duplicate claim id {c['id']}")
            seen_claim_ids.add(c["id"])
        scope_counter = Counter(f["scope"] for c in members for f in c["files"])
        files_counter = Counter(f["path"] for c in members for f in c["files"])
        adds = sum(c["additions"] for c in members)
        dels = sum(c["deletions"] for c in members)
        _, kinds = change_types_for(members)
        overlapping_auto = [e["id"] for e in auto_episodes if set(e["commit_ids"]) & member_ids]
        curated.append({
            "id": spec["id"],
            "order": 0,
            "source": "override",
            "title": spec["title"],
            "start_commit": members[0]["hash"],
            "end_commit": members[-1]["hash"],
            "started_at": members[0]["authored_at"],
            "ended_at": members[-1]["authored_at"],
            "change_type": ct,
            "areas": spec.get("areas") or [s for s, _ in scope_counter.most_common(4)],
            "commit_ids": [c["hash"] for c in members],
            "commit_count": len(members),
            "summary": spec["summary"],
            "problem_or_context": spec["problem_or_context"],
            "what_changed": spec["what_changed"],
            "result": spec["result"],
            "confidence": spec["confidence"],
            "claims": claims,
            "unknowns": spec.get("unknowns") or ["개발자의 의도와 논의 과정은 Git 기록에 없다."],
            "stats": {"additions": adds, "deletions": dels, "files_changed": len(files_counter), "commit_kinds": kinds,
                      "top_files": [{"path": p, "commits": n} for p, n in files_counter.most_common(5)]},
            "auto_origin": {"auto_episode_ids": overlapping_auto, "excluded_commit_ids": sorted(excluded)},
        })
    curated.sort(key=lambda e: by_hash[e["start_commit"]]["sequence"])
    for i, e in enumerate(curated):
        e["order"] = i + 1
        if i > 0 and by_hash[e["start_commit"]]["sequence"] <= by_hash[curated[i - 1]["end_commit"]]["sequence"]:
            raise OverrideValidationError(f"episode {e['id']} overlaps in time with {curated[i - 1]['id']}")
    ids = [e["id"] for e in curated]
    if len(ids) != len(set(ids)):
        raise OverrideValidationError("duplicate curated episode ids")
    story_patch = override.get("story") or {}
    return curated, {"story": story_patch, "auto_patched": sorted((override.get("auto_patches") or {}).keys())}


# --------------------------------------------------------------------------- evidence excerpts

DIFF_HEADER_PREFIXES = ("diff --git", "index ", "--- ", "+++ ", "similarity index", "rename from", "rename to",
                        "new file mode", "deleted file mode", "old mode", "new mode", "Binary files")


def diff_excerpt(repo: str, commit_hash: str, path: str, max_lines: int = 40) -> dict:
    try:
        out = run_git(repo, ["show", "--format=", "--no-color", "-M", "--diff-merges=first-parent", commit_hash, "--", path])
    except RuntimeError as exc:
        return {"lines": [], "truncated": False, "total_lines": 0, "error": str(exc)}
    body = [l for l in out.splitlines() if not l.startswith(DIFF_HEADER_PREFIXES)]
    return {"lines": [l[:200] for l in body[:max_lines]], "truncated": len(body) > max_lines, "total_lines": len(body)}


def collect_excerpts(repo: str, episodes: list[dict], by_hash: dict, per_claim: int = 1) -> dict:
    excerpts: dict[str, dict[str, dict]] = {}
    for ep in episodes:
        for claim in ep["claims"]:
            picks: list[tuple[str, str]] = []
            for h in claim["evidence_commit_ids"]:
                files = claim.get("evidence_files") or []
                touched = {f["path"] for f in by_hash[h]["files"]}
                old_to_new = {f["old_path"]: f["path"] for f in by_hash[h]["files"] if f["old_path"]}
                cand = [old_to_new.get(p, p) for p in files if p in touched or p in old_to_new]
                if not cand:
                    biggest = sorted(by_hash[h]["files"], key=lambda f: -(f["additions"] + f["deletions"]))
                    cand = [f["path"] for f in biggest[:1] if not f["binary"]]
                for p in cand[:per_claim]:
                    picks.append((h, p))
            for h, p in picks[:3]:
                if p in excerpts.get(h, {}):
                    continue
                excerpts.setdefault(h, {})[p] = diff_excerpt(repo, h, p)
    return excerpts


# --------------------------------------------------------------------------- main

def build(repo: str, ref: str, override_path: str | None, weights: dict, threshold: float, min_size: int) -> tuple[list[dict], dict]:
    commits, meta = collect_commits(repo, ref)
    clusters = cluster_commits(commits, weights, threshold, min_size)
    auto_episodes = [build_auto_episode(i, cl, meta) for i, cl in enumerate(clusters)]
    by_hash = meta["by_hash"]

    curated: list[dict] = []
    curation_info: dict = {"override_applied": False, "override_path": None}
    if override_path:
        with open(override_path, "r", encoding="utf-8") as fh:
            override = json.load(fh)
        curated, extra = apply_override(override, auto_episodes, commits, meta)
        curation_info = {"override_applied": True, "override_path": os.path.basename(override_path), **extra}

    episodes = curated if curated else copy.deepcopy(auto_episodes)
    covered = {h for e in episodes for h in e["commit_ids"]}
    uncovered = [c["hash"] for c in commits if c["hash"] not in covered]
    excerpts = collect_excerpts(repo, episodes, by_hash)

    first, last = commits[0], commits[-1]
    kinds = Counter(c["normalized_type"] for c in commits)
    story_patch = curation_info.get("story") or {}
    story_title = story_patch.get("title") or f"{meta['source']['repository']} 개발 이야기"
    arc = story_patch.get("arc_summary") or (
        f"{fmt_date(first['authored_at'])}부터 {fmt_date(last['authored_at'])}까지 {len(commits)}개 commit이 기록됐다. "
        f"자동 clustering은 이를 {len(auto_episodes)}개 구간으로 나눴다."
    )
    inferred = sum(1 for e in episodes for c in e["claims"] if c["status"] == "inferred")
    story = {
        "generator": "experiments/neukbao-storytelling/build_story.py",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "source": meta["source"],
        "title": story_title,
        "arc_summary": arc,
        "arc_points": story_patch.get("arc_points") or [],
        "stats": {
            "commit_count": len(commits),
            "first_parent_count": meta["source"]["first_parent_count"],
            "merge_count": sum(1 for c in commits if c["is_merge"]),
            "author_count": len({c["author"] for c in commits}),
            "first_commit_at": first["authored_at"],
            "last_commit_at": last["authored_at"],
            "commit_kinds": dict(kinds),
            "tag_count": sum(len(c["tags"]) for c in commits),
            "total_additions": sum(c["additions"] for c in commits),
            "total_deletions": sum(c["deletions"] for c in commits),
        },
        "clustering": {
            "method": "deterministic chronological clustering (adjacent commits only)",
            "weights": weights,
            "threshold": threshold,
            "min_cluster_size": min_size,
            "long_gap_hours": LONG_GAP_HOURS,
            "note": "Weights and threshold are MVP initial values, not research-validated.",
        },
        "curation": {
            **{k: v for k, v in curation_info.items() if k != "story"},
            "auto_episode_count": len(auto_episodes),
            "curated_episode_count": len(curated),
            "final_episode_count": len(episodes),
            "uncovered_commit_count": len(uncovered),
            "uncovered_commit_ids": uncovered,
            "inferred_claim_count": inferred,
        },
        "episodes": episodes,
        "auto_episodes": auto_episodes,
        "evidence_excerpts": excerpts,
    }
    return commits, story


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--commits-output", default="public/commits.json")
    ap.add_argument("--story-output", default="public/story.json")
    ap.add_argument("--override", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "story.override.json"))
    ap.add_argument("--no-override", action="store_true", help="ignore story.override.json even if it exists")
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--min-cluster-size", type=int, default=MIN_CLUSTER_SIZE)
    args = ap.parse_args(argv)

    override_path = None if args.no_override else (args.override if os.path.exists(args.override) else None)
    try:
        commits, story = build(args.repo, args.ref, override_path, dict(DEFAULT_WEIGHTS), args.threshold, args.min_cluster_size)
    except OverrideValidationError as exc:
        print(f"override validation error: {exc}", file=sys.stderr)
        return 2

    commits_doc = {
        "generator": story["generator"],
        "generated_at": story["generated_at"],
        "source": story["source"],
        "commit_count": len(commits),
        "commits": [{k: v for k, v in c.items() if k != "tokens"} for c in commits],
    }
    for out_path, doc in ((args.commits_output, commits_doc), (args.story_output, story)):
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
    print(f"source HEAD: {story['source']['head_commit']} ({story['source']['branch']})")
    print(f"commits analyzed: {len(commits)}  auto episodes: {story['curation']['auto_episode_count']}  "
          f"final episodes: {story['curation']['final_episode_count']}  override: {story['curation']['override_applied']}")
    print(f"inferred claims: {story['curation']['inferred_claim_count']}  uncovered commits: {story['curation']['uncovered_commit_count']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
