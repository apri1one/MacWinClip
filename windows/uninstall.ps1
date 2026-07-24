$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'MacWindowsSSHClipboard'
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'MacWindowsSSHClipboard.lnk'

if (Test-Path -LiteralPath (Join-Path $root 'stop.ps1')) {
    & (Join-Path $root 'stop.ps1')
}

Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Windows clipboard bridge removed.'

