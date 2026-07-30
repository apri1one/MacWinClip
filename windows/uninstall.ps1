param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'MacWindowsSSHClipboard'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [string]$RecoveryTaskName = 'MacWindowsSSHClipboard Recovery'
)

$ErrorActionPreference = 'Stop'
$root = $InstallRoot
$shortcutPath = Join-Path $StartupDirectory 'MacWindowsSSHClipboard.lnk'

function Invoke-TaskScheduler([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & "$env:WINDIR\System32\schtasks.exe" @Arguments *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

if (Test-Path -LiteralPath (Join-Path $root 'stop.ps1')) {
    & (Join-Path $root 'stop.ps1')
}

Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
[void](Invoke-TaskScheduler @('/Delete', '/TN', $RecoveryTaskName, '/F'))
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Windows clipboard bridge removed.'
