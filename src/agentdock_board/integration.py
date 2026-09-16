from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any

from .client import BoardClient


class TaskReporter:
    """Small drop-in adapter for AgentDock/Harness task lifecycle hooks."""

    def __init__(
        self,
        task_id: str,
        *,
        title: str | None = None,
        owner: str | None = None,
        source: str = "agentdock",
        client: BoardClient | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.task_id = task_id
        self.title = title
        self.owner = owner
        self.source = source
        self.client = client or BoardClient()
        self.metadata = metadata or {}

    def emit(
        self,
        event_type: str,
        *,
        progress: float | None = None,
        message: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        merged_metadata = dict(self.metadata)
        if metadata:
            merged_metadata.update(metadata)
        return self.client.emit(
            task_id=self.task_id,
            event_type=event_type,
            source=self.source,
            title=self.title,
            owner=self.owner,
            progress=progress,
            message=message,
            metadata=merged_metadata,
        )

    def created(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("created", progress=0, message=message)

    def assigned(self, owner: str | None = None, message: str | None = None) -> dict[str, Any]:
        if owner is not None:
            self.owner = owner
        return self.emit("assigned", message=message)

    def running(
        self,
        *,
        progress: float | None = None,
        message: str | None = None,
    ) -> dict[str, Any]:
        return self.emit("running", progress=progress, message=message)

    def progress(self, value: float, message: str | None = None) -> dict[str, Any]:
        return self.emit("running", progress=value, message=message)

    def blocked(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("blocked", message=message)

    def paused(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("paused", message=message)

    def resumed(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("resumed", message=message)

    def retrying(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("retrying", message=message)

    def completed(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("completed", progress=100, message=message)

    def failed(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("failed", message=message)

    def cancelled(self, message: str | None = None) -> dict[str, Any]:
        return self.emit("cancelled", message=message)


ActionHandler = Callable[[dict[str, Any]], dict[str, Any] | None]


class ActionWorker:
    """Polls board actions and hands them to AgentDock with crash-safe leases."""

    def __init__(
        self,
        handler: ActionHandler,
        *,
        client: BoardClient | None = None,
        consumer: str = "agentdock",
        poll_interval: float = 1.0,
        lease_seconds: int = 30,
        batch_size: int = 20,
    ) -> None:
        self.handler = handler
        self.client = client or BoardClient()
        self.consumer = consumer
        self.poll_interval = max(0.2, poll_interval)
        self.lease_seconds = max(5, lease_seconds)
        self.batch_size = max(1, batch_size)
        self._stop = threading.Event()

    def run_once(self) -> int:
        count = 0
        for _action in self.client.consume_actions(
            self.handler,
            consumer=self.consumer,
            limit=self.batch_size,
            lease_seconds=self.lease_seconds,
        ):
            count += 1
        return count

    def run_forever(self) -> None:
        while not self._stop.is_set():
            try:
                processed = self.run_once()
            except Exception:
                processed = 0
            if processed == 0:
                self._stop.wait(self.poll_interval)

    def stop(self) -> None:
        self._stop.set()

    def start_daemon(self, name: str = "agentdock-board-actions") -> threading.Thread:
        thread = threading.Thread(target=self.run_forever, name=name, daemon=True)
        thread.start()
        return thread


def wait_for_board(
    client: BoardClient | None = None,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> bool:
    board = client or BoardClient()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if board.health().get("ok") is True:
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False
