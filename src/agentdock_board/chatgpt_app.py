from __future__ import annotations

import os
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from .chatgpt_ui import TASKBOARD_APP_HTML
from .client import BoardClient

APP_RESOURCE_URI = "ui://agentdock-task-board/v2.html"
APP_MIME_TYPE = "text/html;profile=mcp-app"

READ_ONLY = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    openWorldHint=False,
)

RESOURCE_META: dict[str, Any] = {
    "ui": {"prefersBorder": True},
    "openai/widgetPrefersBorder": True,
}

OPEN_TOOL_META: dict[str, Any] = {
    "ui": {"resourceUri": APP_RESOURCE_URI},
    # Compatibility aliases used by older ChatGPT Apps SDK hosts.
    "openai/outputTemplate": APP_RESOURCE_URI,
    "openai/widgetAccessible": True,
    "openai/toolInvocation/invoking": "正在打开 AgentDock 任务看板…",
    "openai/toolInvocation/invoked": "AgentDock 任务看板已打开。",
}


def _http_settings() -> tuple[str, int, str]:
    host = os.getenv("AGENTDOCK_CHATGPT_MCP_HOST", "127.0.0.1")
    port = int(os.getenv("AGENTDOCK_CHATGPT_MCP_PORT", "8767"))
    path = os.getenv("AGENTDOCK_CHATGPT_MCP_PATH", "/mcp")
    if not path.startswith("/"):
        path = f"/{path}"
    return host, port, path


_MCP_HOST, _MCP_PORT, _MCP_PATH = _http_settings()

mcp = FastMCP(
    "AgentDock Task Board 2.0",
    instructions=(
        "Read live AgentDock task state. Use taskboard_open when the user asks to open, "
        "show, display, or view the task board. Use taskboard_snapshot for factual task "
        "status questions. This ChatGPT app surface is read-only."
    ),
    stateless_http=True,
    host=_MCP_HOST,
    port=_MCP_PORT,
    streamable_http_path=_MCP_PATH,
)
client = BoardClient()


def _snapshot(limit: int = 200) -> dict[str, Any]:
    limit = max(1, min(limit, 500))
    result = client.tasks(limit=limit)
    tasks = result.get("tasks") or []
    return {
        "last_sequence": int(result.get("last_sequence") or 0),
        "task_count": len(tasks),
        "tasks": tasks,
    }


@mcp.resource(
    APP_RESOURCE_URI,
    name="agentdock-task-board",
    title="AgentDock Task Board 2.0",
    description="Interactive read-only AgentDock task board rendered inside ChatGPT.",
    mime_type=APP_MIME_TYPE,
    meta=RESOURCE_META,
)
def taskboard_app_resource() -> str:
    return TASKBOARD_APP_HTML


@mcp.tool(
    name="taskboard_open",
    title="打开 AgentDock 任务看板",
    description=(
        "Open the live AgentDock Task Board 2.0 inline in ChatGPT. "
        "Use this when the user asks to open or show the task board."
    ),
    annotations=READ_ONLY,
    meta=OPEN_TOOL_META,
)
def taskboard_open(limit: int = 200) -> dict[str, Any]:
    return _snapshot(limit)


@mcp.tool(
    name="taskboard_snapshot",
    title="读取 AgentDock 任务状态",
    description=(
        "Read the current persisted AgentDock task snapshot for status, progress, owner, "
        "blockers, and latest step information."
    ),
    annotations=READ_ONLY,
)
def taskboard_snapshot(limit: int = 200) -> dict[str, Any]:
    return _snapshot(limit)


@mcp.tool(
    name="taskboard_changes",
    title="读取 AgentDock 任务变化",
    description="Read durable AgentDock task events newer than a sequence number.",
    annotations=READ_ONLY,
)
def taskboard_changes(after_sequence: int = 0, limit: int = 200) -> dict[str, Any]:
    after_sequence = max(0, after_sequence)
    limit = max(1, min(limit, 1000))
    return client.events(after_sequence=after_sequence, limit=limit)


def run_http() -> None:
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    run_http()
