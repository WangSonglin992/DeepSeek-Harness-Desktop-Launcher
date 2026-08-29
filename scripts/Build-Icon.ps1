[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\IMG_18845-source.png'),
    [string]$PreviewPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\DeepSeek-Harness.png'),
    [string]$IconPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\DeepSeek-Harness.ico')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw 'Python 3 was not found. Install Python and Pillow to rebuild the icon.'
}

& $python.Source -c 'from PIL import Image; print(Image.__version__)' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Pillow is not installed. Run: python -m pip install -r requirements-dev.txt'
}

& $python.Source (Join-Path $PSScriptRoot 'build_icon.py') $SourcePath $PreviewPath $IconPath
if ($LASTEXITCODE -ne 0) {
    throw "Icon build failed with exit code $LASTEXITCODE"
}

Write-Host "PNG preview: $PreviewPath"
Write-Host "Windows icon: $IconPath"
