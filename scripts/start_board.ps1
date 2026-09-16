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

if (-not $env:AGENTDOCK_BOARD_HOST) { $env:AGENTDOCK_BOARD_HOST = '127.0.0.1' }
if (-not $env:AGENTDOCK_BOARD_PORT) { $env:AGENTDOCK_BOARD_PORT = '8765' }
if (-not $env:AGENTDOCK_BOARD_DB) { $env:AGENTDOCK_BOARD_DB = (Join-Path $repo 'data\taskboard.db') }

Write-Host "AgentDock Task Board 2.0 starting on http://$($env:AGENTDOCK_BOARD_HOST):$($env:AGENTDOCK_BOARD_PORT)"
& $python -m agentdock_board.main
