from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from . import __version__
from .store import Store

DB_PATH = os.getenv("AGENTDOCK_BOARD_DB", "./data/taskboard.db")
store = Store(DB_PATH)
app = FastAPI(title="AgentDock Task Board 2.0", version=__version__)


class EventIn(BaseModel):
    task_id: str = Field(min_length=1)
    type: str = Field(min_length=1)
    source: str = "agentdock"
    source_event_id: str | None = None
    occurred_at: str | None = None
    title: str | None = None
    owner: str | None = None
    progress: float | None = Field(default=None, ge=0, le=100)
    message: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class ActionIn(BaseModel):
    action: str = Field(min_length=1)
    payload: dict[str, Any] = Field(default_factory=dict)


class ActionAckIn(BaseModel):
    ok: bool = True
    result: dict[str, Any] = Field(default_factory=dict)


class SocketHub:
    def __init__(self) -> None:
        self._clients: set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._clients.add(websocket)

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(websocket)

    async def broadcast(self, payload: dict[str, Any]) -> None:
        async with self._lock:
            clients = list(self._clients)
        stale: list[WebSocket] = []
        for client in clients:
            try:
                await client.send_json(payload)
            except Exception:
                stale.append(client)
        if stale:
            async with self._lock:
                for client in stale:
                    self._clients.discard(client)


hub = SocketHub()
STATIC_INDEX = Path(__file__).with_name("static") / "index.html"


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    return HTMLResponse(STATIC_INDEX.read_text(encoding="utf-8"))


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "version": __version__,
        "last_sequence": store.latest_sequence(),
        "task_count": len(store.list_tasks(limit=10000)),
    }


@app.post("/api/events")
async def ingest_event(event: EventIn) -> dict[str, Any]:
    payload = event.model_dump(exclude_none=True)
    result = store.append_event(payload)
    if not result["duplicate"]:
        await hub.broadcast(
            {
                "kind": "task_event",
                "sequence": result["sequence"],
                "event": payload,
                "task": result["task"],
            }
        )
    return result


@app.get("/api/tasks")
def list_tasks(limit: int = Query(default=200, ge=1, le=2000)) -> dict[str, Any]:
    return {
        "last_sequence": store.latest_sequence(),
        "tasks": store.list_tasks(limit=limit),
    }


@app.get("/api/tasks/{task_id}")
def get_task(task_id: str) -> dict[str, Any]:
    task = store.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="task not found")
    return task


@app.get("/api/events")
def list_events(
    after_sequence: int = Query(default=0, ge=0),
    limit: int = Query(default=500, ge=1, le=5000),
) -> dict[str, Any]:
    events = store.list_events(after_sequence=after_sequence, limit=limit)
    return {
        "last_sequence": store.latest_sequence(),
        "events": events,
    }


@app.post("/api/tasks/{task_id}/actions")
async def create_action(task_id: str, body: ActionIn) -> dict[str, Any]:
    if not store.get_task(task_id):
        raise HTTPException(status_code=404, detail="task not found")
    action = store.create_action(task_id, body.action, body.payload)
    await hub.broadcast({"kind": "action_created", "action": action})
    return action


@app.get("/api/actions/pending")
def pending_actions(
    consumer: str = Query(default="agentdock", min_length=1),
    limit: int = Query(default=50, ge=1, le=500),
    lease_seconds: int = Query(default=30, ge=5, le=3600),
) -> dict[str, Any]:
    return {
        "actions": store.pending_actions(
            consumer=consumer,
            limit=limit,
            lease_seconds=lease_seconds,
        )
    }


@app.post("/api/actions/{action_id}/ack")
async def ack_action(action_id: str, body: ActionAckIn) -> dict[str, Any]:
    action = store.ack_action(action_id, body.ok, body.result)
    if not action:
        raise HTTPException(status_code=404, detail="action not found")
    await hub.broadcast({"kind": "action_acked", "action": action})
    return action


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await hub.connect(websocket)
    try:
        await websocket.send_json(
            {
                "kind": "snapshot",
                "last_sequence": store.latest_sequence(),
                "tasks": store.list_tasks(),
            }
        )
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        await hub.disconnect(websocket)
    except Exception:
        await hub.disconnect(websocket)


def run() -> None:
    host = os.getenv("AGENTDOCK_BOARD_HOST", "127.0.0.1")
    port = int(os.getenv("AGENTDOCK_BOARD_PORT", "8765"))
    uvicorn.run("agentdock_board.main:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    run()
