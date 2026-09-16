from __future__ import annotations

import os
from typing import Any

from mcp.server.fastmcp import FastMCP

from .client import BoardClient

mcp = FastMCP("AgentDock Task Board 2.0")
client = BoardClient()


@mcp.tool()
def taskboard_health() -> dict[str, Any]:
    """Return Task Board 2.0 health, task count, and latest event sequence."""
    return client.health()


@mcp.tool()
def taskboard_get(limit: int = 200) -> dict[str, Any]:
    """Return the current persisted task read model."""
    limit = max(1, min(limit, 2000))
    return client.tasks(limit=limit)


@mcp.tool()
def taskboard_sync(after_sequence: int = 0, limit: int = 500) -> dict[str, Any]:
    """Return durable task events newer than a sequence number."""
    after_sequence = max(0, after_sequence)
    limit = max(1, min(limit, 5000))
    return client.events(after_sequence=after_sequence, limit=limit)


@mcp.tool()
def taskboard_request_action(
    task_id: str,
    action: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Queue a durable task action for AgentDock to execute and ACK."""
    allowed = {"pause", "resume", "retry", "cancel"}
    if action not in allowed:
        raise ValueError(f"unsupported action: {action}; allowed={sorted(allowed)}")
    return client.request_action(task_id, action, payload or {"requested_from": "mcp"})


def run() -> None:
    """Run the local stdio MCP server."""
    mcp.run()


def run_http() -> None:
    """Run MCP over Streamable HTTP for an AgentDock/Developer-MCP host."""
    host = os.getenv("AGENTDOCK_BOARD_MCP_HOST", "127.0.0.1")
    port = int(os.getenv("AGENTDOCK_BOARD_MCP_PORT", "8766"))
    path = os.getenv("AGENTDOCK_BOARD_MCP_PATH", "/mcp")
    if not path.startswith("/"):
        path = f"/{path}"
    mcp.run(
        transport="streamable-http",
        host=host,
        port=port,
        streamable_http_path=path,
    )


if __name__ == "__main__":
    run()
