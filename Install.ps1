[CmdletBinding()]
param(
    [string]$Distro = '',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness'),
    [string]$IconCacheRoot = (Join-Path $env:ProgramData 'DeepSeekHarness'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness.lnk'),
    [switch]$SkipPrerequisiteChecks,
    [switch]$SkipRuntimeInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Join-Path $repositoryRoot 'src'
$assetRoot = Join-Path $repositoryRoot 'assets'
$iconSource = Join-Path $assetRoot 'DeepSeek-Harness.ico'
$wslPath = Join-Path $env:WINDIR 'System32\wsl.exe'

if ([string]::IsNullOrWhiteSpace($IconCacheRoot) -or
    -not [IO.Path]::IsPathRooted($IconCacheRoot) -or
    $IconCacheRoot.Contains('%')) {
    throw 'IconCacheRoot must be an absolute Windows path without environment-variable tokens.'
}
$IconCacheRoot = [IO.Path]::GetFullPath($IconCacheRoot)

function Invoke-WslCapture([string[]]$Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 promotes native stderr to ErrorRecord objects when
        # streams are merged. WSL may emit non-fatal host warnings on stderr, so
        # preserve them for real failures but return stdout only on exit code 0.
        $ErrorActionPreference = 'Continue'
        $output = & $wslPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "WSL command failed (exit $exitCode): $($output -join [Environment]::NewLine)"
    }
    $standardOutput = @($output | Where-Object { $_ -is [string] })
    return (($standardOutput | Out-String).Trim())
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
    (Join-Path $sourceRoot 'pnpm-workspace.yaml'),
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
    foreach ($requiredCommand in @('bash', 'setsid', 'ps', 'awk', 'grep', 'tail', 'install', 'node', 'pnpm')) {
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
New-Item -ItemType Directory -Force -Path $IconCacheRoot | Out-Null

$vbsDestination = Join-Path $InstallRoot 'Launch-DeepSeek-Harness.vbs'
$powershellDestination = Join-Path $InstallRoot 'Launch-DeepSeek-Harness.ps1'
$helperDestination = Join-Path $InstallRoot 'Run-DeepSeek-Harness.sh'
$pnpmPolicyDestination = Join-Path $InstallRoot 'pnpm-workspace.yaml'
$iconHash = (Get-FileHash -LiteralPath $iconSource -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
$iconDestination = Join-Path $IconCacheRoot ("DeepSeek-Harness-v1-$iconHash.ico")

Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launch-DeepSeek-Harness.vbs') -Destination $vbsDestination -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Launch-DeepSeek-Harness.ps1') -Destination $powershellDestination -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Run-DeepSeek-Harness.sh') -Destination $helperDestination -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'pnpm-workspace.yaml') -Destination $pnpmPolicyDestination -Force
Copy-Item -LiteralPath $iconSource -Destination $iconDestination -Force
$sourceIconHash = (Get-FileHash -LiteralPath $iconSource -Algorithm SHA256).Hash
$installedIconHash = (Get-FileHash -LiteralPath $iconDestination -Algorithm SHA256).Hash
if (-not $sourceIconHash.Equals($installedIconHash, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Installed shortcut icon failed its integrity check: $iconDestination"
}
Get-ChildItem -LiteralPath $IconCacheRoot -File -Filter 'DeepSeek-Harness-*.ico' -ErrorAction SilentlyContinue |
    Where-Object { -not $_.FullName.Equals($iconDestination, [StringComparison]::OrdinalIgnoreCase) } |
    Remove-Item -Force
$installedIcons = Get-ChildItem -LiteralPath $InstallRoot -File -Filter 'DeepSeek-Harness-*.ico' -ErrorAction SilentlyContinue
if ($installedIcons) {
    $installedIcons | Remove-Item -Force
}
$legacyIcon = Join-Path $InstallRoot 'DeepSeek-Harness.ico'
if (Test-Path -LiteralPath $legacyIcon) {
    Remove-Item -LiteralPath $legacyIcon -Force
}

$sourceHelperLinux = Invoke-WslCapture @(
    '-d', $Distro, '--exec', 'wslpath', '-a', (Join-Path $sourceRoot 'Run-DeepSeek-Harness.sh')
)
$sourcePolicyLinux = Invoke-WslCapture @(
    '-d', $Distro, '--exec', 'wslpath', '-a', (Join-Path $sourceRoot 'pnpm-workspace.yaml')
)
foreach ($sourceLinuxPath in @($sourceHelperLinux, $sourcePolicyLinux)) {
    if ($sourceLinuxPath -notmatch '^/[^"\r\n]+$') {
        throw "Could not convert a runtime source path to a safe WSL path: $sourceLinuxPath"
    }
}

if ($SkipRuntimeInstall) {
    # Package validation remains side-effect free inside WSL.
    $linuxHelper = $sourceHelperLinux
}
else {
    $linuxLauncherRoot = "$linuxHome/.local/share/deepseek-harness-launcher"
    $linuxHelper = "$linuxLauncherRoot/Run-DeepSeek-Harness.sh"
    if ($linuxLauncherRoot -notmatch '^/[A-Za-z0-9._/-]+$' -or $linuxHelper -notmatch '^/[A-Za-z0-9._/-]+$') {
        throw "Could not construct a safe WSL launcher path: $linuxHelper"
    }

    & $wslPath -d $Distro --exec mkdir -p $linuxLauncherRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the WSL launcher directory (exit $LASTEXITCODE)."
    }
    & $wslPath -d $Distro --exec install -m 700 $sourceHelperLinux $linuxHelper
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install the WSL launcher helper (exit $LASTEXITCODE)."
    }
    & $wslPath -d $Distro --exec install -m 600 $sourcePolicyLinux "$linuxLauncherRoot/pnpm-workspace.yaml"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install the pnpm runtime policy (exit $LASTEXITCODE)."
    }

    Write-Host 'Installing or updating the DeepSeek Harness runtime in WSL...'
    & $wslPath -d $Distro --exec bash $linuxHelper install
    if ($LASTEXITCODE -ne 0) {
        throw "DeepSeek Harness runtime installation failed (exit $LASTEXITCODE)."
    }
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
if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
}
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $vbsDestination
$shortcut.Arguments = ''
$shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
$shortcut.IconLocation = '{0},0' -f $iconDestination
$shortcut.Description = 'Launch the official DeepSeek Harness in WSL; closing the app window stops the service'
$shortcut.Save()

# Re-open the .lnk and enforce the icon-path contract. In particular, never let
# %USERPROFILE% or another environment token be serialized into IconLocation:
# Windows can treat it as literal text and silently fall back to a blank icon.
$verifiedShortcut = $shell.CreateShortcut($ShortcutPath)
$verifiedIconLocation = [string]$verifiedShortcut.IconLocation
if (-not (Test-Path -LiteralPath $vbsDestination) -or
    -not (Test-Path -LiteralPath $powershellDestination) -or
    -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'launcher-config.json'))) {
    throw 'The shortcut was created before all required launcher files were installed.'
}
if (-not ([string]$verifiedShortcut.TargetPath).Equals($vbsDestination, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::IsNullOrEmpty([string]$verifiedShortcut.Arguments)) {
    throw 'The shortcut target or launcher-script argument was not saved correctly.'
}
if ($verifiedIconLocation -notmatch '^(?<IconPath>.+),0$') {
    throw "The shortcut contains an invalid icon location: $verifiedIconLocation"
}
$verifiedIconPath = [IO.Path]::GetFullPath($Matches.IconPath)
if (-not $verifiedIconPath.Equals($iconDestination, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $verifiedIconPath)) {
    throw "The shortcut icon path was not saved correctly: $verifiedIconLocation"
}
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
