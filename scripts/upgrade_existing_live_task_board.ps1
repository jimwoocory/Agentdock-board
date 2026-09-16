param(
    [int]$PreferredPort = 8875,
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/jimwoocory/Agentdock-board.git"
$StateRoot = Join-Path $env:USERPROFILE ".agentdock"
$LegacyDir = Join-Path $StateRoot "live-task-board"
$RuntimeRoot = Join-Path $StateRoot "services\agentdock-board-v2"
$BackupRoot = Join-Path $StateRoot "backups"
$EnvFile = Join-Path $StateRoot "env\mcp\live-task-board.env"
$SkillStateDir = Join-Path $StateRoot "skill-store\state"
$V2StateFile = Join-Path $SkillStateDir "live-task-board-v2.json"

function Resolve-Python {
    $candidates = @(
        @{ Command = "py"; Args = @("-3.12") },
        @{ Command = "py"; Args = @("-3") },
        @{ Command = "python"; Args = @() },
        @{ Command = "python3"; Args = @() },
        @{ Command = (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"); Args = @() }
    )

    foreach ($candidate in $candidates) {
        $command = $candidate.Command
        $available = $false
        if (Test-Path $command) {
            $available = $true
        } elseif (Get-Command $command -ErrorAction SilentlyContinue) {
            $available = $true
        }
        if (-not $available) { continue }

        try {
            & $command @($candidate.Args) -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)" *> $null
            if ($LASTEXITCODE -eq 0) {
                return [PSCustomObject]@{ Command = $command; PrefixArgs = @($candidate.Args) }
            }
        } catch {}
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Python 3.11+ was not found and winget is unavailable."
    }

    Write-Host "[Board 2.0] Installing Python 3.12 for current user..."
    & winget install --id Python.Python.3.12 --exact --scope user --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Python 3.12 installation failed with exit code $LASTEXITCODE."
    }

    $python312 = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"
    if (-not (Test-Path $python312)) {
        throw "Python 3.12 was installed but python.exe was not found at $python312"
    }
    return [PSCustomObject]@{ Command = $python312; PrefixArgs = @() }
}

function Test-PortFree([int]$Port) {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return (-not $listener)
}

function Resolve-BoardPort([int]$Preferred) {
    $configPath = Join-Path $LegacyDir "board-v2-local.json"
    if (Test-Path $configPath) {
        try {
            $existing = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing.port -and (Test-PortFree ([int]$existing.port))) {
                return [int]$existing.port
            }
        } catch {}
    }

    foreach ($port in @($Preferred) + (8876..8899)) {
        if (Test-PortFree $port) { return $port }
    }
    throw "No free local port was found for Board 2.0."
}

function Set-EnvLine([string]$Path, [string]$Key, [string]$Value) {
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lines = @()
    if (Test-Path $Path) {
        $lines = @(Get-Content $Path -ErrorAction SilentlyContinue)
    }
    $pattern = "^" + [Regex]::Escape($Key) + "="
    $replaced = $false
    $out = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $replaced = $true
            "$Key=$Value"
        } else {
            $line
        }
    }
    if (-not $replaced) { $out += "$Key=$Value" }
    $out | Set-Content -Path $Path -Encoding utf8
}

if (-not (Test-Path $LegacyDir)) {
    throw "Existing AgentDock live-task-board data was not found: $LegacyDir"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows was not found."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
$backup = Join-Path $BackupRoot "live-task-board-before-v2-$stamp"
Write-Host "[Board 2.0] Backing up legacy live-task-board -> $backup"
Copy-Item -Path $LegacyDir -Destination $backup -Recurse -Force
if (Test-Path $EnvFile) {
    Copy-Item $EnvFile (Join-Path $backup "live-task-board.env.backup") -Force
}

$legacySkillState = Join-Path $SkillStateDir "live-task-board.json"
if (Test-Path $legacySkillState) {
    Copy-Item $legacySkillState (Join-Path $backup "live-task-board.skill-state.backup.json") -Force
}

if (Test-Path (Join-Path $RuntimeRoot ".git")) {
    Write-Host "[Board 2.0] Updating V2 runtime..."
    & git -C $RuntimeRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull failed." }
} else {
    Write-Host "[Board 2.0] Installing V2 runtime..."
    $parent = Split-Path -Parent $RuntimeRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    & git clone $RepoUrl $RuntimeRoot
    if ($LASTEXITCODE -ne 0) { throw "git clone failed." }
}

$launcher = Resolve-Python
$venv = Join-Path $RuntimeRoot ".venv"
$venvPython = Join-Path $venv "Scripts\python.exe"
if ((Test-Path $venv) -and -not (Test-Path $venvPython)) {
    Remove-Item $venv -Recurse -Force
}
if (-not (Test-Path $venvPython)) {
    Write-Host "[Board 2.0] Creating virtual environment..."
    $pythonCommand = $launcher.Command
    $venvArgs = @($launcher.PrefixArgs) + @("-m", "venv", $venv)
    & $pythonCommand @venvArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPython)) {
        throw "Virtual environment creation failed."
    }
}

Write-Host "[Board 2.0] Installing/updating package..."
& $venvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed." }
& $venvPython -m pip install -e $RuntimeRoot
if ($LASTEXITCODE -ne 0) { throw "Board 2.0 package install failed." }

$port = Resolve-BoardPort $PreferredPort
$boardUrl = "http://127.0.0.1:$port"
$dbPath = Join-Path $LegacyDir "taskboard-v2.db"
$env:AGENTDOCK_BOARD_HOST = "127.0.0.1"
$env:AGENTDOCK_BOARD_PORT = [string]$port
$env:AGENTDOCK_BOARD_DB = $dbPath
$env:AGENTDOCK_BOARD_URL = $boardUrl

Write-Host "[Board 2.0] Starting V2 board on $boardUrl ..."
$boardProcess = Start-Process -FilePath $venvPython `
    -ArgumentList "-m", "agentdock_board.main" `
    -WorkingDirectory $RuntimeRoot `
    -WindowStyle Hidden `
    -PassThru
Set-Content -Path (Join-Path $LegacyDir "board-v2.pid") -Value $boardProcess.Id -Encoding ascii

$healthUrl = "$boardUrl/api/health"
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
        if ($health.ok -eq $true) { $ready = $true; break }
    } catch {}
}
if (-not $ready) {
    throw "Board 2.0 did not become healthy at $healthUrl"
}

Write-Host "[Board 2.0] Migrating legacy events and read model..."
$migrationOutput = & $venvPython -m agentdock_board.legacy_bridge `
    --legacy-dir $LegacyDir `
    --board-url $boardUrl `
    --once
if ($LASTEXITCODE -ne 0) { throw "Legacy migration failed." }
Write-Host ("[Board 2.0] Migration: " + ($migrationOutput -join " "))

Write-Host "[Board 2.0] Starting continuous legacy event bridge..."
$bridgeProcess = Start-Process -FilePath $venvPython `
    -ArgumentList "-m", "agentdock_board.legacy_bridge", "--legacy-dir", $LegacyDir, "--board-url", $boardUrl `
    -WorkingDirectory $RuntimeRoot `
    -WindowStyle Hidden `
    -PassThru
Set-Content -Path (Join-Path $LegacyDir "board-v2-bridge.pid") -Value $bridgeProcess.Id -Encoding ascii

Set-EnvLine $EnvFile "AGENTDOCK_BOARD_V2_URL" $boardUrl
Set-EnvLine $EnvFile "AGENTDOCK_BOARD_V2_DB" $dbPath
Set-EnvLine $EnvFile "AGENTDOCK_BOARD_V2_RUNTIME" $RuntimeRoot
Set-EnvLine $EnvFile "AGENTDOCK_BOARD_V2_BRIDGE" "legacy-jsonl"

New-Item -ItemType Directory -Force -Path $SkillStateDir | Out-Null
$v2State = [ordered]@{
    version = "2.0"
    mode = "legacy-bridge"
    board_url = $boardUrl
    port = $port
    database = $dbPath
    legacy_dir = $LegacyDir
    runtime = $RuntimeRoot
    backup = $backup
    upgraded_at = (Get-Date).ToString("o")
}
$v2State | ConvertTo-Json -Depth 4 | Set-Content -Path $V2StateFile -Encoding utf8
$v2State | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $LegacyDir "board-v2-local.json") -Encoding utf8

$health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
Write-Host ""
Write-Host "[Board 2.0] UPGRADE READY" -ForegroundColor Green
Write-Host "Board:  $boardUrl"
Write-Host "Health: $healthUrl"
Write-Host "DB:     $dbPath"
Write-Host "seq:    $($health.last_sequence)"
Write-Host "tasks:  $($health.task_count)"
Write-Host "Backup: $backup"
Write-Host ""
Write-Host "Legacy AgentDock task events remain untouched and continue feeding Board 2.0."

if (-not $NoOpen) {
    Start-Process $boardUrl
}
