$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $appRoot 'launcher-config.json'
$wslPath = Join-Path $env:WINDIR 'System32\wsl.exe'
$edgeProfile = Join-Path $appRoot 'EdgeProfile'
$launcherLog = Join-Path $appRoot 'launcher.log'
$launchId = [guid]::NewGuid().ToString()
$mutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekHarnessDesktopLauncher')
$hasMutex = $false
$wslProcess = $null
$edgeStarted = $false

function Write-LauncherLog([string]$Message) {
    $line = '{0:o} {1}' -f [DateTime]::Now, $Message
    Add-Content -LiteralPath $launcherLog -Value $line -Encoding UTF8
}

function Show-LauncherError([string]$Message) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        $Message,
        'DeepSeek Harness',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Find-EdgePath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    return ($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

function Invoke-WslHelper([string]$Action, [string]$Id = '') {
    $arguments = @('-d', $script:distro, '--exec', 'bash', $script:linuxHelper, $Action)
    if ($Id) {
        $arguments += $Id
    }
    & $wslPath @arguments | Out-Null
    return $LASTEXITCODE
}

function Get-OwnedEdgeProcesses {
    $profileNeedle = $edgeProfile.ToLowerInvariant()
    $owned = Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($profileNeedle) }
    return @($owned)
}

function Stop-OwnedEdgeProcesses {
    foreach ($item in @(Get-OwnedEdgeProcesses)) {
        Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

function Get-LauncherLogTail {
    $lines = & $wslPath -d $script:distro --exec tail -n 24 "$script:linuxHome/.cache/deepseek-harness-launcher/latest.log" 2>$null
    if ($lines) {
        return ($lines -join "`n")
    }
    return 'No launcher log was produced.'
}

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        $shell = New-Object -ComObject WScript.Shell
        $shell.AppActivate('DeepSeek Harness') | Out-Null
        exit 0
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Launcher configuration is missing. Run Install.ps1 again.`n$configPath"
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $script:distro = [string]$config.distro
    $script:linuxHome = [string]$config.linuxHome
    $script:linuxHelper = [string]$config.linuxHelper
    $url = [string]$config.url

    if ($script:distro -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'The configured WSL distribution name is invalid. Run Install.ps1 again.'
    }
    if ($script:linuxHome -notmatch '^/[A-Za-z0-9._/-]+$') {
        throw 'The configured Linux HOME path is invalid. Run Install.ps1 again.'
    }
    if ($script:linuxHelper -notmatch '^/[^"\r\n]+$') {
        throw 'The configured WSL helper path is invalid. Run Install.ps1 again.'
    }
    if ($url -ne 'http://127.0.0.1:3080/') {
        throw 'The configured Harness URL is invalid. Run Install.ps1 again.'
    }

    $edgePath = Find-EdgePath
    if (-not $edgePath) {
        throw 'Microsoft Edge was not found. Install Edge and try again.'
    }

    Set-Content -LiteralPath $launcherLog -Value '' -Encoding UTF8
    Write-LauncherLog "launch_id=$launchId start"

    $stopAllResult = Invoke-WslHelper 'stop-all'
    if ($stopAllResult -ne 0) {
        throw "Could not clean a previous launcher-owned Harness process (exit $stopAllResult)."
    }
    if (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue) {
        throw 'Port 3080 is already in use. Close the existing service and try again.'
    }

    $wslArguments = '-d {0} --cd {1} --exec setsid --wait bash "{2}" start {3}' -f `
        $script:distro, $script:linuxHome, $script:linuxHelper, $launchId
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $wslPath
    $startInfo.Arguments = $wslArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $wslProcess = New-Object System.Diagnostics.Process
    $wslProcess.StartInfo = $startInfo
    if (-not $wslProcess.Start()) {
        throw 'Failed to start DeepSeek Harness in WSL.'
    }
    Write-LauncherLog "hidden_wsl_pid=$($wslProcess.Id)"

    $ready = $false
    $readyDeadline = [DateTime]::UtcNow.AddMinutes(15)
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        if ($wslProcess.HasExited) {
            throw "DeepSeek Harness exited during startup.`n`n$(Get-LauncherLogTail)"
        }
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
        throw "DeepSeek Harness did not become ready within 15 minutes.`n`n$(Get-LauncherLogTail)"
    }
    Write-LauncherLog 'http_ready=200'

    New-Item -ItemType Directory -Force -Path $edgeProfile | Out-Null
    $edgeArguments = '--app="{0}" --user-data-dir="{1}" --no-first-run --no-default-browser-check --disable-background-mode' -f `
        $url, $edgeProfile
    Start-Process -FilePath $edgePath -ArgumentList $edgeArguments | Out-Null
    $edgeStarted = $true
    Write-LauncherLog 'edge_app_started'

    $windowSeen = $false
    $windowMissingSince = $null
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ($true) {
        if ($wslProcess.HasExited) {
            throw "DeepSeek Harness stopped unexpectedly.`n`n$(Get-LauncherLogTail)"
        }

        $visibleWindow = $false
        foreach ($owned in @(Get-OwnedEdgeProcesses)) {
            $process = Get-Process -Id ([int]$owned.ProcessId) -ErrorAction SilentlyContinue
            if ($process -and $process.MainWindowHandle -ne 0) {
                $visibleWindow = $true
                break
            }
        }

        if ($visibleWindow) {
            if (-not $windowSeen) {
                Write-LauncherLog 'edge_app_window_seen'
            }
            $windowSeen = $true
            $windowMissingSince = $null
        }
        elseif ($windowSeen) {
            if (-not $windowMissingSince) {
                $windowMissingSince = [DateTime]::UtcNow
            }
            elseif (([DateTime]::UtcNow - $windowMissingSince).TotalSeconds -ge 2) {
                Write-LauncherLog 'edge_app_window_closed'
                break
            }
        }
        elseif ([DateTime]::UtcNow -gt $windowDeadline) {
            throw 'The DeepSeek Harness application window did not appear.'
        }

        Start-Sleep -Milliseconds 500
    }
}
catch {
    Write-LauncherLog "error=$($_.Exception.Message)"
    Show-LauncherError $_.Exception.Message
}
finally {
    if ($edgeStarted) {
        Stop-OwnedEdgeProcesses
    }

    try {
        $stopResult = Invoke-WslHelper 'stop' $launchId
        Write-LauncherLog "wsl_stop_exit=$stopResult"
    }
    catch {
        Write-LauncherLog "wsl_stop_error=$($_.Exception.Message)"
    }

    if ($wslProcess -and -not $wslProcess.HasExited) {
        $wslProcess.WaitForExit(8000) | Out-Null
        if (-not $wslProcess.HasExited) {
            Stop-Process -Id $wslProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
    Write-LauncherLog 'launcher_exit'
}
