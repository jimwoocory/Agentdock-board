param(
    [int]$Port = 8767,
    [string]$Path = "/mcp"
)

$ErrorActionPreference = "Stop"
$StateRoot = Join-Path $env:USERPROFILE ".agentdock"
$LegacyDir = Join-Path $StateRoot "live-task-board"
$RuntimeRoot = Join-Path $StateRoot "services\agentdock-board-v2"
$VenvPython = Join-Path $RuntimeRoot ".venv\Scripts\python.exe"
$PidFile = Join-Path $LegacyDir "chatgpt-app-mcp.pid"
$ConfigFile = Join-Path $LegacyDir "chatgpt-app-local.json"
$BoardConfigFile = Join-Path $LegacyDir "board-v2-local.json"
$StdoutLog = Join-Path $LegacyDir "chatgpt-app-mcp.out.log"
$StderrLog = Join-Path $LegacyDir "chatgpt-app-mcp.err.log"

function Test-PortListening([int]$TargetPort) {
    $listener = Get-NetTCPConnection `
        -LocalAddress "127.0.0.1" `
        -LocalPort $TargetPort `
        -State Listen `
        -ErrorAction SilentlyContinue
    return ($null -ne $listener)
}

function Stop-RecordedProcess {
    if (-not (Test-Path $PidFile)) { return }
    $rawPid = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
    $processId = 0
    if (-not [int]::TryParse($rawPid, [ref]$processId)) { return }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($process) {
        try {
            $win32 = Get-CimInstance Win32_Process -Filter "ProcessId=$processId"
            $commandLine = [string]$win32.CommandLine
            if ($commandLine -match "agentdock_board\.chatgpt_app") {
                Write-Host "[ChatGPT App] Stopping previous MCP process PID $processId ..."
                Stop-Process -Id $processId -Force
                Start-Sleep -Milliseconds 500
            }
        } catch {}
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $RuntimeRoot ".git"))) {
    throw "Board 2.0 runtime was not found: $RuntimeRoot"
}
if (-not (Test-Path $VenvPython)) {
    throw "Board 2.0 virtual environment was not found: $VenvPython"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows was not found."
}

Write-Host "[ChatGPT App] Updating Board 2.0 runtime..."
& git -C $RuntimeRoot pull --ff-only
if ($LASTEXITCODE -ne 0) { throw "git pull failed." }

Write-Host "[ChatGPT App] Installing/updating package..."
& $VenvPython -m pip install -e $RuntimeRoot
if ($LASTEXITCODE -ne 0) { throw "Board 2.0 package update failed." }

$boardUrl = "http://127.0.0.1:8875"
if (Test-Path $BoardConfigFile) {
    try {
        $boardConfig = Get-Content $BoardConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($boardConfig.board_url) {
            $boardUrl = [string]$boardConfig.board_url
        }
    } catch {}
}
$boardUrl = $boardUrl.TrimEnd("/")
$healthUrl = "$boardUrl/api/health"
try {
    $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 4
    if ($health.ok -ne $true) {
        throw "Board health response was not healthy."
    }
} catch {
    throw "Board 2.0 is not healthy at $healthUrl. Start the Board/Native Bridge first. $($_.Exception.Message)"
}

if (-not $Path.StartsWith("/")) { $Path = "/$Path" }
if ((Test-PortListening $Port) -and -not (Test-Path $PidFile)) {
    throw "Port $Port is already in use by another process."
}

Stop-RecordedProcess
if (Test-PortListening $Port) {
    throw "Port $Port is still in use after stopping the recorded ChatGPT App process."
}

$env:AGENTDOCK_BOARD_URL = $boardUrl
$env:AGENTDOCK_CHATGPT_MCP_HOST = "127.0.0.1"
$env:AGENTDOCK_CHATGPT_MCP_PORT = [string]$Port
$env:AGENTDOCK_CHATGPT_MCP_PATH = $Path

Write-Host "[ChatGPT App] Starting local MCP at http://127.0.0.1:$Port$Path ..."
$process = Start-Process `
    -FilePath $VenvPython `
    -ArgumentList "-m", "agentdock_board.chatgpt_app" `
    -WorkingDirectory $RuntimeRoot `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -WindowStyle Hidden `
    -PassThru
Set-Content -Path $PidFile -Value $process.Id -Encoding ascii

$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) { break }
    if (Test-PortListening $Port) {
        $ready = $true
        break
    }
}

if (-not $ready) {
    $errorTail = ""
    if (Test-Path $StderrLog) {
        $errorTail = (Get-Content $StderrLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n"
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    throw "ChatGPT App MCP did not start on port $Port.`n$errorTail"
}

$config = [ordered]@{
    version = "2.0"
    mode = "chatgpt-app-local"
    board_url = $boardUrl
    local_mcp_url = "http://127.0.0.1:$Port$Path"
    pid = $process.Id
    runtime = $RuntimeRoot
    started_at = (Get-Date).ToString("o")
}
$config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigFile -Encoding utf8

Write-Host ""
Write-Host "[ChatGPT App] LOCAL MCP READY" -ForegroundColor Green
Write-Host "Board:     $boardUrl"
Write-Host "Local MCP: http://127.0.0.1:$Port$Path"
Write-Host "PID:       $($process.Id)"
Write-Host "Tasks:     $($health.task_count)"
Write-Host "Seq:       $($health.last_sequence)"
Write-Host "Config:    $ConfigFile"
Write-Host ""
Write-Host "Next: connect this local MCP to ChatGPT through Secure MCP Tunnel."
