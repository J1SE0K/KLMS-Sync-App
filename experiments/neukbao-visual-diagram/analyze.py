#!/usr/bin/env python3
"""Neukbao Visual Diagram analyzer.

Reads only git-tracked files of a repository and emits ``graph.json`` with
system / component / directory / file nodes and evidence-backed edges.

Usage:
    python3 analyze.py --repo ../.. --output public/graph.json

Only the Python standard library is used. No network, no API keys.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
DEFAULT_COMPONENT_MAP = HERE / "component-map.json"

EDGE_TYPES = ("contains", "invokes", "imports", "packages", "tests", "communicates")
CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}

# Files we never open even if someone tracked them by mistake.
PRIVATE_BASENAME_PATTERNS = (
    "config.env",
    ".env",
    ".env.*",
    "*.cookies",
    "cookies*.txt",
    "session*.json",
    "kaikey*",
    "qr-screenshot*",
    "kaikey_qr*",
    "manual_assignment_overrides.json",
)
PRIVATE_DIR_PREFIXES = ("runtime/", "course_files/", "course_transcripts/", "course_videos/")

BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".icns", ".ico", ".pdf", ".zip",
    ".gz", ".tar", ".dylib", ".so", ".a", ".o", ".ttf", ".otf", ".woff", ".woff2",
}
MAX_TEXT_BYTES = 4 * 1024 * 1024

# Extensions whose content is scanned for relationships.
CODE_EXTENSIONS = {
    ".sh", ".py", ".js", ".mjs", ".cjs", ".swift", ".toml", ".yml", ".yaml", ".json",
    ".txt", ".html",
}
CODE_BASENAMES = {"Dockerfile", "Caddyfile", "Caddyfile.tunnel"}

LANGUAGE_BY_EXTENSION = {
    ".sh": "Shell",
    ".py": "Python",
    ".js": "JavaScript",
    ".mjs": "JavaScript",
    ".cjs": "JavaScript",
    ".swift": "Swift",
    ".html": "HTML",
    ".css": "CSS",
    ".json": "JSON",
    ".toml": "TOML",
    ".yml": "YAML",
    ".yaml": "YAML",
    ".md": "Markdown",
    ".sql": "SQL",
    ".txt": "Text",
    ".svg": "SVG",
    ".png": "Image",
    ".jpg": "Image",
    ".jpeg": "Image",
    ".icns": "Image",
    ".ico": "Image",
    ".plist": "Config",
    ".xcconfig": "Config",
    ".entitlements": "Config",
    ".example": "Config",
    ".pbxproj": "Xcode",
    ".xcscheme": "Xcode",
    ".lock": "Lockfile",
    ".gitkeep": "Text",
    ".dockerignore": "Config",
    ".gitignore": "Config",
    ".gitattributes": "Config",
    ".gitleaksignore": "Config",
}
LANGUAGE_BY_BASENAME = {
    "Dockerfile": "Dockerfile",
    "Caddyfile": "Caddyfile",
    "Caddyfile.tunnel": "Caddyfile",
    "LICENSE": "Text",
    "package-lock.json": "Lockfile",
}

REPO_TOP_DIRS = ("bin", "src", "tools", "deploy", "apps", "tests", "docs", "examples", "integrations", "vendor")
REPO_PATH_RE = re.compile(
    r"(?<![\w./-])((?:%s)/[\w][\w./-]*\.[A-Za-z0-9]+)" % "|".join(REPO_TOP_DIRS)
)
VAR_PATH_RE = re.compile(
    r"\$\{?(SCRIPT_DIR|ROOT_DIR|REPO_ROOT|PROJECT_ROOT|PROJECT_DIR)\}?/([\w][\w./-]*\.[A-Za-z0-9]+)"
)
KLMS_DIR_RE = re.compile(r"\$\{?KLMS_(JS|PYTHON|SWIFT|SH)_DIR\}?/([\w][\w./-]*\.[A-Za-z0-9]+)")
KLMS_DIR_TO_PATH = {"JS": "src/js", "PYTHON": "src/python", "SWIFT": "src/swift", "SH": "src/sh"}
DOT_SLASH_RE = re.compile(r"(?<![\w/])\./([\w][\w./-]*\.[A-Za-z0-9]+)")
BASENAME_RE = re.compile(r"(?<![\w./-])([A-Za-z_][\w-]*\.(?:sh|py|js|mjs|cjs|swift))(?![\w./-])")
PY_MODULE_RE = re.compile(r"python3?\s+-m\s+([\w.]+)")
ROUTE_RE = re.compile(r"[\"'`](/(?:v1|healthz|relay)(?:/[\w:.-]+)*)[\"'`]")

PY_IMPORT_RE = re.compile(r"^\s*(?:from\s+([\w.]+)\s+import\b|import\s+([\w.]+))", re.M)
JS_REQUIRE_RE = re.compile(r"require\(\s*[\"']([^\"']+)[\"']\s*\)")
JS_SIDE_EFFECT_IMPORT_RE = re.compile(r"^[ \t]*import\s+[\"']([^\"']+)[\"']", re.M)
# `import … from "x"` / `export … from "x"`: statement starts at line start and may span lines,
# but must not cross another statement-start keyword or a semicolon.
JS_FROM_IMPORT_RE = re.compile(
    r"^[ \t]*(?:import|export)\b(?!\s*[\"'])"
    r"(?:(?!^[ \t]*(?:import|export|const|let|var|function|class)\b)[^;])*?"
    r"\bfrom\s+[\"']([^\"']+)[\"']",
    re.M,
)
SWIFT_IMPORT_RE = re.compile(r"^\s*(@testable\s+)?import\s+([A-Za-z_]\w*)", re.M)
SWIFT_TARGET_RE = re.compile(
    r"\.(target|executableTarget|testTarget)\(\s*name:\s*\"([^\"]+)\"((?:(?!\.(?:target|executableTarget|testTarget)\().)*?)\)\s*,?\s*(?=\.(?:target|executableTarget|testTarget)\(|\])",
    re.S,
)
SWIFT_DEPS_RE = re.compile(r"dependencies:\s*\[([^\]]*)\]")
SHEBANG_RE = re.compile(r"^#!.*")
SHELL_ASSIGN_RE = re.compile(
    r'^\s*([A-Z_][A-Z0-9_]*)="?\$\{?(?:SCRIPT_DIR|ROOT_DIR|REPO_ROOT|PROJECT_ROOT|PROJECT_DIR)\}?/([\w][\w./-]*\.[A-Za-z0-9]+)"?\s*$',
    re.M,
)
SHELL_EXEC_RE = re.compile(r"(^|\s)(exec|/bin/zsh|zsh|bash|sh|/usr/bin/osascript|osascript|python3?|swift|node|swiftc)\s")
SHELL_SOURCE_VAR_RE = re.compile(r'(?:^|\s)(?:source|\.)\s+"?\$\{?([A-Z_][A-Z0-9_]*)\}?"?', re.M)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def run_git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-c", "core.quotepath=false", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.stdout


def posix(path: str) -> str:
    return path.replace("\\", "/")


def is_private_path(path: str) -> bool:
    base = PurePosixPath(path).name
    if any(path.startswith(prefix) for prefix in PRIVATE_DIR_PREFIXES):
        return True
    if base.endswith(".example"):
        return False
    return any(fnmatch.fnmatch(base, pattern) for pattern in PRIVATE_BASENAME_PATTERNS)


def language_for(path: str, head: str = "") -> Optional[str]:
    name = PurePosixPath(path).name
    if name in LANGUAGE_BY_BASENAME:
        return LANGUAGE_BY_BASENAME[name]
    suffix = PurePosixPath(path).suffix.lower()
    if name.startswith(".") and suffix == "" and ("." + name.lstrip(".")) in LANGUAGE_BY_EXTENSION:
        return LANGUAGE_BY_EXTENSION["." + name.lstrip(".")]
    if suffix in (".js",) and "osascript" in head.splitlines()[0] if head else False:
        return "JavaScript (JXA)"
    if suffix in (".js", ".mjs", ".cjs") and head.startswith("#!/usr/bin/env node"):
        return "JavaScript (Node)"
    if suffix == ".sh" and head.startswith("#!/bin/zsh"):
        return "Shell (zsh)"
    return LANGUAGE_BY_EXTENSION.get(suffix, "Text" if suffix == "" else "Other")


def match_pattern(path: str, pattern: str) -> bool:
    """Glob where '*' does not cross '/' and '**' matches any depth."""
    if pattern == "**":
        return True
    regex = ""
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "*":
            if pattern[i : i + 2] == "**":
                regex += ".*"
                i += 2
                if i < len(pattern) and pattern[i] == "/":
                    regex = regex[:-2] + "(?:.*/)?"
                    i += 1
                continue
            regex += "[^/]*"
        elif ch == "?":
            regex += "[^/]"
        else:
            regex += re.escape(ch)
        i += 1
    return re.fullmatch(regex, path) is not None


EXECUTABLE_SUFFIXES = {".sh", ".py", ".js", ".mjs", ".cjs", ".swift"}


def is_executable_path(path: str) -> bool:
    return PurePosixPath(path).suffix.lower() in EXECUTABLE_SUFFIXES


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.:/-]+", "_", text)


def first_comment_line(text: str, suffix: str) -> Optional[str]:
    lines = text.splitlines()
    for raw in lines[:12]:
        line = raw.strip()
        if not line or SHEBANG_RE.match(line):
            continue
        if line.startswith("//"):
            body = line.lstrip("/").strip()
        elif line.startswith("#") and suffix in (".sh", ".py", ".toml", ".yml", ".yaml"):
            body = line.lstrip("#").strip()
        elif line.startswith('"""') or line.startswith("'''"):
            body = line.strip("\"'").strip()
        elif line.startswith("/*") or line.startswith("*"):
            body = line.lstrip("/*").strip()
        else:
            return None
        if body and not body.startswith("!") and len(body) > 3:
            return body[:140]
    return None


# ---------------------------------------------------------------------------
# analyzer
# ---------------------------------------------------------------------------

class Analyzer:
    def __init__(self, repo: Path, component_map: dict, max_commits: Optional[int] = None):
        self.repo = repo
        self.component_map = component_map
        self.max_commits = max_commits
        self.tracked: List[str] = []
        self.tracked_set: set = set()
        self.texts: Dict[str, str] = {}
        self.file_component: Dict[str, str] = {}
        self.file_rule: Dict[str, str] = {}
        self.nodes: Dict[str, dict] = {}
        self.edges: Dict[str, dict] = {}
        self.commit_count: Counter = Counter()
        self.last_changed: Dict[str, int] = {}
        self.basename_index: Dict[str, List[str]] = defaultdict(list)
        self.swift_targets: Dict[str, dict] = {}
        self.route_index: Dict[str, set] = defaultdict(set)
        self.server_files: set = set()

    # -- collection --------------------------------------------------------
    def collect_tracked(self) -> None:
        out = run_git(self.repo, "ls-files", "-z")
        files = [posix(p) for p in out.split("\0") if p]
        self.tracked = sorted(p for p in files if not is_private_path(p))
        skipped = len(files) - len(self.tracked)
        if skipped:
            print(f"warning: skipped {skipped} tracked path(s) matching private patterns", file=sys.stderr)
        self.tracked_set = set(self.tracked)
        for path in self.tracked:
            self.basename_index[PurePosixPath(path).name].append(path)

    def read_texts(self) -> None:
        for path in self.tracked:
            p = PurePosixPath(path)
            if p.suffix.lower() in BINARY_EXTENSIONS:
                continue
            if p.suffix.lower() not in CODE_EXTENSIONS and p.name not in CODE_BASENAMES:
                continue
            full = self.repo / path
            try:
                if full.stat().st_size > MAX_TEXT_BYTES:
                    continue
                self.texts[path] = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue

    def collect_git_history(self) -> None:
        args = ["log", "--format=%x01%H\t%ct", "--name-only"]
        if self.max_commits:
            args.append(f"-n{self.max_commits}")
        args.append("--")
        args.append(".")
        out = run_git(self.repo, *args)
        current_ts: Optional[int] = None
        for line in out.splitlines():
            if line.startswith("\x01"):
                _, ts = line[1:].split("\t")
                current_ts = int(ts)
                continue
            line = line.strip()
            if not line or current_ts is None:
                continue
            path = posix(line)
            if path not in self.tracked_set:
                continue
            self.commit_count[path] += 1
            if path not in self.last_changed or current_ts > self.last_changed[path]:
                self.last_changed[path] = current_ts

    # -- classification ----------------------------------------------------
    def classify(self) -> None:
        comps = self.component_map["components"]
        for path in self.tracked:
            for comp in comps:
                for pattern in comp["patterns"]:
                    if match_pattern(path, pattern):
                        self.file_component[path] = comp["id"]
                        self.file_rule[path] = pattern
                        break
                if path in self.file_component:
                    break

    # -- nodes -------------------------------------------------------------
    def build_nodes(self) -> None:
        system = self.component_map["system"]
        self.nodes["system"] = {
            "id": "system",
            "label": system["label"],
            "kind": "system",
            "parent_id": None,
            "path": None,
            "language": None,
            "description": system["description"],
            "commit_count": 0,
            "last_changed_at": None,
            "evidence": [{"path": ".", "reason": "git ls-files 기준 tracked 파일 전체를 하나의 시스템으로 본다."}],
        }
        by_component: Dict[str, List[str]] = defaultdict(list)
        for path, comp_id in self.file_component.items():
            by_component[comp_id].append(path)

        for comp in self.component_map["components"]:
            files = sorted(by_component.get(comp["id"], []))
            if not files:
                continue
            comp_node_id = f"component:{comp['id']}"
            rule_hits = Counter(self.file_rule[p] for p in files)
            self.nodes[comp_node_id] = {
                "id": comp_node_id,
                "label": comp["label"],
                "kind": "component",
                "parent_id": "system",
                "path": None,
                "language": None,
                "description": comp["role"],
                "commit_count": 0,
                "last_changed_at": None,
                "evidence": [
                    {"path": pattern, "reason": f"component-map.json 규칙 '{pattern}'에 tracked 파일 {count}개가 매칭"}
                    for pattern, count in sorted(rule_hits.items(), key=lambda kv: -kv[1])
                ],
                "component_id": comp["id"],
                "layout": comp.get("layout", {}),
                "file_count": len(files),
                "languages": {},
            }
            self.add_edge("contains", "system", comp_node_id, "high", [
                {"path": ".", "reason": f"component-map.json이 {len(files)}개 파일을 '{comp['label']}'로 분류"}
            ])
            for path in files:
                self.add_file_and_dirs(comp["id"], comp_node_id, path)

        self.aggregate_stats()

    def add_file_and_dirs(self, comp_id: str, comp_node_id: str, path: str) -> None:
        parts = path.split("/")
        parent = comp_node_id
        for depth in range(1, len(parts)):
            dir_path = "/".join(parts[:depth])
            dir_id = f"dir:{comp_id}:{dir_path}"
            if dir_id not in self.nodes:
                self.nodes[dir_id] = {
                    "id": dir_id,
                    "label": parts[depth - 1] + "/",
                    "kind": "directory",
                    "parent_id": parent,
                    "path": dir_path,
                    "language": None,
                    "description": "",
                    "commit_count": 0,
                    "last_changed_at": None,
                    "evidence": [],
                    "component_id": comp_id,
                    "file_count": 0,
                    "languages": {},
                }
                self.add_edge("contains", parent, dir_id, "high", [
                    {"path": dir_path, "reason": "tracked 파일 경로의 상위 디렉터리"}
                ])
            parent = dir_id
        text = self.texts.get(path, "")
        head = text[:200]
        lang = language_for(path, head)
        suffix = PurePosixPath(path).suffix.lower()
        comment = first_comment_line(text, suffix) if text else None
        ts = self.last_changed.get(path)
        file_id = f"file:{path}"
        description = comment or f"{lang} 파일"
        self.nodes[file_id] = {
            "id": file_id,
            "label": parts[-1],
            "kind": "file",
            "parent_id": parent,
            "path": path,
            "language": lang,
            "description": description,
            "commit_count": self.commit_count.get(path, 0),
            "last_changed_at": datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else None,
            "evidence": [
                {"path": path, "reason": "git ls-files에 tracked"},
                {"path": path, "reason": f"component-map.json 규칙 '{self.file_rule[path]}'로 '{comp_id}'에 분류"},
            ],
            "component_id": comp_id,
            "size_bytes": (self.repo / path).stat().st_size if (self.repo / path).exists() else None,
        }
        self.add_edge("contains", parent, file_id, "high", [
            {"path": path, "reason": "디렉터리가 이 tracked 파일을 포함"}
        ])

    def aggregate_stats(self) -> None:
        # Walk files -> ancestors, accumulate commit counts (distinct commits are not
        # tracked per path here; we sum file touches, documented in README).
        children: Dict[str, List[str]] = defaultdict(list)
        for node in self.nodes.values():
            if node["parent_id"]:
                children[node["parent_id"]].append(node["id"])

        def visit(node_id: str) -> Tuple[int, Optional[str], Counter, int]:
            node = self.nodes[node_id]
            if node["kind"] == "file":
                lang = Counter({node["language"]: 1}) if node["language"] else Counter()
                return node["commit_count"], node["last_changed_at"], lang, 1
            total = 0
            latest: Optional[str] = None
            langs: Counter = Counter()
            files = 0
            for child in children.get(node_id, []):
                c, l, lg, f = visit(child)
                total += c
                langs.update(lg)
                files += f
                if l and (latest is None or l > latest):
                    latest = l
            node["commit_count"] = total
            node["last_changed_at"] = latest
            node["languages"] = dict(sorted(langs.items(), key=lambda kv: -kv[1]))
            node["file_count"] = files
            if node["kind"] == "directory":
                lang_summary = ", ".join(f"{k} {v}" for k, v in list(node["languages"].items())[:3])
                node["description"] = f"{node['path']}/ 아래 tracked 파일 {files}개 ({lang_summary})"
                node["evidence"] = [{"path": node["path"], "reason": f"tracked 파일 {files}개의 상위 디렉터리"}]
            return total, latest, langs, files

        visit("system")

    # -- edges -------------------------------------------------------------
    def add_edge(self, etype: str, source: str, target: str, confidence: str, evidence: List[dict]) -> Optional[str]:
        if etype not in EDGE_TYPES:
            raise ValueError(etype)
        if source == target or source not in self.nodes or target not in self.nodes:
            return None
        edge_id = f"{etype}:{source}->{target}"
        existing = self.edges.get(edge_id)
        if existing:
            if CONFIDENCE_RANK[confidence] > CONFIDENCE_RANK[existing["confidence"]]:
                existing["confidence"] = confidence
            seen = {(e["path"], e["reason"]) for e in existing["evidence"]}
            for ev in evidence:
                if (ev["path"], ev["reason"]) not in seen:
                    existing["evidence"].append(ev)
                    seen.add((ev["path"], ev["reason"]))
            return edge_id
        self.edges[edge_id] = {
            "id": edge_id,
            "source": source,
            "target": target,
            "type": etype,
            "confidence": confidence,
            "evidence": list(evidence),
            "level": "file" if source.startswith("file:") or target.startswith("file:") else "structure",
        }
        return edge_id

    def is_test_file(self, path: str) -> bool:
        comp = self.file_component.get(path)
        if comp == "tests-verification":
            return True
        name = PurePosixPath(path).name
        return name.startswith("test_") or name.endswith(("Tests.swift", ".test.cjs", ".test.mjs", ".spec.js"))

    def relation_type_for(self, source: str, default: str) -> str:
        if self.is_test_file(source) and default in ("invokes", "imports", "packages"):
            return "tests"
        return default

    def file_edge(self, source: str, target: str, default_type: str, confidence: str, reason: str) -> None:
        if target not in self.tracked_set or source == target:
            return
        etype = default_type
        if etype == "invokes" and not is_executable_path(target):
            # A non-executable target (html/json/md/...) is loaded or referenced, never executed.
            # Keep it as packages even for test sources: a test reading a fixture does not "test" it.
            etype = "packages"
            reason = reason + " (실행 파일이 아니라 로드/참조)"
        else:
            etype = self.relation_type_for(source, etype)
        self.add_edge(etype, f"file:{source}", f"file:{target}", confidence, [{"path": source, "reason": reason}])

    def resolve_relative(self, source: str, ref: str, extra_bases: Iterable[str] = ()) -> Optional[str]:
        candidates: List[str] = []
        src_dir = PurePosixPath(source).parent
        bases = [str(src_dir) if str(src_dir) != "." else "", ""] + list(extra_bases)
        for base in bases:
            joined = os.path.normpath(os.path.join(base, ref)).replace("\\", "/")
            if joined.startswith("../") or joined == "..":
                continue
            candidates.append(joined)
            for ext in (".js", ".mjs", ".cjs", ".py"):
                candidates.append(joined + ext)
            candidates.append(joined + "/index.js")
            candidates.append(joined + "/__init__.py")
        for cand in candidates:
            if cand in self.tracked_set:
                return cand
        return None

    def extract_edges(self) -> None:
        self.parse_swift_package()
        for path, text in self.texts.items():
            suffix = PurePosixPath(path).suffix.lower()
            name = PurePosixPath(path).name
            if name in ("EnginePayloadAllowlist.txt", "EnginePythonPayloadAllowlist.txt"):
                self.parse_allowlist(path, text)
                continue
            if suffix == ".txt":
                continue
            if name == "Dockerfile":
                self.parse_generic_paths(path, text, "packages", "Dockerfile COPY/CMD가 참조하는 tracked 파일")
                continue
            if suffix == ".json":
                if name == "package.json":
                    self.parse_package_json(path, text)
                continue
            if suffix == ".toml":
                self.parse_wrangler(path, text)
                continue
            if suffix in (".yml", ".yaml"):
                self.parse_generic_paths(path, text, "invokes", "GitHub Actions workflow가 실행/참조하는 tracked 파일", confidence="medium")
                continue
            if suffix == ".html":
                self.parse_html(path, text)
                continue
            if suffix == ".sh":
                self.parse_shell(path, text)
            elif suffix == ".py":
                self.parse_python(path, text)
            elif suffix in (".js", ".mjs", ".cjs"):
                self.parse_javascript(path, text)
            elif suffix == ".swift":
                self.parse_swift(path, text)
            self.collect_routes(path, text)
        self.link_routes()
        self.link_tests_by_name()

    # generic string path references ------------------------------------------------
    def parse_generic_paths(self, path: str, text: str, default_type: str, reason: str, confidence: str = "high") -> None:
        for match in REPO_PATH_RE.finditer(text):
            ref = match.group(1)
            if ref not in self.tracked_set:
                continue
            if default_type == "invokes" and not is_executable_path(ref):
                self.file_edge(path, ref, "invokes", "low", f"{reason}: '{ref}'")
                continue
            self.file_edge(path, ref, default_type, confidence, f"{reason}: '{ref}'")

    def parse_shell(self, path: str, text: str) -> None:
        is_root_wrapper = "/" not in path
        # VAR="$SCRIPT_DIR/x.sh" ... source "$VAR"  -> imports x.sh (high)
        assigned: Dict[str, str] = {}
        for m in SHELL_ASSIGN_RE.finditer(text):
            assigned[m.group(1)] = m.group(2)
        sourced_vars = set(SHELL_SOURCE_VAR_RE.findall(text))
        sourced_refs = set()
        for var_name in sourced_vars & set(assigned):
            ref = assigned[var_name]
            if ref in self.tracked_set:
                sourced_refs.add(ref)
                self.file_edge(path, ref, "imports", "high", f"`{var_name}=\"$SCRIPT_DIR/{ref}\"` 뒤에 `source \"${var_name}\"`")
        # entry_path 인자로 자기 root wrapper 경로를 넘기는 klms_init_context 호출은 실행이 아니다
        context_refs = set(re.findall(r'klms_init_context\s+"\$SCRIPT_DIR/([\w./-]+\.sh)"', text))
        for match in VAR_PATH_RE.finditer(text):
            var, ref = match.groups()
            if ref in sourced_refs or ref in context_refs:
                continue
            line = text[text.rfind("\n", 0, match.start()) + 1 : text.find("\n", match.end())]
            target = ref if ref in self.tracked_set else None
            if target is None:
                continue
            is_source = bool(re.search(r"(^|\s)(source|\.)\s", line))
            is_exec = bool(SHELL_EXEC_RE.search(line)) or line.lstrip().startswith('"$')
            etype = "imports" if is_source else "invokes"
            if is_root_wrapper and ref.startswith("bin/") and re.search(r"(^|\s)exec\s", line):
                reason = f"root wrapper가 `exec /bin/zsh \"${var}/{ref}\"`로 실제 구현에 위임"
                confidence = "high"
            elif is_source:
                reason = f"`${var}/{ref}`를 source"
                confidence = "high"
            elif is_exec:
                reason = f"`${var}/{ref}`를 실행"
                confidence = "high"
            else:
                reason = f"`${var}/{ref}` 경로를 참조 (같은 줄에서 실행 여부 미확인)"
                confidence = "medium"
            self.file_edge(path, target, etype, confidence, reason)
        for match in KLMS_DIR_RE.finditer(text):
            kind, ref = match.groups()
            target = f"{KLMS_DIR_TO_PATH[kind]}/{ref}"
            line = text[text.rfind("\n", 0, match.start()) + 1 : text.find("\n", match.end())]
            is_source = bool(re.search(r"(^|\s)(source|\.)\s", line))
            is_exec = bool(SHELL_EXEC_RE.search(line))
            base = f"`$KLMS_{kind}_DIR/{ref}` (KLMS_{kind}_DIR는 src/sh/klms_common.sh가 {KLMS_DIR_TO_PATH[kind]}로 정의)"
            if is_source:
                etype, confidence, reason = "imports", "high", base + "를 source"
            elif is_exec:
                etype, confidence, reason = "invokes", "high", base + "를 같은 줄에서 실행"
            else:
                etype, confidence, reason = "invokes", "medium", base + "를 인자/변수로 참조. 같은 줄에서 실행 여부 미확인"
            self.file_edge(path, target, etype, confidence, reason)
        # ./x.sh calls (cwd is the repo root set by klms_init_context)
        for match in DOT_SLASH_RE.finditer(text):
            ref = match.group(1)
            if ref in self.tracked_set and "/" not in ref:
                self.file_edge(path, ref, "invokes", "medium", f"`./{ref}` 호출. cwd가 저장소 루트라는 가정에 의존")
        for match in PY_MODULE_RE.finditer(text):
            module = match.group(1)
            target = self.resolve_python_module(module, path)
            if target:
                self.file_edge(path, target, "invokes", "medium", f"`python3 -m {module}` 실행. 모듈 경로는 PYTHONPATH/cwd에 의존")
        self.parse_generic_paths(path, text, "invokes", "shell 스크립트 안의 저장소 상대 경로 문자열", confidence="medium")
        self.parse_basename_refs(path, text)

    def parse_basename_refs(self, path: str, text: str) -> None:
        """Bare script names (e.g. "sync_klms_core.sh" in Swift). Low confidence."""
        own = PurePosixPath(path).name
        for match in BASENAME_RE.finditer(text):
            name = match.group(1)
            if name == own:
                continue
            candidates = [c for c in self.basename_index.get(name, []) if c != path]
            if not candidates:
                continue
            ambiguous = len(candidates) > 1
            if ambiguous:
                root_level = [c for c in candidates if "/" not in c]
                if len(root_level) != 1:
                    continue
                target = root_level[0]
            else:
                target = candidates[0]
            existing = any(
                e["source"] == f"file:{path}" and e["target"] == f"file:{target}"
                for e in self.edges.values()
            )
            if existing:
                continue
            if ambiguous:
                reason = f"파일 이름 '{name}'만 문자열로 등장. 같은 이름이 {len(candidates)}곳에 있어 root 파일로 해석"
            else:
                reason = f"파일 이름 '{name}'만 문자열로 등장. 유일한 tracked 파일과 이름이 일치"
            self.file_edge(path, target, "invokes", "low", reason)

    def resolve_python_module(self, module: str, source: str) -> Optional[str]:
        rel = module.replace(".", "/")
        bases = ["src/python", "", "tools", "tests"]
        src_dir = str(PurePosixPath(source).parent)
        if src_dir != ".":
            bases.insert(0, src_dir)
        for base in bases:
            for cand in (f"{base}/{rel}.py", f"{base}/{rel}/__init__.py"):
                cand = cand.lstrip("/")
                if cand in self.tracked_set and cand != source:
                    return cand
        return None

    def parse_python(self, path: str, text: str) -> None:
        pkg_dir = str(PurePosixPath(path).parent)
        has_src_path = bool(re.search(r"sys\.path\.(?:insert|append)\([^)]*(?:src/python|\"src\"\s*/\s*\"python\")", text))
        has_src_pkg = "src.python" in text
        for match in PY_IMPORT_RE.finditer(text):
            module = match.group(1) or match.group(2)
            if not module:
                continue
            target: Optional[str] = None
            if module.startswith("."):
                stripped = module.lstrip(".")
                level = len(module) - len(stripped)
                base = PurePosixPath(pkg_dir)
                for _ in range(level - 1):
                    base = base.parent
                rel = stripped.replace(".", "/")
                for cand in (f"{base}/{rel}.py", f"{base}/{rel}/__init__.py", f"{base}/__init__.py" if not rel else ""):
                    if cand and cand in self.tracked_set and cand != path:
                        target = cand
                        break
                reason = f"상대 import `{module}`"
            else:
                target = self.resolve_python_module(module, path)
                reason = f"`import {module}`"
                if target and path.startswith("tests/") and target.startswith("src/python/"):
                    if module.startswith("src.python.") and has_src_pkg:
                        reason += " (src.python 네임스페이스 경로로 import)"
                    elif has_src_path:
                        reason += " (sys.path에 src/python 추가 후 import)"
                    else:
                        reason += " (모듈 경로 해석 방식 미확인)"
            if target:
                self.file_edge(path, target, "imports", "high", reason)
        self.parse_generic_paths(path, text, "invokes", "Python 코드 안의 저장소 상대 경로 문자열", confidence="medium")
        # PROJECT_DIR / "src" / "python" / "x.py" style
        for match in re.finditer(r'PROJECT_DIR((?:\s*/\s*"[^"]+")+)', text):
            parts = re.findall(r'"([^"]+)"', match.group(1))
            ref = "/".join(parts)
            if ref in self.tracked_set:
                self.file_edge(path, ref, "invokes", "high", f"`PROJECT_DIR / ... / \"{parts[-1]}\"` 경로로 참조")
        self.parse_basename_refs(path, text)

    def parse_javascript(self, path: str, text: str) -> None:
        refs: List[str] = []
        for regex in (JS_REQUIRE_RE, JS_SIDE_EFFECT_IMPORT_RE, JS_FROM_IMPORT_RE):
            refs.extend(m.group(1) for m in regex.finditer(text))
        for ref in refs:
            if not ref or not ref.startswith("."):
                continue
            target = self.resolve_relative(path, ref)
            if target:
                self.file_edge(path, target, "imports", "high", f"`require/import '{ref}'`")
        self.parse_generic_paths(path, text, "invokes", "JavaScript 코드 안의 저장소 상대 경로 문자열", confidence="medium")
        for match in re.finditer(r"path\.join\(\s*__dirname\s*,\s*[\"']([\w./-]+)[\"']\s*\)", text):
            target = self.resolve_relative(path, match.group(1))
            if target:
                self.file_edge(path, target, "invokes", "high", f"`path.join(__dirname, \"{match.group(1)}\")` 경로로 로드")
        for match in re.finditer(r"\$\{scriptDir\}/([\w][\w./-]+\.[A-Za-z0-9]+)", text):
            ref = match.group(1)
            if ref in self.tracked_set:
                self.file_edge(path, ref, "invokes", "high", f"`${{scriptDir}}/{ref}` 경로로 실행")
        self.parse_basename_refs(path, text)

    def parse_swift_package(self) -> None:
        for path, text in self.texts.items():
            if PurePosixPath(path).name != "Package.swift":
                continue
            pkg_dir = str(PurePosixPath(path).parent)
            for match in SWIFT_TARGET_RE.finditer(text):
                kind, name, body = match.groups()
                sub = "Tests" if kind == "testTarget" else "Sources"
                dir_path = f"{pkg_dir}/{sub}/{name}"
                deps_match = SWIFT_DEPS_RE.search(body or "")
                dep_names = re.findall(r'"([^"]+)"', deps_match.group(1)) if deps_match else []
                self.swift_targets[name] = {"dir": dir_path, "kind": kind, "deps": dep_names, "package": path}

    def dir_node_for(self, dir_path: str) -> Optional[str]:
        for node in self.nodes.values():
            if node["kind"] == "directory" and node["path"] == dir_path:
                return node["id"]
        return None

    def parse_swift(self, path: str, text: str) -> None:
        name = PurePosixPath(path).name
        if name == "Package.swift":
            for target_name, info in self.swift_targets.items():
                if info["package"] != path:
                    continue
                dir_id = self.dir_node_for(info["dir"])
                if dir_id:
                    self.add_edge("packages", f"file:{path}", dir_id, "high", [
                        {"path": path, "reason": f"Package.swift가 {info['kind']} '{target_name}'을 선언 (경로 {info['dir']})"}
                    ])
                for dep in info["deps"]:
                    dep_info = self.swift_targets.get(dep)
                    if not dep_info or not dir_id:
                        continue
                    dep_dir = self.dir_node_for(dep_info["dir"])
                    if dep_dir:
                        etype = "tests" if info["kind"] == "testTarget" else "imports"
                        self.add_edge(etype, dir_id, dep_dir, "high", [
                            {"path": path, "reason": f"Package.swift에서 target '{target_name}'이 '{dep}'에 의존"}
                        ])
            return
        for match in SWIFT_IMPORT_RE.finditer(text):
            testable, module = match.groups()
            info = self.swift_targets.get(module)
            if not info:
                continue
            dir_id = self.dir_node_for(info["dir"])
            if not dir_id:
                continue
            etype = "tests" if self.is_test_file(path) else "imports"
            reason = f"`{'@testable ' if testable else ''}import {module}` (Package.swift target → {info['dir']})"
            if etype == "tests" and not testable:
                reason += ". @testable이 아닌 일반 import라 링크 의존성일 뿐 직접 검증 대상이 아닐 수 있다"
            self.add_edge(etype, f"file:{path}", dir_id, "high", [{"path": path, "reason": reason}])
        self.parse_generic_paths(path, text, "invokes", "Swift 코드 안의 저장소 상대 경로 문자열", confidence="medium")
        self.parse_basename_refs(path, text)

    def parse_allowlist(self, path: str, text: str) -> None:
        bases = [""] if "Python" not in PurePosixPath(path).name else ["vendor/python-packages/"]
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            for base in bases:
                ref = base + line
                if ref in self.tracked_set:
                    self.file_edge(path, ref, "packages", "high", f"allowlist 항목 '{line}'이 앱 EnginePayload에 주입됨")
                    break

    def parse_package_json(self, path: str, text: str) -> None:
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return
        base = str(PurePosixPath(path).parent)
        main = data.get("main")
        if isinstance(main, str):
            target = self.resolve_relative(path, main)
            if target:
                self.file_edge(path, target, "packages", "high", f"package.json \"main\": \"{main}\"")
        scripts = data.get("scripts", {})
        for script_name, command in scripts.items():
            if not isinstance(command, str):
                continue
            for ref in re.findall(r"(?<![\w-])((?:src|test|tests|tools)/[\w./-]+\.[A-Za-z0-9]+|\./[\w./-]+\.[A-Za-z0-9]+)", command):
                target = self.resolve_relative(path, ref)
                if target:
                    self.file_edge(path, target, "invokes", "high", f"package.json scripts.{script_name}이 '{ref}' 실행")
        for dep_kind in ("dependencies", "devDependencies"):
            deps = data.get(dep_kind, {})
            if deps:
                self.nodes[f"file:{path}"].setdefault("external_dependencies", {})[dep_kind] = sorted(deps)

    def parse_wrangler(self, path: str, text: str) -> None:
        match = re.search(r'^main\s*=\s*"([^"]+)"', text, re.M)
        if match:
            target = self.resolve_relative(path, match.group(1))
            if target:
                self.file_edge(path, target, "packages", "high", f"wrangler.toml main = \"{match.group(1)}\"")

    def parse_html(self, path: str, text: str) -> None:
        for match in re.finditer(r'(?:src|href)="(\./[\w./-]+)"', text):
            target = self.resolve_relative(path, match.group(1))
            if target:
                self.file_edge(path, target, "imports", "high", f"HTML이 '{match.group(1)}'을 로드")

    # communicates ----------------------------------------------------------
    def collect_routes(self, path: str, text: str) -> None:
        routes = set(m.group(1) for m in ROUTE_RE.finditer(text))
        if not routes:
            return
        self.route_index[path] = routes
        if self.is_test_file(path):
            return
        if re.search(r"http\.createServer\(|async fetch\(request|addEventListener\(\"fetch\"", text):
            self.server_files.add(path)

    def link_routes(self) -> None:
        for client, routes in self.route_index.items():
            if client in self.server_files:
                continue
            for server in sorted(self.server_files):
                shared = sorted(routes & self.route_index[server])
                if not shared:
                    continue
                sample = ", ".join(shared[:4]) + (" 등" if len(shared) > 4 else "")
                uses_ws = "WebSocket" in self.texts.get(client, "") and "WebSocket" in self.texts.get(server, "")
                reason = f"HTTP 경로 문자열 {len(shared)}개 공유 ({sample})"
                if uses_ws:
                    reason += "; 양쪽 모두 WebSocket 사용"
                confidence = "medium" if len(shared) >= 3 else "low"
                if self.is_test_file(client):
                    confidence = "low"
                    reason += ". 테스트 보조 파일이라 실제 통신이 아니라 같은 경로를 흉내 내는 것일 수 있다"
                elif confidence == "low":
                    reason += ". 공유 경로가 적어 이름 일치 수준으로만 본다"
                reason += ". 배포 형태에 따라 두 서버 중 하나만 실제로 쓰인다"
                self.file_edge(client, server, "communicates", confidence, reason)

    # tests by name ----------------------------------------------------------
    def link_tests_by_name(self) -> None:
        for path in self.tracked:
            if not self.is_test_file(path):
                continue
            name = PurePosixPath(path).name
            stem = None
            if name.startswith("test_") and name.endswith(".py"):
                stem = name[5:-3]
                candidates = [f"src/python/{stem}.py", f"tools/{stem}.py", f"src/python/klms_sync_v2/{stem}.py"]
            elif name.endswith("Tests.swift"):
                stem = name[:-len("Tests.swift")]
                candidates = [p for p in self.basename_index.get(f"{stem}.swift", []) if "/Sources/" in p]
            else:
                continue
            for cand in candidates:
                if cand in self.tracked_set:
                    exists = any(
                        e["source"] == f"file:{path}" and e["target"] == f"file:{cand}" for e in self.edges.values()
                    )
                    if not exists:
                        self.file_edge(path, cand, "tests", "low", f"테스트 파일 이름 '{name}'이 '{cand}'와 이름으로만 대응")

    # component aggregation -------------------------------------------------
    def component_of_node(self, node_id: str) -> Optional[str]:
        node = self.nodes.get(node_id)
        if not node:
            return None
        if node["kind"] == "component":
            return node_id
        comp = node.get("component_id")
        return f"component:{comp}" if comp else None

    def aggregate_component_edges(self) -> None:
        groups: Dict[Tuple[str, str, str], List[dict]] = defaultdict(list)
        for edge in list(self.edges.values()):
            if edge["type"] == "contains":
                continue
            src_comp = self.component_of_node(edge["source"])
            dst_comp = self.component_of_node(edge["target"])
            if not src_comp or not dst_comp or src_comp == dst_comp:
                continue
            groups[(edge["type"], src_comp, dst_comp)].append(edge)
        for (etype, src, dst), members in groups.items():
            best = max(members, key=lambda e: CONFIDENCE_RANK[e["confidence"]])
            evidence = []
            for member in sorted(members, key=lambda e: -CONFIDENCE_RANK[e["confidence"]])[:12]:
                target_node = self.nodes[member["target"]]
                target_desc = target_node["path"] or target_node["label"]
                for ev in member["evidence"][:1]:
                    evidence.append({"path": ev["path"], "reason": f"→ {target_desc}: {ev['reason']}"})
            edge_id = f"{etype}:{src}->{dst}"
            self.edges[edge_id] = {
                "id": edge_id,
                "source": src,
                "target": dst,
                "type": etype,
                "confidence": best["confidence"],
                "evidence": evidence,
                "level": "component",
                "member_edge_count": len(members),
                "member_edge_ids": [m["id"] for m in members],
                "confidence_breakdown": dict(Counter(m["confidence"] for m in members)),
            }

    # output ----------------------------------------------------------------
    def build(self) -> dict:
        self.collect_tracked()
        self.read_texts()
        self.collect_git_history()
        self.classify()
        self.build_nodes()
        self.extract_edges()
        self.aggregate_component_edges()
        head = run_git(self.repo, "rev-parse", "HEAD").strip()
        branch = run_git(self.repo, "rev-parse", "--abbrev-ref", "HEAD").strip()
        dirty = bool(run_git(self.repo, "status", "--porcelain", "--untracked-files=no").strip())
        remote = ""
        try:
            remote = run_git(self.repo, "remote", "get-url", "origin").strip()
        except subprocess.CalledProcessError:
            pass
        language_totals = Counter()
        for node in self.nodes.values():
            if node["kind"] == "file" and node["language"]:
                language_totals[node["language"]] += 1
        nodes = sorted(self.nodes.values(), key=lambda n: ({"system": 0, "component": 1, "directory": 2, "file": 3}[n["kind"]], n["id"]))
        edges = sorted(self.edges.values(), key=lambda e: (e["type"], e["id"]))
        return {
            "meta": {
                "repository": remote or self.repo.name,
                "repository_name": self.repo.name,
                "source_commit": head,
                "source_branch": branch,
                "worktree_dirty": dirty,
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "tracked_file_count": len(self.tracked),
                "analyzed_text_file_count": len(self.texts),
                "node_count": len(nodes),
                "edge_count": len(edges),
                "edge_types": list(EDGE_TYPES),
                "languages": dict(sorted(language_totals.items(), key=lambda kv: -kv[1])),
                "analyzer": "experiments/neukbao-visual-diagram/analyze.py",
                "component_map": "experiments/neukbao-visual-diagram/component-map.json",
                "notes": [
                    "commit_count는 해당 파일을 변경한 커밋 수이며 디렉터리/컴포넌트는 하위 파일 값의 합계다.",
                    "rename 이전 이력은 따라가지 않는다 (git log --name-only 기준).",
                    "tracked 파일만 읽었고 ignored/untracked/runtime 데이터는 열지 않았다.",
                ],
            },
            "nodes": nodes,
            "edges": edges,
        }


def load_component_map(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    ids = [c["id"] for c in data["components"]]
    if len(ids) != len(set(ids)):
        raise SystemExit("component-map.json: duplicate component id")
    return data


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="repository root (must be a git worktree)")
    parser.add_argument("--output", required=True, help="graph.json output path")
    parser.add_argument("--component-map", default=str(DEFAULT_COMPONENT_MAP))
    parser.add_argument("--max-commits", type=int, default=None, help="limit git log depth (for quick runs)")
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists():
        top = run_git(repo, "rev-parse", "--show-toplevel").strip()
        repo = Path(top).resolve()
    component_map = load_component_map(Path(args.component_map))
    analyzer = Analyzer(repo, component_map, max_commits=args.max_commits)
    graph = analyzer.build()

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(graph, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    meta = graph["meta"]
    kinds = Counter(n["kind"] for n in graph["nodes"])
    types = Counter(e["type"] for e in graph["edges"])
    print(f"repository      : {meta['repository']}")
    print(f"source_commit   : {meta['source_commit']} ({meta['source_branch']}{', dirty' if meta['worktree_dirty'] else ''})")
    print(f"tracked files   : {meta['tracked_file_count']}")
    print(f"nodes           : {len(graph['nodes'])} {dict(kinds)}")
    print(f"edges           : {len(graph['edges'])} {dict(types)}")
    uncategorized = [n for n in graph["nodes"] if n["kind"] == "component" and n.get("component_id") == "uncategorized"]
    if uncategorized:
        print(f"warning: {uncategorized[0]['file_count']} file(s) fell into 'uncategorized'", file=sys.stderr)
    print(f"output          : {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
