[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness'),
    [string]$IconCacheRoot = (Join-Path $env:ProgramData 'DeepSeekHarness'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness.lnk')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'DeepSeek Harness'))
$requestedRoot = [IO.Path]::GetFullPath($InstallRoot)
if (-not $requestedRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove an unexpected directory: $requestedRoot"
}
$expectedIconCacheRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'DeepSeekHarness'))
$requestedIconCacheRoot = [IO.Path]::GetFullPath($IconCacheRoot)
if (-not $requestedIconCacheRoot.Equals($expectedIconCacheRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove an unexpected icon cache directory: $requestedIconCacheRoot"
}

$configPath = Join-Path $requestedRoot 'launcher-config.json'
$helperScript = Join-Path $requestedRoot 'Launch-DeepSeek-Harness.ps1'
$edgeProfile = Join-Path $requestedRoot 'EdgeProfile'
$wslPath = Join-Path $env:WINDIR 'System32\wsl.exe'

if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($config.distro -and $config.linuxHelper -and (Test-Path -LiteralPath $wslPath)) {
            & $wslPath -d ([string]$config.distro) --exec bash ([string]$config.linuxHelper) stop-all | Out-Null
        }
    }
    catch {
        Write-Warning "Could not request WSL cleanup: $($_.Exception.Message)"
    }
}

$profileNeedle = $edgeProfile.ToLowerInvariant()
Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($profileNeedle) } |
    ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }

$launcherNeedle = $helperScript.ToLowerInvariant()
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($launcherNeedle) } |
    ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
}
if (Test-Path -LiteralPath $requestedRoot) {
    Remove-Item -LiteralPath $requestedRoot -Recurse -Force
}
if (Test-Path -LiteralPath $requestedIconCacheRoot) {
    Remove-Item -LiteralPath $requestedIconCacheRoot -Recurse -Force
}

Write-Host 'DeepSeek Harness Desktop Launcher was removed.' -ForegroundColor Green
Write-Host 'WSL, pnpm cache, Harness runtime, and ~/.dsh data were preserved.'
