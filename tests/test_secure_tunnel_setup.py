from pathlib import Path


def test_secure_tunnel_setup_uses_full_windows_client() -> None:
    script = Path("scripts/setup_secure_mcp_tunnel.ps1").read_text(encoding="utf-8")

    assert "^tunnel-client-v.+-windows-amd64\\.zip$" in script
    assert "^tunnel-client-runtime-v.+-windows-amd64\\.zip$" not in script
    assert 'Filter "tunnel-client.exe"' in script
    assert 'full-client' in script
