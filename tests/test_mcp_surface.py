from agentdock_board import mcp_server


def test_mcp_surface_is_available() -> None:
    assert callable(mcp_server.taskboard_health)
    assert callable(mcp_server.taskboard_get)
    assert callable(mcp_server.taskboard_sync)
    assert callable(mcp_server.taskboard_request_action)
    assert callable(mcp_server.run_http)


def test_http_mcp_uses_configured_transport(monkeypatch) -> None:
    calls = {}

    monkeypatch.setenv("AGENTDOCK_BOARD_MCP_HOST", "127.0.0.1")
    monkeypatch.setenv("AGENTDOCK_BOARD_MCP_PORT", "9876")
    monkeypatch.setenv("AGENTDOCK_BOARD_MCP_PATH", "taskboard")
    monkeypatch.setattr(mcp_server.mcp, "run", lambda **kwargs: calls.update(kwargs))

    mcp_server.run_http()

    assert calls == {
        "transport": "streamable-http",
        "host": "127.0.0.1",
        "port": 9876,
        "streamable_http_path": "/taskboard",
    }
