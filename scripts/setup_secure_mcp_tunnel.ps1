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
$DoctorJsonLog = Join-Path $RunStateDir "secure-mcp-tunnel-doctor.json"

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

function Write-DoctorFailureSummary($Report) {
    Write-Host ""
    Write-Host "[Secure MCP Tunnel] DOCTOR FAILED" -ForegroundColor Red
    $failed = @($Report.checks | Where-Object { $_.status -eq "FAIL" })
    if ($failed.Count -eq 0 -and $Report.failed_checks) {
        Write-Host ("FAILED_CHECKS: " + (@($Report.failed_checks) -join ", ")) -ForegroundColor Red
        return
    }
    foreach ($check in $failed) {
        Write-Host ("FAIL: " + $check.id) -ForegroundColor Red
        if ($check.summary) {
            Write-Host ("  " + $check.summary)
        }
        if ($check.next) {
            foreach ($next in @($check.next)) {
                Write-Host ("  NEXT: " + $next) -ForegroundColor Yellow
            }
        }
    }
    Write-Host ""
    Write-Host "Full doctor report:" -ForegroundColor Yellow
    Write-Host "  $DoctorJsonLog"
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

# Use the full client package. The runtime ZIP contains tunnel-client-runtime.exe
# and does not provide the full init/doctor/profile CLI surface used below.
$asset = $release.assets | Where-Object {
    $_.name -match '^tunnel-client-v.+-windows-amd64\.zip$'
} | Select-Object -First 1

if (-not $asset) {
    throw "Could not find the full Windows amd64 tunnel-client ZIP in the latest OpenAI release."
}

$version = [string]$release.tag_name
$installMarker = "$version|full-client"
$zipPath = Join-Path $DownloadDir $asset.name
$versionMarker = Join-Path $ExtractRoot ".version"
$currentMarker = ""
if (Test-Path $versionMarker) {
    $currentMarker = (Get-Content $versionMarker -Raw -ErrorAction SilentlyContinue).Trim()
}

$existingTunnelExe = $null
if (Test-Path $ExtractRoot) {
    $existingTunnelExe = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter "tunnel-client.exe" `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}

if ($currentMarker -ne $installMarker -or -not $existingTunnelExe) {
    Write-Host "[2/6] Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    if (Test-Path $ExtractRoot) {
        Remove-Item $ExtractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $ExtractRoot -Force

    $tunnelExe = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter "tunnel-client.exe" `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $tunnelExe) {
        $foundExecutables = @(Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter "*.exe" `
            -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        throw "tunnel-client.exe was not found after extracting $($asset.name). Found executables: $($foundExecutables -join ', ')"
    }
    Set-Content -Path $versionMarker -Value $installMarker -Encoding ascii
} else {
    Write-Host "[2/6] tunnel-client $version full client is already installed."
    $tunnelExe = $existingTunnelExe
}

if (-not $tunnelExe) {
    $tunnelExe = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter "tunnel-client.exe" `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $tunnelExe) {
    throw "tunnel-client.exe was not found after installation."
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
    $doctorRaw = @(& $tunnelExe doctor --profile $profile --json 2>&1)
    $doctorExit = $LASTEXITCODE
    $doctorText = ($doctorRaw -join "`n").Trim()
    if ($doctorText) {
        Set-Content -Path $DoctorJsonLog -Value $doctorText -Encoding utf8
    }

    $doctorReport = $null
    try {
        if ($doctorText) {
            $doctorReport = $doctorText | ConvertFrom-Json
        }
    } catch {
        Write-Host "Doctor returned non-JSON output:" -ForegroundColor Yellow
        Write-Host $doctorText
    }

    if ($doctorExit -ne 0) {
        if ($doctorReport) {
            Write-DoctorFailureSummary $doctorReport
        }
        throw "tunnel-client doctor failed with exit code $doctorExit."
    }

    if ($doctorReport) {
        $skipped = @($doctorReport.checks | Where-Object { $_.status -eq "SKIP" })
        foreach ($check in $skipped) {
            Write-Host ("SKIP: " + $check.id + " - " + $check.summary) -ForegroundColor DarkGray
        }
        Write-Host "[5/6] Doctor OK" -ForegroundColor Green
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
        tunnel_client_flavor = "full-client"
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
    Write-Host "  1. Open Plugins and click + to create a new plugin."
    Write-Host "  2. Choose Connection = Tunnel."
    Write-Host "  3. Select this tunnel or paste the Tunnel ID above."
    Write-Host "  4. Scan tools and create the plugin."
} finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $env:CONTROL_PLANE_TUNNEL_ID = $null
    $apiKey = $null
}
