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

function Test-PythonCandidate {
    param(
        [string]$Command,
        [string[]]$PrefixArgs = @()
    )

    try {
        $args = @()
        $args += $PrefixArgs
        $args += @(
            "-c",
            "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 7)"
        )
        & $Command @args *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Resolve-PythonLauncher {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        if (Test-PythonCandidate -Command "py" -PrefixArgs @("-3")) {
            return [PSCustomObject]@{
                Command = "py"
                PrefixArgs = @("-3")
            }
        }
    }

    if (Get-Command python -ErrorAction SilentlyContinue) {
        if (Test-PythonCandidate -Command "python") {
            return [PSCustomObject]@{
                Command = "python"
                PrefixArgs = @()
            }
        }
    }

    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        if (Test-PythonCandidate -Command "python3") {
            return [PSCustomObject]@{
                Command = "python3"
                PrefixArgs = @()
            }
        }
    }

    return $null
}

function Install-PythonIfNeeded {
    $launcher = Resolve-PythonLauncher
    if ($launcher) {
        return $launcher
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "No usable Python 3.11+ was found, and winget is unavailable. Install Python 3.12+ and retry."
    }

    Write-Host "[AgentDock Board] Python 3.11+ not found. Installing Python 3.12..."
    & winget install --id Python.Python.3.12 -e --scope user `
        --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "Python 3.12 installation failed with exit code $LASTEXITCODE."
    }

    $paths = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:ProgramFiles "Python312\python.exe")
    )
    foreach ($path in $paths) {
        if ((Test-Path $path) -and (Test-PythonCandidate -Command $path)) {
            return [PSCustomObject]@{
                Command = $path
                PrefixArgs = @()
            }
        }
    }

    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "Machine")
    $launcher = Resolve-PythonLauncher
    if ($launcher) {
        return $launcher
    }

    throw "Python 3.12 was installed but could not be resolved. Close this window and rerun the installer."
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
    if ($LASTEXITCODE -ne 0) {
        throw "git pull failed with exit code $LASTEXITCODE."
    }
} elseif (Test-Path $InstallRoot) {
    $items = Get-ChildItem -Force $InstallRoot -ErrorAction SilentlyContinue
    if ($items.Count -gt 0) {
        throw "Install root exists and is not an Agentdock-board git checkout: $InstallRoot"
    }
    & git clone $RepoUrl $InstallRoot
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed with exit code $LASTEXITCODE."
    }
} else {
    $parent = Split-Path -Parent $InstallRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    & git clone $RepoUrl $InstallRoot
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed with exit code $LASTEXITCODE."
    }
}

$pythonLauncher = Install-PythonIfNeeded
Write-Host "[AgentDock Board] Python launcher: $($pythonLauncher.Command) $($pythonLauncher.PrefixArgs -join ' ')"

$venv = Join-Path $InstallRoot ".venv"
$python = Join-Path $venv "Scripts\python.exe"
if ((Test-Path $venv) -and -not (Test-Path $python)) {
    Write-Host "[AgentDock Board] Removing incomplete virtual environment..."
    Remove-Item -Recurse -Force $venv
}

if (-not (Test-Path $python)) {
    Write-Host "[AgentDock Board] Creating Python virtual environment..."
    $pythonCommand = $pythonLauncher.Command
    $venvArgs = @()
    $venvArgs += $pythonLauncher.PrefixArgs
    $venvArgs += @("-m", "venv", $venv)
    & $pythonCommand @venvArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Python virtual environment creation failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path $python)) {
    throw "Virtual environment Python was not created: $python"
}

Write-Host "[AgentDock Board] Installing/updating local package..."
& $python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) {
    throw "pip upgrade failed with exit code $LASTEXITCODE."
}
& $python -m pip install -e $InstallRoot
if ($LASTEXITCODE -ne 0) {
    throw "AgentDock Board package install failed with exit code $LASTEXITCODE."
}

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
