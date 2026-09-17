param(
    [int]$PreferredPort = 8875,
    [int]$ChatGPTMcpPort = 8767
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/jimwoocory/Agentdock-board.git"
$StateRoot = Join-Path $env:USERPROFILE ".agentdock"
$LegacyDir = Join-Path $StateRoot "live-task-board"
$RuntimeRoot = Join-Path $StateRoot "services\agentdock-board-v2"
$BackupRoot = Join-Path $StateRoot "backups"
$SkillStateDir = Join-Path $StateRoot "skill-store\state"
$V2StateFile = Join-Path $SkillStateDir "live-task-board-v2.json"
$ConfigFile = Join-Path $LegacyDir "board-v2-local.json"
$OldStandalone = Join-Path $env:LOCALAPPDATA "Agentdock-board"
$DbPath = Join-Path $LegacyDir "taskboard-v2.db"

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
        if (-not ((Test-Path $command) -or (Get-Command $command -ErrorAction SilentlyContinue))) {
            continue
        }
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
    Write-Host "[Company Bootstrap] Installing Python 3.12 for current user..."
    & winget install --id Python.Python.3.12 --exact --scope user --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "Python 3.12 installation failed." }
    $python312 = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"
    if (-not (Test-Path $python312)) { throw "Python 3.12 was installed but python.exe was not found." }
    return [PSCustomObject]@{ Command = $python312; PrefixArgs = @() }
}

function Test-PortListening([int]$Port) {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $listener)
}

function Test-BoardHealthy([string]$BoardUrl) {
    try {
        $health = Invoke-RestMethod -Uri "$($BoardUrl.TrimEnd('/'))/api/health" -TimeoutSec 3
        return ($health.ok -eq $true)
    } catch {
        return $false
    }
}

function Stop-RecordedProcess([string]$PidFile, [string]$CommandPattern) {
    if (-not (Test-Path $PidFile)) { return }
    $raw = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
    $processId = 0
    if (-not [int]::TryParse($raw, [ref]$processId)) { return }
    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $proc) {
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        return
    }
    try {
        $win32 = Get-CimInstance Win32_Process -Filter "ProcessId=$processId"
        $commandLine = [string]$win32.CommandLine
        if ($commandLine -match $CommandPattern) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
            Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Resolve-TaskDir {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $StateRoot "tasks"))
    $candidates.Add((Join-Path $env:LOCALAPPDATA "AgentDock\tasks"))
    $candidates.Add((Join-Path $env:APPDATA "AgentDock\tasks"))

    try {
        $agentdockProcs = Get-CimInstance Win32_Process -Filter "Name='agentdock.exe'"
        foreach ($proc in $agentdockProcs) {
            $line = [string]$proc.CommandLine
            if ($line -match '--runtime-root\s+(?:"([^"]+)"|([^\s]+))') {
                $root = if ($matches[1]) { $matches[1] } else { $matches[2] }
                if ($root) { $candidates.Add((Join-Path $root "tasks")) }
            }
        }
    } catch {}

    $unique = @($candidates | Select-Object -Unique)
    foreach ($candidate in $unique) {
        if ((Test-Path $candidate) -and (Get-ChildItem $candidate -Filter "tsk_*.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            return $candidate
        }
    }
    foreach ($candidate in $unique) {
        if (Test-Path $candidate) { return $candidate }
    }
    $fallback = Join-Path $StateRoot "tasks"
    New-Item -ItemType Directory -Force -Path $fallback | Out-Null
    return $fallback
}

function Resolve-FreePort([int]$Preferred) {
    if (-not (Test-PortListening $Preferred)) { return $Preferred }
    foreach ($port in 8876..8899) {
        if (-not (Test-PortListening $port)) { return $port }
    }
    throw "No free Board 2.0 port was found."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows was not found."
}

New-Item -ItemType Directory -Force -Path $LegacyDir, $BackupRoot, $SkillStateDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $BackupRoot "company-board-bootstrap-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

foreach ($path in @($ConfigFile, $DbPath, $V2StateFile)) {
    if (Test-Path $path) {
        Copy-Item $path (Join-Path $backup (Split-Path $path -Leaf)) -Force
    }
}
$oldDb = Join-Path $OldStandalone "data\taskboard.db"
if (Test-Path $oldDb) {
    Copy-Item $oldDb (Join-Path $backup "old-standalone-taskboard.db") -Force
}

if (Test-Path (Join-Path $RuntimeRoot ".git")) {
    Write-Host "[Company Bootstrap] Updating canonical Board 2.0 runtime..."
    & git -C $RuntimeRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull failed." }
} else {
    Write-Host "[Company Bootstrap] Creating canonical Board 2.0 runtime..."
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $RuntimeRoot) | Out-Null
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
    $args = @($launcher.PrefixArgs) + @("-m", "venv", $venv)
    & $launcher.Command @args
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPython)) {
        throw "Virtual environment creation failed."
    }
}

Write-Host "[Company Bootstrap] Installing/updating Board 2.0 package..."
& $venvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed." }
& $venvPython -m pip install -e $RuntimeRoot
if ($LASTEXITCODE -ne 0) { throw "Board 2.0 package install failed." }

if ((-not (Test-Path $DbPath)) -and (Test-Path $oldDb)) {
    Write-Host "[Company Bootstrap] Importing the old standalone database as the V2 starting database..."
    Copy-Item $oldDb $DbPath -Force
}

$boardUrl = $null
if (Test-Path $ConfigFile) {
    try {
        $existing = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($existing.board_url -and (Test-BoardHealthy ([string]$existing.board_url))) {
            $boardUrl = [string]$existing.board_url
        }
    } catch {}
}

if (-not $boardUrl) {
    Stop-RecordedProcess (Join-Path $LegacyDir "board-v2.pid") "agentdock_board\.main"
    $port = Resolve-FreePort $PreferredPort
    $boardUrl = "http://127.0.0.1:$port"
    $env:AGENTDOCK_BOARD_HOST = "127.0.0.1"
    $env:AGENTDOCK_BOARD_PORT = [string]$port
    $env:AGENTDOCK_BOARD_DB = $DbPath
    $env:AGENTDOCK_BOARD_URL = $boardUrl
    $stdout = Join-Path $LegacyDir "board-v2.out.log"
    $stderr = Join-Path $LegacyDir "board-v2.err.log"
    Write-Host "[Company Bootstrap] Starting Board 2.0 on $boardUrl ..."
    $proc = Start-Process -FilePath $venvPython `
        -ArgumentList "-m", "agentdock_board.main" `
        -WorkingDirectory $RuntimeRoot `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru
    Set-Content (Join-Path $LegacyDir "board-v2.pid") $proc.Id -Encoding ascii
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-BoardHealthy $boardUrl) { $ready = $true; break }
        if ($proc.HasExited) { break }
    }
    if (-not $ready) {
        $tail = ""
        if (Test-Path $stderr) { $tail = (Get-Content $stderr -Tail 30 -ErrorAction SilentlyContinue) -join "`n" }
        throw "Board 2.0 did not become healthy at $boardUrl.`n$tail"
    }
}

$port = [int](([Uri]$boardUrl).Port)
$config = [ordered]@{
    version = "2.0"
    mode = "company-canonical"
    board_url = $boardUrl
    port = $port
    database = $DbPath
    legacy_dir = $LegacyDir
    runtime = $RuntimeRoot
    backup = $backup
    upgraded_at = (Get-Date).ToString("o")
}
$config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding utf8
$config | ConvertTo-Json -Depth 5 | Set-Content $V2StateFile -Encoding utf8

$legacyEventFile = Join-Path $LegacyDir "task-events.jsonl"
$legacyReadModel = Join-Path $LegacyDir "task-read-model.json"
if ((Test-Path $legacyEventFile) -or (Test-Path $legacyReadModel)) {
    Write-Host "[Company Bootstrap] Importing legacy board events/read model..."
    & $venvPython -m agentdock_board.legacy_bridge --legacy-dir $LegacyDir --board-url $boardUrl --once
    if ($LASTEXITCODE -ne 0) { throw "Legacy bridge import failed." }
    Stop-RecordedProcess (Join-Path $LegacyDir "board-v2-bridge.pid") "agentdock_board\.legacy_bridge"
    $legacyProc = Start-Process -FilePath $venvPython `
        -ArgumentList "-m", "agentdock_board.legacy_bridge", "--legacy-dir", $LegacyDir, "--board-url", $boardUrl `
        -WorkingDirectory $RuntimeRoot `
        -WindowStyle Hidden `
        -PassThru
    Set-Content (Join-Path $LegacyDir "board-v2-bridge.pid") $legacyProc.Id -Encoding ascii
}

$taskDir = Resolve-TaskDir
Write-Host "[Company Bootstrap] AgentDock task directory: $taskDir"
Stop-RecordedProcess (Join-Path $LegacyDir "board-v2-native.pid") "agentdock_board\.native_task_bridge"
& $venvPython -m agentdock_board.native_task_bridge --task-dir $taskDir --board-url $boardUrl --once
if ($LASTEXITCODE -ne 0) { throw "Native AgentDock task import failed." }
$nativeProc = Start-Process -FilePath $venvPython `
    -ArgumentList "-m", "agentdock_board.native_task_bridge", "--task-dir", $taskDir, "--board-url", $boardUrl `
    -WorkingDirectory $RuntimeRoot `
    -WindowStyle Hidden `
    -PassThru
Set-Content (Join-Path $LegacyDir "board-v2-native.pid") $nativeProc.Id -Encoding ascii

$state = Get-Content $V2StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
$stateHash = [ordered]@{}
foreach ($p in $state.PSObject.Properties) { $stateHash[$p.Name] = $p.Value }
$stateHash["native_bridge"] = "agentdock-task-state"
$stateHash["native_task_dir"] = $taskDir
$stateHash["native_bridge_pid"] = $nativeProc.Id
$stateHash | ConvertTo-Json -Depth 6 | Set-Content $V2StateFile -Encoding utf8

$chatgptLauncher = Join-Path $RuntimeRoot "scripts\start_chatgpt_app.ps1"
if (-not (Test-Path $chatgptLauncher)) { throw "ChatGPT App launcher is missing: $chatgptLauncher" }
Write-Host "[Company Bootstrap] Starting ChatGPT App MCP..."
& $chatgptLauncher -Port $ChatGPTMcpPort -Path "/mcp"
if ($LASTEXITCODE -ne 0) { throw "ChatGPT App MCP launcher failed." }
if (-not (Test-PortListening $ChatGPTMcpPort)) {
    throw "ChatGPT App MCP is not listening on port $ChatGPTMcpPort."
}

$health = Invoke-RestMethod -Uri "$boardUrl/api/health" -TimeoutSec 3
$tasks = Invoke-RestMethod -Uri "$boardUrl/api/tasks?limit=500" -TimeoutSec 3
$nativeCount = 0
foreach ($task in $tasks.tasks) {
    if ($task.metadata.native_agentdock_task -eq $true) { $nativeCount++ }
}

Write-Host ""
Write-Host "[Company Bootstrap] READY" -ForegroundColor Green
Write-Host "Board:        $boardUrl"
Write-Host "ChatGPT MCP:  http://127.0.0.1:$ChatGPTMcpPort/mcp"
Write-Host "Task dir:     $taskDir"
Write-Host "seq:          $($health.last_sequence)"
Write-Host "tasks:        $($health.task_count)"
Write-Host "native tasks: $nativeCount"
Write-Host "Backup:       $backup"
Write-Host ""
if (Test-Path $OldStandalone) {
    Write-Host "Old standalone install was left untouched: $OldStandalone"
}
Write-Host "Next: create a separate Secure MCP Tunnel for this company computer."
