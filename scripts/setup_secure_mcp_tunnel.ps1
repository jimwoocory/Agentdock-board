param(
    [string]$McpServerUrl = "http://127.0.0.1:8767/mcp"
)

$ErrorActionPreference = "Stop"

$StateRoot = Join-Path $env:USERPROFILE ".agentdock"
$InstallRoot = Join-Path $StateRoot "tunnel-client"
$DownloadDir = Join-Path $InstallRoot "downloads"
$ExtractRoot = Join-Path $InstallRoot "current"
$RunStateDir = Join-Path $StateRoot "live-task-board"
$ConfigFile = Join-Path $RunStateDir "secure-mcp-tunnel.json"
$StdoutLog = Join-Path $RunStateDir "secure-mcp-tunnel.out.log"
$StderrLog = Join-Path $RunStateDir "secure-mcp-tunnel.err.log"
$PidFile = Join-Path $RunStateDir "secure-mcp-tunnel.pid"

New-Item -ItemType Directory -Force -Path $InstallRoot, $DownloadDir, $RunStateDir | Out-Null

function Test-LocalPort([int]$Port) {
    try {
        $connection = Get-NetTCPConnection `
            -LocalAddress "127.0.0.1" `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction Stop
        return ($null -ne $connection)
    } catch {
        return $false
    }
}

function Convert-SecureStringToPlainText([Security.SecureString]$SecureValue) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

Write-Host ""
Write-Host "AgentDock Task Board 2.0 - Secure MCP Tunnel" -ForegroundColor Cyan
Write-Host "Local MCP: $McpServerUrl"
Write-Host ""

$uri = [Uri]$McpServerUrl
if ($uri.Host -ne "127.0.0.1" -and $uri.Host -ne "localhost") {
    throw "This setup script only accepts a loopback MCP server URL."
}
if (-not (Test-LocalPort $uri.Port)) {
    throw "Local ChatGPT App MCP is not listening on $($uri.Host):$($uri.Port). Start Start-AgentDock-ChatGPT-App-SAFE.cmd first."
}

Write-Host "[1/6] Fetching latest official OpenAI tunnel-client release..."
$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/openai/tunnel-client/releases/latest" `
    -Headers @{ "User-Agent" = "AgentDock-Board-2.0" }

$asset = $release.assets | Where-Object {
    $_.name -match '^tunnel-client-runtime-v.+-windows-amd64\.zip$'
} | Select-Object -First 1

if (-not $asset) {
    throw "Could not find the Windows amd64 tunnel-client runtime ZIP in the latest OpenAI release."
}

$version = [string]$release.tag_name
$zipPath = Join-Path $DownloadDir $asset.name
$versionMarker = Join-Path $ExtractRoot ".version"
$currentVersion = ""
if (Test-Path $versionMarker) {
    $currentVersion = (Get-Content $versionMarker -Raw -ErrorAction SilentlyContinue).Trim()
}

if ($currentVersion -ne $version -or -not (Test-Path $ExtractRoot)) {
    Write-Host "[2/6] Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    if (Test-Path $ExtractRoot) {
        Remove-Item $ExtractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $ExtractRoot -Force
    Set-Content -Path $versionMarker -Value $version -Encoding ascii
} else {
    Write-Host "[2/6] tunnel-client $version is already installed."
}

$tunnelExe = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter "tunnel-client.exe" |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $tunnelExe) {
    throw "tunnel-client.exe was not found after extraction."
}

Write-Host "[3/6] Tunnel client ready: $tunnelExe"
& $tunnelExe --version
if ($LASTEXITCODE -ne 0) {
    throw "tunnel-client --version failed."
}

Write-Host ""
Write-Host "OpenAI Platform values required:" -ForegroundColor Yellow
Write-Host "  Tunnels:      https://platform.openai.com/settings/organization/tunnels"
Write-Host "  Runtime keys: https://platform.openai.com/settings/organization/api-keys"
Write-Host ""
Write-Host "Create/select a tunnel and a Runtime API key first."
Write-Host "Do NOT paste the Runtime API key into ChatGPT; enter it only in this local window."
Write-Host ""

$tunnelId = (Read-Host "Tunnel ID (tunnel_ + 32 lowercase hex characters)").Trim()
if ($tunnelId -notmatch '^tunnel_[0-9a-f]{32}$') {
    throw "Tunnel ID format is invalid."
}

$secureApiKey = Read-Host "Runtime API Key" -AsSecureString
$apiKey = Convert-SecureStringToPlainText $secureApiKey
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "Runtime API key is empty."
}

$profile = "agentdock-board-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$env:CONTROL_PLANE_API_KEY = $apiKey
$env:CONTROL_PLANE_TUNNEL_ID = $tunnelId

try {
    Write-Host "[4/6] Creating tunnel-client profile $profile..."
    & $tunnelExe init `
        --sample sample_mcp_remote_no_auth `
        --profile $profile `
        --tunnel-id $tunnelId `
        --mcp-server-url $McpServerUrl
    if ($LASTEXITCODE -ne 0) {
        throw "tunnel-client init failed."
    }

    Write-Host "[5/6] Running tunnel doctor..."
    & $tunnelExe doctor --profile $profile --explain
    if ($LASTEXITCODE -ne 0) {
        throw "tunnel-client doctor failed."
    }

    if (Test-Path $PidFile) {
        $oldPidText = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $oldPid = 0
        if ([int]::TryParse($oldPidText, [ref]$oldPid)) {
            $oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProcess) {
                try {
                    $oldWin32 = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid"
                    if ([string]$oldWin32.CommandLine -match 'tunnel-client') {
                        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Milliseconds 500
                    }
                } catch {}
            }
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[6/6] Starting Secure MCP Tunnel..."
    $process = Start-Process `
        -FilePath $tunnelExe `
        -ArgumentList @("run", "--profile", $profile) `
        -WorkingDirectory $ExtractRoot `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -Path $PidFile -Value $process.Id -Encoding ascii
    Start-Sleep -Seconds 3

    if ($process.HasExited) {
        $errorTail = ""
        if (Test-Path $StderrLog) {
            $errorTail = (Get-Content $StderrLog -Tail 60 -ErrorAction SilentlyContinue) -join "`n"
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        throw "tunnel-client exited immediately.`n$errorTail"
    }

    $config = [ordered]@{
        version = "2.0"
        tunnel_client_version = $version
        tunnel_id = $tunnelId
        profile = $profile
        mcp_server_url = $McpServerUrl
        pid = $process.Id
        executable = $tunnelExe
        started_at = (Get-Date).ToString("o")
    }
    $config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigFile -Encoding utf8

    Write-Host ""
    Write-Host "[Secure MCP Tunnel] READY" -ForegroundColor Green
    Write-Host "Tunnel ID:  $tunnelId"
    Write-Host "Profile:    $profile"
    Write-Host "Local MCP:  $McpServerUrl"
    Write-Host "PID:        $($process.Id)"
    Write-Host "Config:     $ConfigFile"
    Write-Host ""
    Write-Host "Next in ChatGPT:" -ForegroundColor Cyan
    Write-Host "  1. Open Settings -> Apps/Plugins and enable Developer mode."
    Write-Host "  2. Create a developer app."
    Write-Host "  3. Choose Connection = Tunnel."
    Write-Host "  4. Select this tunnel or paste the Tunnel ID above."
    Write-Host "  5. Scan tools and create the app."
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $apiKey = $null
}
