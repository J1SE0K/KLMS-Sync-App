#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from klms_sync import analyze_login_status


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--state-json", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--write-json")
    return parser


def check(name: str, status: str, detail: str = "") -> dict[str, str]:
    return {"name": name, "status": status, "detail": detail}


def run_quick(argv: list[str], cwd: Path, timeout: int = 8) -> tuple[bool, str]:
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    text = (result.stderr or result.stdout or "").strip().splitlines()
    return result.returncode == 0, text[0] if text else f"exit={result.returncode}"


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def dashboard_login_cache_check(dashboard: Any, source: str = "dashboard cache") -> dict[str, str]:
    if not isinstance(dashboard, list) or not dashboard:
        return check("klms-login-cache", "warn", "dashboard cache missing")

    status = analyze_login_status(dashboard)
    if status.get("status") == "ok":
        title = str(status.get("title") or "").strip()
        detail = f"{source} present title={title}" if title else f"{source} present"
        return check("klms-login-cache", "ok", detail)

    detail = str(status.get("message") or status.get("error") or "dashboard cache looks login-like")
    return check("klms-login-cache", "warn", detail)


def dashboard_login_cache_check_from_cache(cache_dir: Path) -> dict[str, str]:
    candidates: list[dict[str, Any]] = []
    for relative in ("dashboard.json", "core/dashboard.json", "notice/dashboard.json", "files/dashboard.json"):
        path = cache_dir / relative
        if not path.exists():
            continue
        dashboard = load_json(path, [])
        result = dashboard_login_cache_check(dashboard, source=relative)
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = 0.0
        candidates.append({"relative": relative, "dashboard": dashboard, "result": result, "mtime": mtime})

    if not candidates:
        return check("klms-login-cache", "warn", "dashboard cache missing")

    ok_candidates = [item for item in candidates if item["result"]["status"] == "ok"]
    if ok_candidates:
        newest_ok = max(ok_candidates, key=lambda item: float(item["mtime"]))
        return newest_ok["result"]

    newest = max(candidates, key=lambda item: float(item["mtime"]))
    return newest["result"]


def build_result(script_dir: Path, config: Path, cache_dir: Path, state_json: Path) -> dict[str, Any]:
    checks: list[dict[str, str]] = []
    checks.append(check("config.env", "ok" if config.exists() else "fail", str(config)))

    for name in ("python3", "node", "swift", "osascript"):
        found = shutil.which(name)
        checks.append(check(f"executable:{name}", "ok" if found else "fail", found or "not found"))

    runtime_dir = cache_dir.parent
    data_dir = runtime_dir.parent
    swift_cache = runtime_dir / "tmp" / "doctor" / "swift-module-cache"
    clang_cache = runtime_dir / "tmp" / "doctor" / "clang-module-cache"
    try:
        swift_cache.mkdir(parents=True, exist_ok=True)
        clang_cache.mkdir(parents=True, exist_ok=True)
        probe = swift_cache / ".write-probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        checks.append(check("swift-module-cache", "ok", str(swift_cache)))
    except Exception as exc:  # noqa: BLE001
        checks.append(check("swift-module-cache", "fail", str(exc)))

    manifest = load_json(cache_dir / "course_file_manifest.json", [])
    if isinstance(manifest, list) and manifest:
        missing = [
            item.get("relative_path", "")
            for item in manifest
            if isinstance(item, dict) and item.get("absolute_path") and not Path(item["absolute_path"]).is_file()
        ]
        checks.append(check("file-manifest", "ok" if not missing else "fail", f"tracked={len(manifest)} missing={len(missing)}"))
    else:
        checks.append(check("file-manifest", "warn", "manifest missing or empty"))

    course_files_root = data_dir / "course_files"
    checks.append(
        check(
            "course-files",
            "ok" if course_files_root.exists() else "warn",
            str(course_files_root),
        )
    )
    runtime_staging_root = runtime_dir / "tmp" / "files" / "downloads"
    new_files_root = runtime_staging_root / "KLMS New Files"
    checks.append(
        check(
            "downloads-inbox",
            "ok",
            f"{new_files_root} (runtime staging; ~/Downloads is not used by default)",
        )
    )
    checks.append(check("state-json", "ok" if state_json.exists() else "warn", str(state_json)))
    checks.append(dashboard_login_cache_check_from_cache(cache_dir))
    for scope in ("core", "notice", "files"):
        timing = cache_dir / scope / "stage_timings.json"
        checks.append(check(f"stage-timing:{scope}", "ok" if timing.exists() else "warn", str(timing)))

    for app_name in ("Safari", "Notes", "Calendar", "Reminders"):
        ok, detail = run_quick(["/usr/bin/osascript", "-e", f'id of application "{app_name}"'], script_dir)
        checks.append(check(f"app-available:{app_name}", "ok" if ok else "warn", detail))

    overall = "fail" if any(item["status"] == "fail" for item in checks) else "ok"
    return {"status": overall, "checks": checks}


def print_text(result: dict[str, Any]) -> None:
    print(f"doctor_status={result['status']}")
    for item in result["checks"]:
        print(f"{item['status']}\t{item['name']}\t{item['detail']}")


def main() -> int:
    args = build_parser().parse_args()
    result = build_result(Path(args.script_dir), Path(args.config), Path(args.cache_dir), Path(args.state_json))
    if args.write_json:
        Path(args.write_json).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_text(result)
    return 1 if result["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
