# Task Board 2.0 — Streamable HTTP MCP

Task Board 2.0 can expose the same persisted task state to an MCP host over Streamable HTTP.

## Local topology

```text
AgentDock task engine
  |  events/actions
  v
Task Board service        http://127.0.0.1:8765
  |
  | BoardClient
  v
Task Board MCP            http://127.0.0.1:8766/mcp
  |
  v
MCP host that can reach this endpoint
```

The browser board, REST API, WebSocket, and MCP tools all read the same SQLite-backed task model. MCP does not generate simulated state.

## Windows startup

Start the board first:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_board.ps1
```

Then start the MCP endpoint:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start_mcp_http.ps1
```

Default MCP URL:

```text
http://127.0.0.1:8766/mcp
```

## Environment variables

```text
AGENTDOCK_BOARD_URL=http://127.0.0.1:8765
AGENTDOCK_BOARD_MCP_HOST=127.0.0.1
AGENTDOCK_BOARD_MCP_PORT=8766
AGENTDOCK_BOARD_MCP_PATH=/mcp
```

## Exposed tools

- `taskboard_health`
- `taskboard_get`
- `taskboard_sync`
- `taskboard_request_action`

`taskboard_request_action` accepts only `pause`, `resume`, `retry`, and `cancel`.

## Security boundary

Keep the default `127.0.0.1` binding for local use. If a remote MCP host must reach the endpoint, expose it only through the existing trusted AgentDock/MCP/VPN access layer and add authentication at that boundary. Do not publish the unauthenticated local endpoint directly to the public Internet.
