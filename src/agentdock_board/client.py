from __future__ import annotations

import os
import uuid
from collections.abc import Callable, Iterable
from typing import Any

import httpx


ActionHandler = Callable[[dict[str, Any]], dict[str, Any] | None]


class BoardClient:
    def __init__(self, base_url: str | None = None, timeout: float = 5.0) -> None:
        self.base_url = (
            base_url
            or os.getenv("AGENTDOCK_BOARD_URL")
            or "http://127.0.0.1:8765"
        ).rstrip("/")
        self.timeout = timeout

    def health(self) -> dict[str, Any]:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.get(f"{self.base_url}/api/health")
            response.raise_for_status()
            return response.json()

    def tasks(self, *, limit: int = 200) -> dict[str, Any]:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.get(
                f"{self.base_url}/api/tasks",
                params={"limit": limit},
            )
            response.raise_for_status()
            return response.json()

    def events(self, *, after_sequence: int = 0, limit: int = 500) -> dict[str, Any]:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.get(
                f"{self.base_url}/api/events",
                params={"after_sequence": after_sequence, "limit": limit},
            )
            response.raise_for_status()
            return response.json()

    def request_action(
        self,
        task_id: str,
        action: str,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.post(
                f"{self.base_url}/api/tasks/{task_id}/actions",
                json={"action": action, "payload": payload or {}},
            )
            response.raise_for_status()
            return response.json()

    def emit(
        self,
        *,
        task_id: str,
        event_type: str,
        source: str = "agentdock",
        source_event_id: str | None = None,
        title: str | None = None,
        owner: str | None = None,
        progress: float | None = None,
        message: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "task_id": task_id,
            "type": event_type,
            "source": source,
            "source_event_id": source_event_id or str(uuid.uuid4()),
            "metadata": metadata or {},
        }
        optional = {
            "title": title,
            "owner": owner,
            "progress": progress,
            "message": message,
        }
        payload.update({key: value for key, value in optional.items() if value is not None})
        with httpx.Client(timeout=self.timeout) as client:
            response = client.post(f"{self.base_url}/api/events", json=payload)
            response.raise_for_status()
            return response.json()

    def pending_actions(
        self,
        *,
        consumer: str = "agentdock",
        limit: int = 50,
        lease_seconds: int = 30,
    ) -> list[dict[str, Any]]:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.get(
                f"{self.base_url}/api/actions/pending",
                params={
                    "consumer": consumer,
                    "limit": limit,
                    "lease_seconds": lease_seconds,
                },
            )
            response.raise_for_status()
            return response.json()["actions"]

    def ack_action(
        self,
        action_id: str,
        *,
        ok: bool = True,
        result: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.post(
                f"{self.base_url}/api/actions/{action_id}/ack",
                json={"ok": ok, "result": result or {}},
            )
            response.raise_for_status()
            return response.json()

    def consume_actions(
        self,
        handler: ActionHandler,
        *,
        consumer: str = "agentdock",
        limit: int = 50,
        lease_seconds: int = 30,
    ) -> Iterable[dict[str, Any]]:
        actions = self.pending_actions(
            consumer=consumer,
            limit=limit,
            lease_seconds=lease_seconds,
        )
        for action in actions:
            try:
                result = handler(action)
                if result is None:
                    result = {}
                self.ack_action(action["action_id"], ok=True, result=result)
            except Exception as exc:
                self.ack_action(
                    action["action_id"],
                    ok=False,
                    result={"error": str(exc)},
                )
            yield action
