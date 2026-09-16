from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any

from .client import BoardClient

PHASE_PROGRESS = {
    "check": 10.0,
    "execute": 50.0,
    "verify": 80.0,
    "closeout": 95.0,
}


def _state_fingerprint(task: dict[str, Any]) -> str:
    relevant = {
        "id": task.get("id"),
        "title": task.get("title"),
        "status": task.get("status"),
        "phase": task.get("phase"),
        "summary": task.get("summary"),
        "blocker": task.get("blocker"),
        "updated_at": task.get("updated_at"),
        "completed_at": task.get("completed_at"),
        "steps": task.get("steps") or [],
        "final_review": task.get("final_review"),
    }
    payload = json.dumps(
        relevant,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:32]


def _progress(task: dict[str, Any]) -> float:
    if str(task.get("status") or "").lower() == "completed":
        return 100.0

    steps = task.get("steps")
    if isinstance(steps, list) and steps:
        completed = sum(
            1
            for step in steps
            if isinstance(step, dict)
            and str(step.get("status") or "").lower() == "completed"
        )
        return round((completed / len(steps)) * 100.0, 1)

    phase = str(task.get("phase") or "check").lower()
    return PHASE_PROGRESS.get(phase, 0.0)


def _current_step(task: dict[str, Any]) -> dict[str, Any] | None:
    steps = task.get("steps")
    if not isinstance(steps, list):
        return None

    for step in steps:
        if isinstance(step, dict) and str(step.get("status") or "").lower() == "in_progress":
            return step

    for step in steps:
        if isinstance(step, dict) and str(step.get("status") or "").lower() == "pending":
            return step
    return None


def _event_type(task: dict[str, Any]) -> str:
    status = str(task.get("status") or "active").lower()
    if status == "blocked":
        return "blocked"
    if status == "completed":
        return "completed"

    steps = task.get("steps")
    phase = str(task.get("phase") or "check").lower()
    if isinstance(steps, list) and steps:
        statuses = [
            str(step.get("status") or "").lower()
            for step in steps
            if isinstance(step, dict)
        ]
        if statuses and all(value == "pending" for value in statuses) and phase == "check":
            return "created"
    return "running"


def normalize_native_task(task: dict[str, Any]) -> dict[str, Any] | None:
    task_id = task.get("id")
    if not isinstance(task_id, str) or not task_id.startswith("tsk_"):
        return None

    current = _current_step(task)
    status = str(task.get("status") or "active").lower()
    phase = str(task.get("phase") or "check").lower()
    progress = _progress(task)

    blocker = str(task.get("blocker") or "").strip()
    summary = str(task.get("summary") or "").strip()
    current_title = ""
    if current is not None:
        current_title = str(current.get("title") or "").strip()

    if status == "blocked" and blocker:
        message = blocker
    elif current_title:
        message = current_title
    elif summary:
        message = summary
    else:
        message = f"AgentDock phase: {phase}"

    steps = task.get("steps")
    compact_steps: list[dict[str, Any]] = []
    if isinstance(steps, list):
        for step in steps[:12]:
            if not isinstance(step, dict):
                continue
            compact_steps.append(
                {
                    "id": step.get("id"),
                    "title": step.get("title"),
                    "phase": step.get("phase"),
                    "status": step.get("status"),
                    "updated_at": step.get("updated_at"),
                }
            )

    final_review = task.get("final_review")
    metadata: dict[str, Any] = {
        "native_agentdock_task": True,
        "native_status": status,
        "phase": phase,
        "project": task.get("project"),
        "device": task.get("device"),
        "updated_at": task.get("updated_at"),
        "completed_at": task.get("completed_at"),
        "steps": compact_steps,
    }
    if current is not None:
        metadata["current_step"] = {
            "id": current.get("id"),
            "title": current.get("title"),
            "phase": current.get("phase"),
            "status": current.get("status"),
        }
    if isinstance(final_review, dict):
        metadata["final_review"] = {
            "status": final_review.get("status"),
            "summary": final_review.get("summary"),
            "reviewed_at": final_review.get("reviewed_at"),
        }

    fingerprint = _state_fingerprint(task)
    event: dict[str, Any] = {
        "task_id": task_id,
        "event_type": _event_type(task),
        "source": "agentdock-native-task",
        "source_event_id": f"native-task:{task_id}:{fingerprint}",
        "title": str(task.get("title") or task_id),
        "progress": progress,
        "message": message,
        "metadata": metadata,
    }
    return event


def emit_task(client: BoardClient, task: dict[str, Any]) -> bool:
    normalized = normalize_native_task(task)
    if normalized is None:
        return False
    client.emit(
        task_id=normalized["task_id"],
        event_type=normalized["event_type"],
        source=normalized["source"],
        source_event_id=normalized["source_event_id"],
        title=normalized.get("title"),
        progress=normalized.get("progress"),
        message=normalized.get("message"),
        metadata=normalized.get("metadata"),
    )
    return True


def read_task_file(path: Path) -> dict[str, Any] | None:
    try:
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def sync_once(task_dir: Path, client: BoardClient) -> dict[str, int]:
    counts = {"emitted": 0, "skipped": 0}
    if not task_dir.exists():
        return counts
    for path in sorted(task_dir.glob("tsk_*.json")):
        task = read_task_file(path)
        if task is None:
            counts["skipped"] += 1
            continue
        if emit_task(client, task):
            counts["emitted"] += 1
        else:
            counts["skipped"] += 1
    return counts


def follow_tasks(task_dir: Path, client: BoardClient, *, interval: float = 0.75) -> None:
    fingerprints: dict[str, str] = {}
    while True:
        if task_dir.exists():
            for path in sorted(task_dir.glob("tsk_*.json")):
                task = read_task_file(path)
                if task is None:
                    continue
                fingerprint = _state_fingerprint(task)
                if fingerprints.get(path.name) == fingerprint:
                    continue
                emit_task(client, task)
                fingerprints[path.name] = fingerprint
        time.sleep(interval)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Bridge AgentDock native Task state files into Board 2.0"
    )
    parser.add_argument("--task-dir", required=True)
    parser.add_argument("--board-url", required=True)
    parser.add_argument("--interval", type=float, default=0.75)
    parser.add_argument("--once", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    task_dir = Path(args.task_dir)
    client = BoardClient(base_url=args.board_url)
    counts = sync_once(task_dir, client)
    print(json.dumps(counts, ensure_ascii=False))
    if not args.once:
        follow_tasks(task_dir, client, interval=max(0.2, args.interval))


if __name__ == "__main__":
    main()
