from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any, Iterable

from .client import BoardClient

KNOWN_EVENTS = {
    "created",
    "assigned",
    "running",
    "progress",
    "blocked",
    "paused",
    "resumed",
    "retrying",
    "failed",
    "completed",
    "cancelled",
    "message",
}

STATUS_TO_EVENT = {
    "queued": "created",
    "pending": "created",
    "assigned": "assigned",
    "running": "running",
    "in_progress": "running",
    "progress": "progress",
    "blocked": "blocked",
    "paused": "paused",
    "resumed": "resumed",
    "retrying": "retrying",
    "failed": "failed",
    "error": "failed",
    "completed": "completed",
    "done": "completed",
    "success": "completed",
    "cancelled": "cancelled",
    "canceled": "cancelled",
}


def _pick(mapping: dict[str, Any], *names: str) -> Any:
    for name in names:
        value = mapping.get(name)
        if value is not None and value != "":
            return value
    return None


def _stable_id(prefix: str, value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, default=str)
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:32]
    return f"{prefix}:{digest}"


def _payload_view(item: dict[str, Any]) -> dict[str, Any]:
    payload = item.get("payload")
    if isinstance(payload, dict):
        merged = dict(payload)
        merged.update({k: v for k, v in item.items() if k != "payload"})
        return merged
    return item


def normalize_event(item: dict[str, Any]) -> dict[str, Any] | None:
    item = _payload_view(item)
    task_id = _pick(item, "task_id", "taskId", "task", "run_id", "runId")
    if isinstance(task_id, dict):
        task_id = _pick(task_id, "id", "task_id", "taskId")
    if not task_id:
        return None

    event_type = _pick(item, "type", "event_type", "eventType", "event", "status", "state")
    event_type = str(event_type or "message").strip().lower().replace("-", "_")
    if event_type not in KNOWN_EVENTS:
        event_type = STATUS_TO_EVENT.get(event_type, "message")

    source_event_id = _pick(
        item,
        "source_event_id",
        "sourceEventId",
        "event_id",
        "eventId",
        "sequence",
        "seq",
        "id",
    )
    if source_event_id is None:
        source_event_id = _stable_id("legacy-event", item)
    else:
        source_event_id = f"legacy-event:{source_event_id}"

    progress = _pick(item, "progress", "percent", "percentage")
    try:
        progress = float(progress) if progress is not None else None
    except (TypeError, ValueError):
        progress = None

    metadata = _pick(item, "metadata", "meta", "context")
    if not isinstance(metadata, dict):
        metadata = {}
    metadata = dict(metadata)
    metadata.setdefault("legacy_bridge", True)

    normalized: dict[str, Any] = {
        "task_id": str(task_id),
        "event_type": event_type,
        "source": "agentdock-legacy",
        "source_event_id": str(source_event_id),
        "metadata": metadata,
    }

    optional = {
        "title": _pick(item, "title", "name", "task_title", "taskTitle"),
        "owner": _pick(item, "owner", "assignee", "agent", "worker"),
        "progress": progress,
        "message": _pick(
            item,
            "message",
            "current_step",
            "currentStep",
            "detail",
            "reason",
            "block_reason",
            "blockReason",
        ),
    }
    normalized.update({key: value for key, value in optional.items() if value is not None})
    return normalized


def _iter_model_tasks(model: Any) -> Iterable[dict[str, Any]]:
    if isinstance(model, list):
        for item in model:
            if isinstance(item, dict):
                yield item
        return

    if not isinstance(model, dict):
        return

    tasks = model.get("tasks")
    if isinstance(tasks, list):
        for item in tasks:
            if isinstance(item, dict):
                yield item
        return

    if isinstance(tasks, dict):
        for key, item in tasks.items():
            if isinstance(item, dict):
                row = dict(item)
                row.setdefault("task_id", key)
                yield row
        return

    ignored = {"last_sequence", "sequence", "version", "updated_at", "updatedAt"}
    for key, item in model.items():
        if key in ignored or not isinstance(item, dict):
            continue
        row = dict(item)
        row.setdefault("task_id", key)
        yield row


def normalize_snapshot(item: dict[str, Any]) -> dict[str, Any] | None:
    task_id = _pick(item, "task_id", "taskId", "id")
    if not task_id:
        return None

    status = str(_pick(item, "status", "state") or "queued").strip().lower().replace("-", "_")
    event_type = STATUS_TO_EVENT.get(status, "message")
    progress = _pick(item, "progress", "percent", "percentage")
    try:
        progress = float(progress) if progress is not None else None
    except (TypeError, ValueError):
        progress = None

    marker = _pick(
        item,
        "last_sequence",
        "lastSequence",
        "sequence",
        "seq",
        "updated_at",
        "updatedAt",
    )
    if marker is None:
        marker = _stable_id("snapshot", item)

    metadata = _pick(item, "metadata", "meta", "context")
    if not isinstance(metadata, dict):
        metadata = {}
    metadata = dict(metadata)
    metadata.setdefault("legacy_snapshot", True)

    normalized: dict[str, Any] = {
        "task_id": str(task_id),
        "event_type": event_type,
        "source": "agentdock-legacy-model",
        "source_event_id": f"legacy-model:{task_id}:{marker}",
        "metadata": metadata,
    }
    optional = {
        "title": _pick(item, "title", "name"),
        "owner": _pick(item, "owner", "assignee", "agent", "worker"),
        "progress": progress,
        "message": _pick(item, "message", "current_step", "currentStep", "detail", "reason"),
    }
    normalized.update({key: value for key, value in optional.items() if value is not None})
    return normalized


def emit_normalized(client: BoardClient, event: dict[str, Any]) -> None:
    client.emit(
        task_id=event["task_id"],
        event_type=event["event_type"],
        source=event["source"],
        source_event_id=event["source_event_id"],
        title=event.get("title"),
        owner=event.get("owner"),
        progress=event.get("progress"),
        message=event.get("message"),
        metadata=event.get("metadata"),
    )


def migrate_existing(legacy_dir: Path, client: BoardClient) -> dict[str, int]:
    counts = {"events": 0, "snapshots": 0, "skipped": 0}
    events_path = legacy_dir / "task-events.jsonl"
    if events_path.exists():
        for raw in events_path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            if not raw.strip():
                continue
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                counts["skipped"] += 1
                continue
            if not isinstance(item, dict):
                counts["skipped"] += 1
                continue
            normalized = normalize_event(item)
            if normalized is None:
                counts["skipped"] += 1
                continue
            emit_normalized(client, normalized)
            counts["events"] += 1

    model_path = legacy_dir / "task-read-model.json"
    if model_path.exists():
        try:
            model = json.loads(model_path.read_text(encoding="utf-8-sig", errors="replace"))
        except json.JSONDecodeError:
            model = None
            counts["skipped"] += 1
        for item in _iter_model_tasks(model):
            normalized = normalize_snapshot(item)
            if normalized is None:
                counts["skipped"] += 1
                continue
            emit_normalized(client, normalized)
            counts["snapshots"] += 1
    return counts


def follow_events(
    legacy_dir: Path,
    client: BoardClient,
    *,
    interval: float = 0.75,
) -> None:
    path = legacy_dir / "task-events.jsonl"
    while not path.exists():
        time.sleep(interval)

    offset = path.stat().st_size
    while True:
        try:
            size = path.stat().st_size
            if size < offset:
                offset = 0
            if size > offset:
                with path.open("r", encoding="utf-8-sig", errors="replace") as handle:
                    handle.seek(offset)
                    while True:
                        line = handle.readline()
                        if not line:
                            break
                        offset = handle.tell()
                        try:
                            item = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(item, dict):
                            continue
                        normalized = normalize_event(item)
                        if normalized is not None:
                            emit_normalized(client, normalized)
            time.sleep(interval)
        except FileNotFoundError:
            offset = 0
            time.sleep(interval)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Bridge legacy AgentDock live-task-board into Board 2.0"
    )
    parser.add_argument("--legacy-dir", required=True)
    parser.add_argument("--board-url", default="http://127.0.0.1:8875")
    parser.add_argument("--interval", type=float, default=0.75)
    parser.add_argument("--once", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    legacy_dir = Path(args.legacy_dir)
    client = BoardClient(base_url=args.board_url)
    counts = migrate_existing(legacy_dir, client)
    print(json.dumps(counts, ensure_ascii=False))
    if not args.once:
        follow_events(legacy_dir, client, interval=max(0.2, args.interval))


if __name__ == "__main__":
    main()
