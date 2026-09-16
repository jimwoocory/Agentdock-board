param(
    [string]$InstallRoot = "",
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/jimwoocory/Agentdock-board.git"

function Resolve-AgentDockHome {
    if ($env:AGENTDOCK_HOME -and (Test-Path $env:AGENTDOCK_HOME)) {
        return (Resolve-Path $env:AGENTDOCK_HOME).Path
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "AgentDock"),
        (Join-Path $env:APPDATA "AgentDock"),
        (Join-Path $env:USERPROFILE ".agentdock"),
        "C:\AgentDock",
        "D:\AgentDock"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Resolve-PythonLauncher {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        return @("py", "-3.11")
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return @("python")
    }
    throw "Python 3.11+ was not found. Install Python first, then run this installer again."
}

$agentDockHome = Resolve-AgentDockHome
if (-not $InstallRoot) {
    if ($agentDockHome) {
        $InstallRoot = Join-Path $agentDockHome "services\Agentdock-board"
    } else {
        $InstallRoot = Join-Path $env:LOCALAPPDATA "Agentdock-board"
    }
}

Write-Host "[AgentDock Board] Local install root: $InstallRoot"
if ($agentDockHome) {
    Write-Host "[AgentDock Board] AgentDock home detected: $agentDockHome"
} else {
    Write-Host "[AgentDock Board] AgentDock home was not auto-detected; using standalone local sidecar mode."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found. Install Git for Windows first."
}

if (Test-Path (Join-Path $InstallRoot ".git")) {
    Write-Host "[AgentDock Board] Updating existing checkout..."
    & git -C $InstallRoot pull --ff-only
} elseif (Test-Path $InstallRoot) {
    $items = Get-ChildItem -Force $InstallRoot -ErrorAction SilentlyContinue
    if ($items.Count -gt 0) {
        throw "Install root exists and is not an Agentdock-board git checkout: $InstallRoot"
    }
    & git clone $RepoUrl $InstallRoot
} else {
    $parent = Split-Path -Parent $InstallRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    & git clone $RepoUrl $InstallRoot
}

$pythonLauncher = Resolve-PythonLauncher
$venv = Join-Path $InstallRoot ".venv"
if (-not (Test-Path $venv)) {
    Write-Host "[AgentDock Board] Creating Python virtual environment..."
    if ($pythonLauncher.Count -eq 2) {
        & $pythonLauncher[0] $pythonLauncher[1] -m venv $venv
    } else {
        & $pythonLauncher[0] -m venv $venv
    }
}

$python = Join-Path $venv "Scripts\python.exe"
Write-Host "[AgentDock Board] Installing/updating local package..."
& $python -m pip install --upgrade pip
& $python -m pip install -e $InstallRoot

$dataDir = Join-Path $InstallRoot "data"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$env:AGENTDOCK_BOARD_HOST = "127.0.0.1"
$env:AGENTDOCK_BOARD_PORT = "8765"
$env:AGENTDOCK_BOARD_DB = Join-Path $dataDir "taskboard.db"
$env:AGENTDOCK_BOARD_URL = "http://127.0.0.1:8765"

$healthUrl = "$($env:AGENTDOCK_BOARD_URL)/api/health"
$alreadyRunning = $false
try {
    $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
    if ($health.ok -eq $true) {
        $alreadyRunning = $true
    }
} catch {
    $alreadyRunning = $false
}

if (-not $alreadyRunning) {
    Write-Host "[AgentDock Board] Starting local board service..."
    $proc = Start-Process -FilePath $python `
        -ArgumentList "-m", "agentdock_board.main" `
        -WorkingDirectory $InstallRoot `
        -PassThru
    Set-Content -Path (Join-Path $dataDir "board.pid") -Value $proc.Id -Encoding ascii

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
            if ($health.ok -eq $true) {
                $ready = $true
                break
            }
        } catch {
            # Keep waiting until the service becomes healthy.
        }
    }
    if (-not $ready) {
        throw "Board service did not become healthy at $healthUrl"
    }
} else {
    Write-Host "[AgentDock Board] Local board service is already running."
}

$config = [ordered]@{
    mode = "local"
    board_url = $env:AGENTDOCK_BOARD_URL
    health_url = $healthUrl
    database = $env:AGENTDOCK_BOARD_DB
    install_root = $InstallRoot
    agentdock_home = $agentDockHome
}
$config | ConvertTo-Json -Depth 4 | Set-Content `
    -Path (Join-Path $dataDir "local-mode.json") `
    -Encoding utf8

$health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
Write-Host ""
Write-Host "[AgentDock Board] LOCAL MODE READY" -ForegroundColor Green
Write-Host "Board:  http://127.0.0.1:8765"
Write-Host "Health: $healthUrl"
Write-Host "DB:     $($env:AGENTDOCK_BOARD_DB)"
Write-Host "seq:    $($health.last_sequence)"
Write-Host "tasks:  $($health.task_count)"

if (-not $NoOpen) {
    Start-Process "http://127.0.0.1:8765"
}
