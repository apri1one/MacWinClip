param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'MacWindowsSSHClipboard'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup')
)

$ErrorActionPreference = 'Stop'
$root = $InstallRoot
$shortcutPath = Join-Path $StartupDirectory 'MacWindowsSSHClipboard.lnk'

if (Test-Path -LiteralPath (Join-Path $root 'stop.ps1')) {
    & (Join-Path $root 'stop.ps1')
}

Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Windows clipboard bridge removed.'
