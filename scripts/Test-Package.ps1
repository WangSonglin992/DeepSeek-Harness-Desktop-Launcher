[CmdletBinding()]
param(
    [string]$Distro = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$wslPath = Join-Path $env:WINDIR 'System32\wsl.exe'

$powershellFiles = Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Filter '*.ps1'
foreach ($file in $powershellFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error in $($file.FullName): $($errors[0].Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($Distro)) {
    $Distro = ((& $wslPath --exec bash -lc 'printf "%s" "$WSL_DISTRO_NAME"') | Out-String).Trim()
}
$helperWindows = Join-Path $repositoryRoot 'src\Run-DeepSeek-Harness.sh'
$helperLinux = ((& $wslPath -d $Distro --exec wslpath -a $helperWindows) | Out-String).Trim()
& $wslPath -d $Distro --exec bash -n $helperLinux
if ($LASTEXITCODE -ne 0) {
    throw 'Bash syntax validation failed.'
}

$forbiddenNames = @('.dsh', '.env', 'launcher.log', 'launcher-config.json', 'EdgeProfile')
$files = Get-ChildItem -LiteralPath $repositoryRoot -Recurse -Force |
    Where-Object { $_.FullName -notlike "$(Join-Path $repositoryRoot '.git')*" }
foreach ($item in $files) {
    if ($forbiddenNames -contains $item.Name) {
        throw "Forbidden runtime or credential artifact found: $($item.FullName)"
    }
    if (-not $item.PSIsContainer -and $item.Extension -in @('.pem', '.key')) {
        throw "Forbidden key file found: $($item.FullName)"
    }
}

$textFiles = Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File |
    Where-Object { $_.FullName -notlike "$(Join-Path $repositoryRoot '.git')*" } |
    Where-Object { $_.Extension -in @('.ps1', '.psm1', '.vbs', '.sh', '.py', '.md', '.txt', '.gitignore') }
$secretPatterns = @(
    'sk-[A-Za-z0-9_-]{20,}',
    'api[_-]?key\s*[:=]\s*["''][^"'']{8,}["'']',
    'github_pat_[A-Za-z0-9_]{20,}',
    'gh[opurs]_[A-Za-z0-9]{20,}',
    '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'C:\\Users\\[0-9]{3,}',
    '/home/[A-Za-z0-9._-]+'
)
foreach ($file in $textFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern) {
            throw "Potential secret or machine-specific value in $($file.FullName): $pattern"
        }
    }
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryRoot = Join-Path $temporaryBase ('dsh-launcher-test-' + [guid]::NewGuid().ToString('N'))
$temporaryShortcut = Join-Path $temporaryRoot 'DeepSeek Harness.lnk'
$temporaryInstallRoot = Join-Path $temporaryRoot 'app'
$temporaryIconRoot = Join-Path $temporaryRoot 'icons'
try {
    New-Item -ItemType Directory -Force -Path $temporaryIconRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $temporaryIconRoot 'DeepSeek-Harness-stale.ico') -Value 'stale icon cache entry'

    # Reproduce the historical shortcut shape: wscript.exe plus a literal icon
    # environment token. The installer must replace both fragile fields.
    $shell = New-Object -ComObject WScript.Shell
    $legacyShortcut = $shell.CreateShortcut($temporaryShortcut)
    $legacyShortcut.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
    $legacyShortcut.IconLocation = '%USERPROFILE%\AppData\Local\DeepSeek Harness\missing.ico,0'
    $legacyShortcut.Description = 'legacy icon-path regression fixture'
    $legacyShortcut.Save()

    & (Join-Path $repositoryRoot 'Install.ps1') -Distro $Distro -InstallRoot $temporaryInstallRoot -IconCacheRoot $temporaryIconRoot -ShortcutPath $temporaryShortcut -SkipRuntimeInstall
    if (-not (Test-Path -LiteralPath $temporaryShortcut)) {
        throw 'The isolated installer did not create a shortcut.'
    }
    $shortcut = $shell.CreateShortcut($temporaryShortcut)
    $expectedVbsPath = Join-Path $temporaryInstallRoot 'Launch-DeepSeek-Harness.vbs'
    if (-not (Test-Path -LiteralPath $expectedVbsPath) -or
        -not ([string]$shortcut.TargetPath).Equals($expectedVbsPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrEmpty([string]$shortcut.Arguments)) {
        throw 'The isolated shortcut does not target the installed VBS launcher directly.'
    }
    if ($shortcut.Description -eq 'legacy icon-path regression fixture') {
        throw 'The installer did not replace the legacy shortcut.'
    }
    if ($shortcut.IconLocation -notmatch '^(?<IconPath>.+),0$') {
        throw "The isolated shortcut has an invalid icon location: $($shortcut.IconLocation)"
    }
    $shortcutIcon = [IO.Path]::GetFullPath($Matches.IconPath)
    if (-not [IO.Path]::IsPathRooted($shortcutIcon) -or $shortcutIcon.Contains('%')) {
        throw "The isolated shortcut icon is not a token-free absolute path: $shortcutIcon"
    }
    $expectedIconRoot = [IO.Path]::GetFullPath($temporaryIconRoot)
    if (-not (Split-Path -Parent $shortcutIcon).Equals($expectedIconRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The isolated shortcut icon was saved outside the dedicated icon cache: $shortcutIcon"
    }
    if (-not (Test-Path -LiteralPath $shortcutIcon)) {
        throw 'The isolated shortcut icon does not exist.'
    }
    $sourceIcon = Join-Path $repositoryRoot 'assets\DeepSeek-Harness.ico'
    if ((Get-FileHash -LiteralPath $shortcutIcon -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $sourceIcon -Algorithm SHA256).Hash) {
        throw 'The isolated shortcut icon does not match the packaged ICO.'
    }
    $cachedIcons = @(Get-ChildItem -LiteralPath $temporaryIconRoot -File -Filter 'DeepSeek-Harness-*.ico')
    if ($cachedIcons.Count -ne 1 -or
        -not $cachedIcons[0].FullName.Equals($shortcutIcon, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The isolated installer did not clean stale icon cache entries.'
    }
    if (Get-ChildItem -LiteralPath $temporaryInstallRoot -File -Filter 'DeepSeek-Harness-*.ico') {
        throw 'The isolated installer left an icon in the legacy per-user install directory.'
    }
    $generatedConfig = Join-Path $temporaryInstallRoot 'launcher-config.json'
    $configText = Get-Content -LiteralPath $generatedConfig -Raw
    foreach ($pattern in $secretPatterns[0..4]) {
        if ($configText -match $pattern) {
            throw "Potential secret in generated launcher config: $pattern"
        }
    }
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    if ($resolvedTemporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemporaryRoot) -like 'dsh-launcher-test-*' -and
        (Test-Path -LiteralPath $resolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

Write-Host 'Package validation passed: syntax, shortcut regression, isolated install, and secret scan.' -ForegroundColor Green
