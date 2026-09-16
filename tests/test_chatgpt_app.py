from agentdock_board import chatgpt_app


def test_chatgpt_app_surface_is_available() -> None:
    assert chatgpt_app.APP_RESOURCE_URI.startswith("ui://")
    assert chatgpt_app.APP_MIME_TYPE == "text/html;profile=mcp-app"
    assert callable(chatgpt_app.taskboard_open)
    assert callable(chatgpt_app.taskboard_snapshot)
    assert callable(chatgpt_app.taskboard_changes)
    assert callable(chatgpt_app.run_http)


def test_chatgpt_widget_contains_board_and_refresh_bridge() -> None:
    html = chatgpt_app.taskboard_app_resource()
    assert "AgentDock Task Board 2.0" in html
    assert "taskboard_snapshot" in html
    assert "window.openai.callTool" in html
    assert "ui/notifications/tool-result" in html


def test_snapshot_normalizes_board_payload(monkeypatch) -> None:
    monkeypatch.setattr(
        chatgpt_app.client,
        "tasks",
        lambda limit=200: {
            "last_sequence": 9,
            "tasks": [{"task_id": "tsk_demo", "title": "Demo", "status": "running"}],
        },
    )

    result = chatgpt_app.taskboard_snapshot(limit=25)

    assert result["last_sequence"] == 9
    assert result["task_count"] == 1
    assert result["tasks"][0]["task_id"] == "tsk_demo"


def test_chatgpt_http_uses_configured_transport(monkeypatch) -> None:
    calls = {}
    monkeypatch.setenv("AGENTDOCK_CHATGPT_MCP_HOST", "127.0.0.1")
    monkeypatch.setenv("AGENTDOCK_CHATGPT_MCP_PORT", "9988")
    monkeypatch.setenv("AGENTDOCK_CHATGPT_MCP_PATH", "chatgpt")
    monkeypatch.setattr(chatgpt_app.mcp, "run", lambda **kwargs: calls.update(kwargs))

    chatgpt_app.run_http()

    assert calls == {
        "transport": "streamable-http",
        "host": "127.0.0.1",
        "port": 9988,
        "streamable_http_path": "/chatgpt",
    }
