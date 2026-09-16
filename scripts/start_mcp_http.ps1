$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw 'Python launcher (py) not found. Install Python 3.11+ first.'
}

if (-not (Test-Path '.venv')) {
    py -3.11 -m venv .venv
}

$python = Join-Path $repo '.venv\Scripts\python.exe'
& $python -m pip install --upgrade pip
& $python -m pip install -e .

if (-not $env:AGENTDOCK_BOARD_URL) { $env:AGENTDOCK_BOARD_URL = 'http://127.0.0.1:8765' }
if (-not $env:AGENTDOCK_BOARD_MCP_HOST) { $env:AGENTDOCK_BOARD_MCP_HOST = '127.0.0.1' }
if (-not $env:AGENTDOCK_BOARD_MCP_PORT) { $env:AGENTDOCK_BOARD_MCP_PORT = '8766' }
if (-not $env:AGENTDOCK_BOARD_MCP_PATH) { $env:AGENTDOCK_BOARD_MCP_PATH = '/mcp' }

$mcp = Join-Path $repo '.venv\Scripts\agentdock-board-mcp-http.exe'
Write-Host "Task Board MCP starting on http://$($env:AGENTDOCK_BOARD_MCP_HOST):$($env:AGENTDOCK_BOARD_MCP_PORT)$($env:AGENTDOCK_BOARD_MCP_PATH)"
& $mcp
