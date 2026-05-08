#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlparse

from klms_transport import load_json, normalize_whitespace, now_utc_iso, write_json, write_text

COMPLETED_SUBMISSION_KEYWORDS = (
    "채점을 위해 제출되었습니다",
    "제출되었습니다",
    "제출 완료",
    "채점 완료",
    "submitted for grading",
    "submitted",
    "graded",
)
STOP_WORDS = {
    "assignment",
    "homework",
    "project",
    "submit",
    "submission",
    "과제",
    "숙제",
    "제출",
    "보고서",
    "문제",
    "자료",
}
OUTPUT_VERSION = 1


@dataclass
class ProcessResult:
    index: dict[str, Any]
    output_root: Path


def main() -> int:
    args = build_parser().parse_args()
    result = process_assignments(args)
    index = result.index
    print(
        "status=ok "
        f"assignments={index['assignment_count']} "
        f"processed={index['processed_count']} "
        f"skipped={index['skipped_count']} "
        f"output_root={result.output_root}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build local KLMS assignment work packets from the latest sync state."
    )
    parser.add_argument("--state-json", required=True)
    parser.add_argument("--manifest-json")
    parser.add_argument("--download-log-json")
    parser.add_argument("--output-root", required=True)
    parser.add_argument(
        "--provider",
        choices=("codex", "deterministic"),
        default="deterministic",
        help="Use Codex for assignment brief generation, or deterministic local templates.",
    )
    parser.add_argument("--codex-bin", default="")
    parser.add_argument("--codex-timeout-seconds", type=int, default=300)
    parser.add_argument("--max-linked-materials", type=int, default=8)
    parser.add_argument("--assignment-url", action="append", default=[])
    parser.add_argument(
        "--select",
        action="store_true",
        help="Show active assignments and choose which ones to process interactively.",
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--no-codex",
        action="store_true",
        help="Alias for --provider=deterministic.",
    )
    return parser


def process_assignments(args: argparse.Namespace) -> ProcessResult:
    state_json = Path(args.state_json).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()
    provider = "deterministic" if args.no_codex else args.provider
    state = load_required_state(state_json)
    manifest = load_optional_list(args.manifest_json)
    download_log = load_json(Path(args.download_log_json), {}) if args.download_log_json else {}
    download_index = build_download_index(download_log)
    requested_urls = {normalize_url(value) for value in args.assignment_url}
    active_assignments = [
        item
        for item in state.get("content", {}).get("assignments", [])
        if is_active_assignment(item)
        and (not requested_urls or normalize_url(str(item.get("url", ""))) in requested_urls)
    ]
    if args.select:
        active_assignments = select_assignments(active_assignments)
    material_index = build_material_index(manifest, download_index)

    output_root.mkdir(parents=True, exist_ok=True)
    assignment_entries: list[dict[str, Any]] = []
    processed_count = 0
    skipped_count = 0

    for assignment in active_assignments:
        entry = process_assignment(
            assignment,
            material_index,
            output_root,
            provider,
            args,
            state_json,
        )
        assignment_entries.append(entry)
        if entry["status"] == "skipped":
            skipped_count += 1
        else:
            processed_count += 1

    index = {
        "version": OUTPUT_VERSION,
        "generated_at": now_utc_iso(),
        "state_json": str(state_json),
        "provider": provider,
        "assignment_count": len(active_assignments),
        "processed_count": processed_count,
        "skipped_count": skipped_count,
        "assignments": assignment_entries,
    }
    write_json(output_root / "index.json", index)
    return ProcessResult(index=index, output_root=output_root)


def select_assignments(
    assignments: list[dict[str, Any]],
    input_stream: Any | None = None,
    output_stream: Any | None = None,
) -> list[dict[str, Any]]:
    input_stream = input_stream or sys.stdin
    output_stream = output_stream or sys.stderr
    if not assignments:
        print("처리할 미완료 과제가 없습니다.", file=output_stream)
        return []

    print("처리할 과제를 선택하세요.", file=output_stream)
    for index, assignment in enumerate(assignments, start=1):
        print(f"{index}) {assignment_selection_label(assignment)}", file=output_stream)
    print("입력 예: 1 / 1,3 / 2-4 / all / q", file=output_stream)

    while True:
        print("> ", end="", file=output_stream, flush=True)
        raw_value = input_stream.readline()
        if raw_value == "":
            print("선택이 취소되었습니다.", file=output_stream)
            return []
        selection = parse_assignment_selection(raw_value, len(assignments))
        if selection is not None:
            if not selection:
                print("선택이 취소되었습니다.", file=output_stream)
            return [assignments[index] for index in selection]
        print("선택을 다시 입력해 주세요.", file=output_stream)


def assignment_selection_label(assignment: dict[str, Any]) -> str:
    course = normalize_whitespace(str(assignment.get("course", ""))) or "과목 미상"
    title = normalize_whitespace(str(assignment.get("title", ""))) or "제목 없음"
    due = normalize_whitespace(str(assignment.get("due") or assignment.get("sync_due") or "마감 확인 필요"))
    return f"[{course}] {title} - {due}"


def parse_assignment_selection(value: str, count: int) -> list[int] | None:
    normalized = normalize_whitespace(value).lower()
    if normalized in {"q", "quit", "cancel", "취소"}:
        return []
    if normalized in {"all", "a", "전체"}:
        return list(range(count))
    if not normalized:
        return []

    selected: list[int] = []
    seen: set[int] = set()
    for token in re.split(r"[\s,]+", normalized):
        if not token:
            continue
        if "-" in token:
            parts = token.split("-", 1)
            if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
                return None
            start = int(parts[0])
            end = int(parts[1])
            if start > end:
                return None
            numbers = range(start, end + 1)
        else:
            if not token.isdigit():
                return None
            numbers = [int(token)]

        for number in numbers:
            if number < 1 or number > count:
                return None
            index = number - 1
            if index not in seen:
                selected.append(index)
                seen.add(index)

    return selected


def process_assignment(
    assignment: dict[str, Any],
    material_index: list[dict[str, Any]],
    output_root: Path,
    provider: str,
    args: argparse.Namespace,
    state_json: Path,
) -> dict[str, Any]:
    assignment_id = stable_assignment_id(assignment)
    materials = linked_materials_for_assignment(
        assignment,
        material_index,
        max(0, int(args.max_linked_materials)),
    )
    packet = build_assignment_packet(assignment, assignment_id, materials, state_json)
    fingerprint = assignment_fingerprint(packet)
    assignment_dir = assignment_output_dir(output_root, assignment, assignment_id)
    status_path = assignment_dir / "status.json"
    previous_status = load_json(status_path, {}) or {}
    existing_outputs = all(
        (assignment_dir / name).exists()
        for name in ("brief.md", "checklist.md", "draft_template.md", "assignment.json")
    )

    if (
        not args.force
        and previous_status.get("fingerprint") == fingerprint
        and previous_status.get("output_version") == OUTPUT_VERSION
        and existing_outputs
    ):
        skipped_status = {
            **previous_status,
            "status": "skipped",
            "checked_at": now_utc_iso(),
        }
        write_json(status_path, skipped_status)
        return compact_index_entry(assignment, assignment_id, assignment_dir, skipped_status)

    assignment_dir.mkdir(parents=True, exist_ok=True)
    prompt = build_codex_prompt(packet)
    write_json(assignment_dir / "assignment.json", packet)
    write_text(assignment_dir / "codex_prompt.md", prompt)

    generation, provider_status = generate_assignment_brief(
        packet,
        prompt,
        assignment_dir,
        provider,
        args.codex_bin,
        args.codex_timeout_seconds,
    )
    write_json(
        assignment_dir / "codex_result.json",
        {
            "provider": provider,
            "provider_status": provider_status,
            "generated_at": now_utc_iso(),
            "result": generation,
        },
    )
    write_text(assignment_dir / "brief.md", render_brief(packet, generation, provider_status))
    write_text(assignment_dir / "checklist.md", render_checklist(packet, generation))
    write_text(assignment_dir / "draft_template.md", render_draft_template(packet, generation))

    status = {
        "output_version": OUTPUT_VERSION,
        "status": "processed",
        "assignment_id": assignment_id,
        "fingerprint": fingerprint,
        "provider": provider,
        "provider_status": provider_status,
        "updated_at": now_utc_iso(),
        "materials_count": len(materials),
        "assignment_dir": str(assignment_dir),
    }
    write_json(status_path, status)
    return compact_index_entry(assignment, assignment_id, assignment_dir, status)


def load_required_state(path: Path) -> dict[str, Any]:
    state = load_json(path, None)
    if not isinstance(state, dict):
        raise SystemExit(f"Missing or invalid state JSON: {path}")
    if state.get("status") != "ok" or state.get("content", {}).get("kind") != "success":
        raise SystemExit(f"State is not a successful KLMS sync state: {path}")
    assignments = state.get("content", {}).get("assignments")
    if not isinstance(assignments, list):
        raise SystemExit(f"State has no assignment list: {path}")
    return state


def load_optional_list(path_value: str | None) -> list[dict[str, Any]]:
    if not path_value:
        return []
    payload = load_json(Path(path_value), [])
    return payload if isinstance(payload, list) else []


def is_active_assignment(item: dict[str, Any]) -> bool:
    if not isinstance(item, dict):
        return False
    if not normalize_whitespace(str(item.get("url", ""))):
        return False
    if not normalize_whitespace(str(item.get("title", ""))):
        return False
    if bool(item.get("auto_completed")):
        return False
    submission = normalize_whitespace(str(item.get("submission", ""))).lower()
    return not any(keyword.lower() in submission for keyword in COMPLETED_SUBMISSION_KEYWORDS)


def build_download_index(download_log: Any) -> dict[str, dict[str, Any]]:
    results = download_log.get("results", []) if isinstance(download_log, dict) else []
    index: dict[str, dict[str, Any]] = {}
    if not isinstance(results, list):
        return index
    for result in results:
        if not isinstance(result, dict):
            continue
        for key in (
            str(result.get("url") or ""),
            str(result.get("source_url") or ""),
            str(result.get("relative_path") or ""),
            str(result.get("manifest_relative_path") or ""),
        ):
            normalized = normalize_url(key) if key.startswith("http") else normalize_whitespace(key)
            if normalized:
                index[normalized] = result
    return index


def build_material_index(
    manifest: list[dict[str, Any]],
    download_index: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    materials: list[dict[str, Any]] = []
    for item in manifest:
        if not isinstance(item, dict):
            continue
        course = normalize_whitespace(str(item.get("course", "")))
        relative_path = normalize_whitespace(str(item.get("relative_path", "")))
        if not course or not relative_path:
            continue
        downloaded = (
            download_index.get(normalize_url(str(item.get("url") or "")))
            or download_index.get(normalize_url(str(item.get("source_url") or "")))
            or download_index.get(relative_path)
            or {}
        )
        candidate_paths = [
            item.get("absolute_path"),
            downloaded.get("destination_path") if isinstance(downloaded, dict) else "",
            downloaded.get("downloads_path") if isinstance(downloaded, dict) else "",
        ]
        resolved_path = next(
            (str(path) for path in candidate_paths if path and Path(str(path)).exists()),
            str(item.get("absolute_path") or ""),
        )
        materials.append(
            {
                "course": course,
                "filename": normalize_whitespace(str(item.get("filename", "")))
                or Path(relative_path).name,
                "relative_path": relative_path,
                "absolute_path": resolved_path,
                "exists": bool(resolved_path and Path(resolved_path).exists()),
                "url": normalize_whitespace(str(item.get("url", ""))),
                "source_url": normalize_whitespace(str(item.get("source_url", ""))),
                "source_title": normalize_whitespace(str(item.get("source_title", ""))),
                "section_title": normalize_whitespace(str(item.get("section_title", ""))),
                "activity_title": normalize_whitespace(str(item.get("activity_title", ""))),
                "link_text": normalize_whitespace(str(item.get("link_text", ""))),
            }
        )
    return materials


def linked_materials_for_assignment(
    assignment: dict[str, Any],
    materials: list[dict[str, Any]],
    max_materials: int,
) -> list[dict[str, Any]]:
    if max_materials <= 0:
        return []
    course_key = normalize_whitespace(str(assignment.get("course", ""))).casefold()
    title_tokens = token_set(str(assignment.get("title", "")))
    instruction_tokens = token_set(str(assignment.get("instructions", "")))
    scored: list[tuple[int, dict[str, Any]]] = []
    same_course: list[dict[str, Any]] = []

    for material in materials:
        if normalize_whitespace(material.get("course", "")).casefold() != course_key:
            continue
        same_course.append(material)
        material_text = " ".join(
            str(material.get(field, ""))
            for field in (
                "filename",
                "relative_path",
                "source_title",
                "section_title",
                "activity_title",
                "link_text",
            )
        )
        material_tokens = token_set(material_text)
        title_overlap = title_tokens & material_tokens
        instruction_overlap = instruction_tokens & material_tokens
        score = 3 * len(title_overlap) + len(instruction_overlap)
        if score > 0:
            prepared = compact_material(material)
            prepared["match_reason"] = "token-overlap"
            prepared["match_score"] = score
            scored.append((score, prepared))

    if scored:
        return [item for _score, item in sorted(scored, key=lambda pair: (-pair[0], pair[1]["relative_path"]))][
            :max_materials
        ]

    return [
        {
            **compact_material(material),
            "match_reason": "same-course-fallback",
            "match_score": 0,
        }
        for material in same_course[:max_materials]
    ]


def compact_material(material: dict[str, Any]) -> dict[str, Any]:
    return {
        "filename": material.get("filename", ""),
        "relative_path": material.get("relative_path", ""),
        "absolute_path": material.get("absolute_path", ""),
        "exists": bool(material.get("exists")),
        "url": material.get("url", ""),
        "source_url": material.get("source_url", ""),
        "source_title": material.get("source_title", ""),
        "section_title": material.get("section_title", ""),
        "activity_title": material.get("activity_title", ""),
    }


def build_assignment_packet(
    assignment: dict[str, Any],
    assignment_id: str,
    materials: list[dict[str, Any]],
    state_json: Path,
) -> dict[str, Any]:
    return {
        "version": OUTPUT_VERSION,
        "generated_at": now_utc_iso(),
        "source_state_json": str(state_json),
        "assignment_id": assignment_id,
        "assignment": {
            "url": normalize_whitespace(str(assignment.get("url", ""))),
            "type": normalize_whitespace(str(assignment.get("type", ""))),
            "category": normalize_whitespace(str(assignment.get("category", "assignment"))),
            "course": normalize_whitespace(str(assignment.get("course", ""))),
            "title": normalize_whitespace(str(assignment.get("title", ""))),
            "due": normalize_whitespace(str(assignment.get("due", ""))),
            "sync_due": normalize_whitespace(str(assignment.get("sync_due", ""))),
            "instructions": normalize_whitespace(str(assignment.get("instructions", ""))),
            "submission": normalize_whitespace(str(assignment.get("submission", ""))),
            "source_title": normalize_whitespace(str(assignment.get("source_title", ""))),
        },
        "linked_materials": materials,
        "policy": {
            "allowed": [
                "Summarize requirements.",
                "Create a work plan and checklist.",
                "Create a writing template.",
                "Identify questions the user should answer.",
            ],
            "not_allowed": [
                "Do not complete or submit the assignment for the user.",
                "Do not solve quizzes, exams, or graded questions.",
                "Do not interact with KLMS or any submission page.",
            ],
        },
    }


def generate_assignment_brief(
    packet: dict[str, Any],
    prompt: str,
    assignment_dir: Path,
    provider: str,
    codex_bin: str,
    timeout_seconds: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if provider != "codex":
        return deterministic_generation(packet), {"status": "skipped", "reason": "deterministic"}

    resolved_codex_bin = shutil.which(codex_bin) if codex_bin else ""
    codex_path = Path(resolved_codex_bin or codex_bin).expanduser() if codex_bin else None
    if not codex_path or not codex_path.exists():
        return deterministic_generation(packet), {
            "status": "fallback",
            "reason": "codex-bin-missing",
            "codex_bin": codex_bin,
        }

    schema_path = assignment_dir / "codex_output_schema.json"
    last_message_path = assignment_dir / "codex_last_message.json"
    write_json(schema_path, codex_output_schema())
    command = [
        str(codex_path),
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--ask-for-approval",
        "never",
        "--output-schema",
        str(schema_path),
        "--output-last-message",
        str(last_message_path),
        "-C",
        str(assignment_dir),
        "-",
    ]
    try:
        completed = subprocess.run(
            command,
            input=prompt,
            text=True,
            capture_output=True,
            timeout=max(10, timeout_seconds),
            check=False,
        )
    except Exception as error:  # noqa: BLE001
        return deterministic_generation(packet), {
            "status": "fallback",
            "reason": "codex-exception",
            "error": str(error),
        }

    parsed = parse_codex_json_result(last_message_path, completed.stdout)
    if completed.returncode != 0 or parsed is None:
        return deterministic_generation(packet), {
            "status": "fallback",
            "reason": "codex-failed",
            "returncode": completed.returncode,
            "stderr": completed.stderr[-4000:],
            "stdout": completed.stdout[-4000:],
        }

    return normalize_generation(parsed), {
        "status": "ok",
        "returncode": completed.returncode,
    }


def deterministic_generation(packet: dict[str, Any]) -> dict[str, Any]:
    assignment = packet["assignment"]
    title = assignment.get("title") or "과제"
    course = assignment.get("course") or "과목 미상"
    due = assignment.get("due") or assignment.get("sync_due") or "마감 정보 확인 필요"
    instructions = assignment.get("instructions") or "KLMS 원문에서 세부 요구사항을 확인해야 합니다."
    material_count = len(packet.get("linked_materials", []))
    return {
        "summary": f"{course}의 {title} 과제입니다. 마감은 {due}입니다.",
        "requirements": [
            f"KLMS 원문 요구사항 확인: {instructions}",
            f"마감 확인: {due}",
            "제출 형식과 제출 위치를 KLMS에서 최종 확인",
        ],
        "deliverables": [
            "제출용 파일 또는 답안",
            "필요한 경우 참고자료/코드/부록",
        ],
        "plan": [
            "KLMS 원문과 첨부자료를 먼저 확인",
            "요구사항을 작업 단위로 나누기",
            "초안 작성 후 요구사항 체크리스트로 검토",
            "제출 전 파일명, 형식, 마감 시각 재확인",
        ],
        "draft_template": "\n".join(
            [
                f"# {title}",
                "",
                "## 요구사항 해석",
                "",
                "## 풀이/작성 계획",
                "",
                "## 본문",
                "",
                "## 검토 메모",
                "",
            ]
        ),
        "questions": [
            "제출 형식이 PDF, 코드, 텍스트 중 무엇인지 확인했는가?",
            "채점 기준이나 분량 제한이 별도로 있는가?",
        ],
        "integrity_notes": [
            "이 문서는 작성 보조용이며 제출물을 자동 완성하지 않습니다.",
            "최종 답안 작성과 제출 판단은 사용자가 직접 해야 합니다.",
            f"연결된 참고자료 수: {material_count}",
        ],
    }


def normalize_generation(value: dict[str, Any]) -> dict[str, Any]:
    fallback = deterministic_generation({"assignment": {}, "linked_materials": []})
    normalized: dict[str, Any] = {}
    normalized["summary"] = normalize_whitespace(str(value.get("summary") or fallback["summary"]))
    for key in ("requirements", "deliverables", "plan", "questions", "integrity_notes"):
        raw_items = value.get(key)
        if isinstance(raw_items, list):
            items = [normalize_whitespace(str(item)) for item in raw_items if normalize_whitespace(str(item))]
        else:
            items = []
        normalized[key] = items or fallback[key]
    normalized["draft_template"] = str(value.get("draft_template") or fallback["draft_template"])
    return normalized


def build_codex_prompt(packet: dict[str, Any]) -> str:
    return "\n".join(
        [
            "You are helping the user prepare for a KLMS assignment.",
            "Use Korean unless the assignment itself requires English.",
            "Only use the JSON packet below. Do not inspect other files, cookies, browser state, or KLMS.",
            "Do not complete graded work, solve quizzes/exams, or submit anything.",
            "Return concise JSON matching the schema: summary, requirements, deliverables, plan, draft_template, questions, integrity_notes.",
            "",
            "<assignment_packet>",
            json.dumps(packet, ensure_ascii=False, indent=2),
            "</assignment_packet>",
        ]
    )


def codex_output_schema() -> dict[str, Any]:
    string_array = {"type": "array", "items": {"type": "string"}}
    return {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "summary",
            "requirements",
            "deliverables",
            "plan",
            "draft_template",
            "questions",
            "integrity_notes",
        ],
        "properties": {
            "summary": {"type": "string"},
            "requirements": string_array,
            "deliverables": string_array,
            "plan": string_array,
            "draft_template": {"type": "string"},
            "questions": string_array,
            "integrity_notes": string_array,
        },
    }


def parse_codex_json_result(path: Path, stdout_text: str) -> dict[str, Any] | None:
    candidates = []
    if path.exists():
        candidates.append(path.read_text(encoding="utf-8"))
    if stdout_text:
        candidates.append(stdout_text)
    for candidate in candidates:
        parsed = parse_json_object(candidate)
        if isinstance(parsed, dict):
            return parsed
    return None


def parse_json_object(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        return None
    try:
        return json.loads(match.group(0))
    except json.JSONDecodeError:
        return None


def render_brief(packet: dict[str, Any], generation: dict[str, Any], provider_status: dict[str, Any]) -> str:
    assignment = packet["assignment"]
    lines = [
        f"# {assignment.get('title') or 'KLMS 과제'}",
        "",
        f"- 과목: {assignment.get('course') or '확인 필요'}",
        f"- 마감: {assignment.get('due') or assignment.get('sync_due') or '확인 필요'}",
        f"- KLMS: {assignment.get('url') or '확인 필요'}",
        f"- 생성 상태: {provider_status.get('status', 'unknown')}",
        "",
        "## 요약",
        "",
        generation["summary"],
        "",
        "## 요구사항",
        "",
        *bullet_lines(generation["requirements"]),
        "",
        "## 제출물",
        "",
        *bullet_lines(generation["deliverables"]),
        "",
        "## 작업 계획",
        "",
        *numbered_lines(generation["plan"]),
        "",
        "## 연결된 자료",
        "",
    ]
    materials = packet.get("linked_materials", [])
    if materials:
        lines.extend(render_material_lines(materials))
    else:
        lines.append("- 연결된 자료 없음")
    lines.extend(
        [
            "",
            "## 확인 질문",
            "",
            *bullet_lines(generation["questions"]),
            "",
            "## 학업 윤리 메모",
            "",
            *bullet_lines(generation["integrity_notes"]),
            "",
        ]
    )
    return "\n".join(lines)


def render_checklist(packet: dict[str, Any], generation: dict[str, Any]) -> str:
    assignment = packet["assignment"]
    checklist = [
        f"# 체크리스트 - {assignment.get('title') or 'KLMS 과제'}",
        "",
        "- [ ] KLMS 원문 다시 열어 요구사항 확인",
        "- [ ] 마감 시각과 제출 형식 확인",
    ]
    checklist.extend(f"- [ ] {item}" for item in generation["requirements"])
    checklist.extend(f"- [ ] 제출물 준비: {item}" for item in generation["deliverables"])
    checklist.extend(
        [
            "- [ ] 최종 파일명과 첨부 누락 여부 확인",
            "- [ ] 제출 전 미리보기 또는 다운로드본 확인",
            "",
        ]
    )
    return "\n".join(checklist)


def render_draft_template(packet: dict[str, Any], generation: dict[str, Any]) -> str:
    assignment = packet["assignment"]
    header = [
        f"<!-- KLMS assignment: {assignment.get('title', '')} -->",
        "<!-- This is a writing template, not a completed submission. -->",
        "",
    ]
    return "\n".join(header) + generation["draft_template"].rstrip() + "\n"


def render_material_lines(materials: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    for material in materials:
        path = material.get("absolute_path") or material.get("relative_path") or ""
        exists = "있음" if material.get("exists") else "미확보"
        source = material.get("source_title") or material.get("activity_title") or ""
        reason = material.get("match_reason") or "matched"
        lines.append(
            f"- {material.get('filename') or material.get('relative_path')} "
            f"({exists}, {reason})"
        )
        if source:
            lines.append(f"  - 출처: {source}")
        if path:
            lines.append(f"  - 경로: {path}")
    return lines


def bullet_lines(items: list[str]) -> list[str]:
    return [f"- {item}" for item in items] or ["- 확인 필요"]


def numbered_lines(items: list[str]) -> list[str]:
    return [f"{index}. {item}" for index, item in enumerate(items, start=1)] or ["1. 확인 필요"]


def compact_index_entry(
    assignment: dict[str, Any],
    assignment_id: str,
    assignment_dir: Path,
    status: dict[str, Any],
) -> dict[str, Any]:
    return {
        "assignment_id": assignment_id,
        "course": normalize_whitespace(str(assignment.get("course", ""))),
        "title": normalize_whitespace(str(assignment.get("title", ""))),
        "due": normalize_whitespace(str(assignment.get("due", ""))),
        "sync_due": normalize_whitespace(str(assignment.get("sync_due", ""))),
        "url": normalize_whitespace(str(assignment.get("url", ""))),
        "status": status.get("status", ""),
        "provider": status.get("provider", ""),
        "materials_count": status.get("materials_count", 0),
        "assignment_dir": str(assignment_dir),
        "brief_path": str(assignment_dir / "brief.md"),
    }


def assignment_fingerprint(packet: dict[str, Any]) -> str:
    stable_packet = {
        "assignment": packet["assignment"],
        "linked_materials": [
            {
                "relative_path": item.get("relative_path", ""),
                "url": item.get("url", ""),
                "source_url": item.get("source_url", ""),
                "exists": bool(item.get("exists")),
            }
            for item in packet.get("linked_materials", [])
        ],
        "output_version": OUTPUT_VERSION,
    }
    payload = json.dumps(stable_packet, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def stable_assignment_id(assignment: dict[str, Any]) -> str:
    url = normalize_url(str(assignment.get("url", "")))
    parsed = urlparse(url)
    params = dict(parse_qsl(parsed.query, keep_blank_values=True))
    klms_id = params.get("id", "").strip()
    if klms_id and "/mod/assign/" in parsed.path:
        return f"assign-{safe_identifier_fragment(klms_id)}"
    payload = "|".join(
        [
            url,
            normalize_whitespace(str(assignment.get("title", ""))),
            normalize_whitespace(str(assignment.get("sync_due") or assignment.get("due", ""))),
        ]
    )
    return "item-" + hashlib.sha1(payload.encode("utf-8")).hexdigest()[:12]


def assignment_output_dir(output_root: Path, assignment: dict[str, Any], assignment_id: str) -> Path:
    course = safe_path_component(str(assignment.get("course", "")) or "unknown-course")
    title = safe_path_component(str(assignment.get("title", "")) or "assignment")
    due_prefix = due_date_prefix(str(assignment.get("sync_due") or assignment.get("due") or ""))
    return output_root / course / f"{due_prefix}-{title[:72]}-{assignment_id}"


def due_date_prefix(value: str) -> str:
    normalized = normalize_whitespace(value)
    if not normalized:
        return "undated"
    try:
        parsed = datetime.fromisoformat(normalized)
        return parsed.strftime("%Y%m%d")
    except ValueError:
        pass
    match = re.search(r"(\d{4})[.년-]\s*(\d{1,2})[.월-]\s*(\d{1,2})", normalized)
    if match:
        return f"{int(match.group(1)):04d}{int(match.group(2)):02d}{int(match.group(3)):02d}"
    return "undated"


def safe_path_component(value: str) -> str:
    text = normalize_whitespace(value) or "untitled"
    text = re.sub(r"[:/\\\n\r\t]", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" .")
    return text[:96] or "untitled"


def safe_identifier_fragment(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "unknown"


def token_set(value: str) -> set[str]:
    return {
        token
        for token in re.findall(r"[A-Za-z0-9가-힣]{2,}", normalize_whitespace(value).lower())
        if token not in STOP_WORDS
    }


def normalize_url(value: str) -> str:
    text = normalize_whitespace(value)
    if not text:
        return ""
    parsed = urlparse(text)
    if not parsed.scheme or not parsed.netloc:
        return text
    query = "&".join(
        f"{key}={value}"
        for key, value in sorted(parse_qsl(parsed.query, keep_blank_values=True))
        if key.lower() != "forcedownload"
    )
    return parsed._replace(query=query, fragment="").geturl()


if __name__ == "__main__":
    raise SystemExit(main())
