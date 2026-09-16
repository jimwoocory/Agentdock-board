from agentdock_board import mcp_server


def test_mcp_surface_is_available() -> None:
    assert callable(mcp_server.taskboard_health)
    assert callable(mcp_server.taskboard_get)
    assert callable(mcp_server.taskboard_sync)
    assert callable(mcp_server.taskboard_request_action)
