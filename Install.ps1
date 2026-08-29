[CmdletBinding()]
param(
    [string]$Distro = '',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness.lnk'),
    [switch]$SkipPrerequisiteChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Join-Path $repositoryRoot 'src'
$assetRoot = Join-Path $repositoryRoot 'assets'
$iconSource = Join-Path $assetRoot 'DeepSeek-Harness.ico'
$wslPath = Join-Path $env:WINDIR 'System32\wsl.exe'
$wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'

function Invoke-WslCapture([string[]]$Arguments) {
    $output = & $wslPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
    return (($output | Out-String).Trim())
}

function Test-EdgeInstalled {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    return [bool]($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

foreach ($requiredPath in @(
    (Join-Path $sourceRoot 'Launch-DeepSeek-Harness.vbs'),
    (Join-Path $sourceRoot 'Launch-DeepSeek-Harness.ps1'),
    (Join-Path $sourceRoot 'Run-DeepSeek-Harness.sh'),
    $iconSource
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required package file is missing: $requiredPath"
    }
}

if (-not (Test-Path -LiteralPath $wslPath)) {
    throw 'WSL is not installed. Enable WSL2 before installing this launcher.'
}

if ([string]::IsNullOrWhiteSpace($Distro)) {
    $Distro = Invoke-WslCapture @('--exec', 'bash', '-lc', 'printf "%s" "$WSL_DISTRO_NAME"')
}
if ($Distro -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Unsupported WSL distribution name '$Distro'. Use a name containing only letters, numbers, dot, underscore, or hyphen."
}

$linuxHome = Invoke-WslCapture @('-d', $Distro, '--exec', 'bash', '-lc', 'printf "%s" "$HOME"')
if ($linuxHome -notmatch '^/[A-Za-z0-9._/-]+$') {
    throw "Unsupported Linux HOME path returned by WSL: $linuxHome"
}

if (-not $SkipPrerequisiteChecks) {
    foreach ($requiredCommand in @('bash', 'setsid', 'ps', 'awk', 'grep', 'tail', 'node', 'npm', 'npx')) {
        & $wslPath -d $Distro --exec bash -lc "command -v $requiredCommand >/dev/null"
        if ($LASTEXITCODE -ne 0) {
            throw "The selected WSL distribution is missing the required command: $requiredCommand"
        }
    }
    if (-not (Test-EdgeInstalled)) {
        throw 'Microsoft Edge was not found. Install Edge before using the launcher.'
    }
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$vbsDestination = Join-Path $InstallRoot 'Launch-DeepSeek-Harness.vbs'
$powershellDestination = Join-Path $InstallRoot 'Launch-DeepSeek-Harness.ps1'
$helperDestination = Join-Path $InstallRoot 'Run-DeepSeek-Harness.sh'
$iconHash = (Get-FileHash -LiteralPath $iconSource -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
$iconDestination = Join-Path $InstallRoot ("DeepSeek-Harness-$iconHash.ico")

Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launch-DeepSeek-Harness.vbs') -Destination $vbsDestination -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launch-DeepSeek-Harness.ps1') -Destination $powershellDestination -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Run-DeepSeek-Harness.sh') -Destination $helperDestination -Force
Copy-Item -LiteralPath $iconSource -Destination $iconDestination -Force
Get-ChildItem -LiteralPath $InstallRoot -File -Filter 'DeepSeek-Harness-*.ico' -ErrorAction SilentlyContinue |
    Where-Object { -not $_.FullName.Equals($iconDestination, [StringComparison]::OrdinalIgnoreCase) } |
    Remove-Item -Force
$legacyIcon = Join-Path $InstallRoot 'DeepSeek-Harness.ico'
if (Test-Path -LiteralPath $legacyIcon) {
    Remove-Item -LiteralPath $legacyIcon -Force
}

$linuxHelper = Invoke-WslCapture @('-d', $Distro, '--exec', 'wslpath', '-a', $helperDestination)
if ($linuxHelper -notmatch '^/[^"\r\n]+$') {
    throw "Could not convert the helper path to a safe WSL path: $linuxHelper"
}

$config = [ordered]@{
    schemaVersion = 1
    distro = $Distro
    linuxHome = $linuxHome
    linuxHelper = $linuxHelper
    url = 'http://127.0.0.1:3080/'
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'launcher-config.json') -Encoding UTF8

$shortcutDirectory = Split-Path -Parent $ShortcutPath
if ($shortcutDirectory) {
    New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null
}
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $wscriptPath
$shortcut.Arguments = '//nologo "{0}"' -f $vbsDestination
$shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
$shortcut.IconLocation = '{0},0' -f $iconDestination
$shortcut.Description = 'Launch the official DeepSeek Harness in WSL; closing the app window stops the service'
$shortcut.Save()

try {
    if (-not ('DeepSeekHarnessLauncher.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
namespace DeepSeekHarnessLauncher {
    public static class NativeMethods {
        [System.Runtime.InteropServices.DllImport("shell32.dll")]
        public static extern void SHChangeNotify(uint eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
    }
}
'@
    }
    [DeepSeekHarnessLauncher.NativeMethods]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}
catch {
    # Explorer refresh is cosmetic; installation remains valid if it is unavailable.
}

Write-Host ''
Write-Host 'DeepSeek Harness Desktop Launcher installed successfully.' -ForegroundColor Green
Write-Host "Shortcut: $ShortcutPath"
Write-Host "WSL distribution: $Distro"
Write-Host 'No API key or DeepSeek credential was copied.'
