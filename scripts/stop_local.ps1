param(
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $InstallRoot) {
    $candidates = @()
    if ($env:AGENTDOCK_HOME) {
        $candidates += (Join-Path $env:AGENTDOCK_HOME "services\Agentdock-board")
    }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA "AgentDock\services\Agentdock-board"),
        (Join-Path $env:APPDATA "AgentDock\services\Agentdock-board"),
        (Join-Path $env:USERPROFILE ".agentdock\services\Agentdock-board"),
        (Join-Path $env:LOCALAPPDATA "Agentdock-board")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $InstallRoot = $candidate
            break
        }
    }
}

if (-not $InstallRoot) {
    throw "Agentdock-board local install was not found. Pass -InstallRoot explicitly."
}

$pidFile = Join-Path $InstallRoot "data\board.pid"
if (-not (Test-Path $pidFile)) {
    Write-Host "No board.pid found; the local board may already be stopped."
    exit 0
}

$boardPid = (Get-Content $pidFile -Raw).Trim()
if ($boardPid -match "^\d+$") {
    $proc = Get-Process -Id ([int]$boardPid) -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id ([int]$boardPid) -Force
        Write-Host "AgentDock Task Board stopped (PID $boardPid)."
    } else {
        Write-Host "PID $boardPid is not running."
    }
}

Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
