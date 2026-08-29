[CmdletBinding()]
param(
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness.lnk'),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness'),
    [int]$ReadyTimeoutSeconds = 180,
    [int]$StopTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$url = 'http://127.0.0.1:3080/'
$edgeProfile = Join-Path $InstallRoot 'EdgeProfile'
$supervisorPath = Join-Path $InstallRoot 'Launch-DeepSeek-Harness.ps1'
$launcherLog = Join-Path $InstallRoot 'launcher.log'

function Get-OwnedEdgeProcesses {
    $profileNeedle = $edgeProfile.ToLowerInvariant()
    return @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($profileNeedle) })
}

function Get-SupervisorCount {
    $supervisorNeedle = $supervisorPath.ToLowerInvariant()
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($supervisorNeedle) }).Count
}

function Get-OwnedEdgeCount {
    return @(Get-OwnedEdgeProcesses).Count
}

if (-not (Test-Path -LiteralPath $ShortcutPath)) {
    throw "Shortcut not found: $ShortcutPath"
}
if (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue) {
    throw 'Port 3080 is already in use. Close the existing Harness window before testing.'
}

Start-Process -FilePath $ShortcutPath

$ready = $false
$readyDeadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
while ([DateTime]::UtcNow -lt $readyDeadline) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2
        if ($response.StatusCode -eq 200 -and $response.Content -match 'DeepSeek') {
            $ready = $true
            break
        }
    }
    catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $ready) {
    throw "Harness did not become ready within $ReadyTimeoutSeconds seconds."
}

$visibleWindow = $null
$windowDeadline = [DateTime]::UtcNow.AddSeconds(45)
while ([DateTime]::UtcNow -lt $windowDeadline -and -not $visibleWindow) {
    foreach ($owned in @(Get-OwnedEdgeProcesses)) {
        $candidate = Get-Process -Id ([int]$owned.ProcessId) -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.MainWindowHandle -ne 0) {
            $visibleWindow = $candidate
            break
        }
    }
    if (-not $visibleWindow) {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $visibleWindow) {
    throw 'The dedicated DeepSeek Harness Edge app window did not appear.'
}

$supervisorSawWindow = $false
$seenDeadline = [DateTime]::UtcNow.AddSeconds(10)
while ([DateTime]::UtcNow -lt $seenDeadline) {
    if ((Get-Content -LiteralPath $launcherLog -Raw -ErrorAction SilentlyContinue) -match 'edge_app_window_seen') {
        $supervisorSawWindow = $true
        break
    }
    Start-Sleep -Milliseconds 250
}
if (-not $supervisorSawWindow) {
    throw 'The supervisor did not confirm the application window before the test timeout.'
}

$windowTitle = $visibleWindow.MainWindowTitle
$visibleWindow.CloseMainWindow() | Out-Null

$stopped = $false
$stopDeadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSeconds)
while ([DateTime]::UtcNow -lt $stopDeadline) {
    $portListening = [bool](Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)
    if (-not $portListening -and (Get-SupervisorCount) -eq 0 -and (Get-OwnedEdgeCount) -eq 0) {
        $stopped = $true
        break
    }
    Start-Sleep -Milliseconds 500
}

$result = [ordered]@{
    httpReady = $ready
    windowTitle = $windowTitle
    portClosed = -not [bool](Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)
    supervisorCount = Get-SupervisorCount
    ownedEdgeCount = Get-OwnedEdgeCount
    lifecyclePassed = $stopped
}
$result | ConvertTo-Json

if (-not $stopped) {
    throw 'The launcher did not stop cleanly after the app window was closed.'
}
