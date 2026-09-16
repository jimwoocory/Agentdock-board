from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TERMINAL_STATUSES = {"completed", "failed", "cancelled"}
STATUS_BY_EVENT = {
    "created": "queued",
    "assigned": "queued",
    "running": "running",
    "resumed": "running",
    "blocked": "blocked",
    "completed": "completed",
    "failed": "failed",
    "cancelled": "cancelled",
    "paused": "paused",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, db_path: str | Path) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def _init_db(self) -> None:
        with self._lock, self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    source TEXT NOT NULL,
                    source_event_id TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    UNIQUE(source, source_event_id)
                );

                CREATE INDEX IF NOT EXISTS idx_events_task_sequence
                    ON events(task_id, sequence);

                CREATE TABLE IF NOT EXISTS tasks (
                    task_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'queued',
                    owner TEXT NOT NULL DEFAULT '',
                    progress REAL NOT NULL DEFAULT 0,
                    message TEXT NOT NULL DEFAULT '',
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    last_sequence INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_tasks_updated_at
                    ON tasks(updated_at DESC);

                CREATE TABLE IF NOT EXISTS actions (
                    action_id TEXT PRIMARY KEY,
                    task_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    payload_json TEXT NOT NULL DEFAULT '{}',
                    status TEXT NOT NULL DEFAULT 'pending',
                    consumer TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    acked_at TEXT,
                    result_json TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_actions_status_created
                    ON actions(status, created_at);
                """
            )

    @staticmethod
    def _task_row(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if row is None:
            return None
        result = dict(row)
        result["metadata"] = json.loads(result.pop("metadata_json") or "{}")
        return result

    @staticmethod
    def _action_row(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if row is None:
            return None
        result = dict(row)
        result["payload"] = json.loads(result.pop("payload_json") or "{}")
        result["result"] = (
            json.loads(result.pop("result_json")) if result.get("result_json") else None
        )
        result.pop("result_json", None)
        return result

    def append_event(self, event: dict[str, Any]) -> dict[str, Any]:
        source = str(event.get("source") or "agentdock")
        source_event_id = str(event.get("source_event_id") or uuid.uuid4())
        task_id = str(event["task_id"])
        event_type = str(event["type"])
        created_at = str(event.get("occurred_at") or utc_now())
        payload = dict(event)
        payload["source"] = source
        payload["source_event_id"] = source_event_id
        payload["occurred_at"] = created_at

        with self._lock, self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                cursor = conn.execute(
                    """
                    INSERT OR IGNORE INTO events
                        (source, source_event_id, task_id, type, payload_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        source,
                        source_event_id,
                        task_id,
                        event_type,
                        json.dumps(payload, ensure_ascii=False),
                        created_at,
                    ),
                )

                duplicate = cursor.rowcount == 0
                if duplicate:
                    row = conn.execute(
                        "SELECT sequence FROM events WHERE source=? AND source_event_id=?",
                        (source, source_event_id),
                    ).fetchone()
                    sequence = int(row["sequence"])
                else:
                    sequence = int(cursor.lastrowid)
                    self._apply_projection(conn, sequence, payload)

                task = self._task_row(
                    conn.execute("SELECT * FROM tasks WHERE task_id=?", (task_id,)).fetchone()
                )
                conn.commit()
                return {
                    "sequence": sequence,
                    "duplicate": duplicate,
                    "task": task,
                }
            except Exception:
                conn.rollback()
                raise

    def _apply_projection(
        self,
        conn: sqlite3.Connection,
        sequence: int,
        event: dict[str, Any],
    ) -> None:
        task_id = str(event["task_id"])
        current_row = conn.execute(
            "SELECT * FROM tasks WHERE task_id=?", (task_id,)
        ).fetchone()
        current = self._task_row(current_row)

        if current and sequence <= int(current["last_sequence"]):
            return

        event_type = str(event["type"])
        now = str(event.get("occurred_at") or utc_now())
        title = str(event.get("title") or (current or {}).get("title") or task_id)
        owner = str(event.get("owner") or (current or {}).get("owner") or "")
        message = str(event.get("message") or (current or {}).get("message") or "")

        current_status = str((current or {}).get("status") or "queued")
        status = STATUS_BY_EVENT.get(event_type, current_status)

        if current_status in TERMINAL_STATUSES and event_type not in {"message"}:
            status = current_status

        progress_value = event.get("progress")
        if progress_value is None:
            progress = float((current or {}).get("progress") or 0)
        else:
            progress = max(0.0, min(100.0, float(progress_value)))

        if event_type == "completed":
            progress = 100.0

        metadata = dict((current or {}).get("metadata") or {})
        incoming_metadata = event.get("metadata") or {}
        if isinstance(incoming_metadata, dict):
            metadata.update(incoming_metadata)

        created_at = str((current or {}).get("created_at") or now)

        conn.execute(
            """
            INSERT INTO tasks (
                task_id, title, status, owner, progress, message,
                metadata_json, last_sequence, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(task_id) DO UPDATE SET
                title=excluded.title,
                status=excluded.status,
                owner=excluded.owner,
                progress=excluded.progress,
                message=excluded.message,
                metadata_json=excluded.metadata_json,
                last_sequence=excluded.last_sequence,
                updated_at=excluded.updated_at
            """,
            (
                task_id,
                title,
                status,
                owner,
                progress,
                message,
                json.dumps(metadata, ensure_ascii=False),
                sequence,
                created_at,
                now,
            ),
        )

    def list_tasks(self, limit: int = 200) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM tasks ORDER BY updated_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [self._task_row(row) for row in rows if row is not None]

    def get_task(self, task_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM tasks WHERE task_id=?", (task_id,)).fetchone()
        return self._task_row(row)

    def list_events(self, after_sequence: int = 0, limit: int = 500) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT sequence, source, source_event_id, task_id, type, payload_json, created_at
                FROM events
                WHERE sequence > ?
                ORDER BY sequence ASC
                LIMIT ?
                """,
                (after_sequence, limit),
            ).fetchall()

        events: list[dict[str, Any]] = []
        for row in rows:
            item = dict(row)
            item["payload"] = json.loads(item.pop("payload_json") or "{}")
            events.append(item)
        return events

    def latest_sequence(self) -> int:
        with self._connect() as conn:
            row = conn.execute("SELECT COALESCE(MAX(sequence), 0) AS value FROM events").fetchone()
        return int(row["value"])

    def create_action(
        self,
        task_id: str,
        action: str,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        action_id = f"act_{uuid.uuid4().hex}"
        created_at = utc_now()
        with self._lock, self._connect() as conn:
            conn.execute(
                """
                INSERT INTO actions
                    (action_id, task_id, action, payload_json, status, created_at)
                VALUES (?, ?, ?, ?, 'pending', ?)
                """,
                (
                    action_id,
                    task_id,
                    action,
                    json.dumps(payload or {}, ensure_ascii=False),
                    created_at,
                ),
            )
            row = conn.execute(
                "SELECT * FROM actions WHERE action_id=?", (action_id,)
            ).fetchone()
        return self._action_row(row)

    def pending_actions(
        self,
        consumer: str = "agentdock",
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rows = conn.execute(
                    """
                    SELECT * FROM actions
                    WHERE status='pending' AND (consumer='' OR consumer=?)
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                    (consumer, limit),
                ).fetchall()
                ids = [row["action_id"] for row in rows]
                if ids:
                    placeholders = ",".join("?" for _ in ids)
                    conn.execute(
                        f"UPDATE actions SET status='claimed', consumer=? "
                        f"WHERE action_id IN ({placeholders})",
                        (consumer, *ids),
                    )
                    rows = conn.execute(
                        f"SELECT * FROM actions WHERE action_id IN ({placeholders}) "
                        "ORDER BY created_at ASC",
                        ids,
                    ).fetchall()
                conn.commit()
            except Exception:
                conn.rollback()
                raise
        return [self._action_row(row) for row in rows if row is not None]

    def ack_action(
        self,
        action_id: str,
        ok: bool,
        result: dict[str, Any] | None = None,
    ) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            status = "done" if ok else "failed"
            conn.execute(
                """
                UPDATE actions
                SET status=?, acked_at=?, result_json=?
                WHERE action_id=?
                """,
                (
                    status,
                    utc_now(),
                    json.dumps(result or {}, ensure_ascii=False),
                    action_id,
                ),
            )
            row = conn.execute(
                "SELECT * FROM actions WHERE action_id=?", (action_id,)
            ).fetchone()
        return self._action_row(row)
