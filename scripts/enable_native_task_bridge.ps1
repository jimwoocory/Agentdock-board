param(
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$StateRoot = Join-Path $env:USERPROFILE ".agentdock"
$TaskDir = Join-Path $StateRoot "tasks"
$LegacyDir = Join-Path $StateRoot "live-task-board"
$ConfigPath = Join-Path $LegacyDir "board-v2-local.json"
$StateFile = Join-Path $StateRoot "skill-store\state\live-task-board-v2.json"

if (-not (Test-Path $ConfigPath)) {
    throw "Board 2.0 local config was not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$boardUrl = [string]$config.board_url
$runtime = [string]$config.runtime
if (-not $boardUrl) {
    throw "board_url is missing from $ConfigPath"
}
if (-not $runtime) {
    $runtime = Join-Path $StateRoot "services\agentdock-board-v2"
}

if (-not (Test-Path (Join-Path $runtime ".git"))) {
    throw "Board 2.0 runtime checkout was not found: $runtime"
}
if (-not (Test-Path $TaskDir)) {
    New-Item -ItemType Directory -Force -Path $TaskDir | Out-Null
}

$venvPython = Join-Path $runtime ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    throw "Board 2.0 virtual environment Python was not found: $venvPython"
}

Write-Host "[Native Bridge] Updating Board 2.0 runtime..."
& git -C $runtime pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw "git pull failed."
}

Write-Host "[Native Bridge] Updating editable package..."
& $venvPython -m pip install -e $runtime
if ($LASTEXITCODE -ne 0) {
    throw "Board 2.0 package update failed."
}

$healthUrl = "$boardUrl/api/health"
try {
    $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
} catch {
    throw "Board 2.0 is not reachable at $healthUrl"
}
if ($health.ok -ne $true) {
    throw "Board 2.0 health check failed at $healthUrl"
}

$pidFile = Join-Path $LegacyDir "board-v2-native.pid"
if (Test-Path $pidFile) {
    $oldPid = 0
    try { $oldPid = [int](Get-Content $pidFile -Raw) } catch {}
    if ($oldPid -gt 0) {
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc) {
            Write-Host "[Native Bridge] Restarting existing native bridge PID $oldPid ..."
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
        }
    }
}

Write-Host "[Native Bridge] Importing current AgentDock native tasks..."
$syncOutput = & $venvPython -m agentdock_board.native_task_bridge `
    --task-dir $TaskDir `
    --board-url $boardUrl `
    --once
if ($LASTEXITCODE -ne 0) {
    throw "Native task import failed."
}
Write-Host ("[Native Bridge] Import: " + ($syncOutput -join " "))

Write-Host "[Native Bridge] Starting continuous native task watcher..."
$proc = Start-Process -FilePath $venvPython `
    -ArgumentList "-m", "agentdock_board.native_task_bridge", "--task-dir", $TaskDir, "--board-url", $boardUrl `
    -WorkingDirectory $runtime `
    -WindowStyle Hidden `
    -PassThru
Set-Content -Path $pidFile -Value $proc.Id -Encoding ascii

$state = [ordered]@{}
if (Test-Path $StateFile) {
    try {
        $existing = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $existing.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
    } catch {}
}
$state["native_bridge"] = "agentdock-task-state"
$state["native_task_dir"] = $TaskDir
$state["native_bridge_pid"] = $proc.Id
$state["native_bridge_enabled_at"] = (Get-Date).ToString("o")
$state | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8

$health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
$tasksResponse = Invoke-RestMethod -Uri "$boardUrl/api/tasks?limit=200" -TimeoutSec 3
$nativeCount = 0
foreach ($task in $tasksResponse.tasks) {
    if ($task.metadata.native_agentdock_task -eq $true) {
        $nativeCount++
    }
}

Write-Host ""
Write-Host "[Native Bridge] READY" -ForegroundColor Green
Write-Host "Board:        $boardUrl"
Write-Host "Task dir:     $TaskDir"
Write-Host "Bridge PID:   $($proc.Id)"
Write-Host "seq:          $($health.last_sequence)"
Write-Host "tasks:        $($health.task_count)"
Write-Host "native tasks: $nativeCount"
Write-Host ""
Write-Host "New AgentDock task_manage updates will now project into Board 2.0."

if (-not $NoOpen) {
    Start-Process $boardUrl
}
