param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'MacWindowsSSHClipboard'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [string]$ReceiveRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
    [switch]$NoStart,
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw 'PowerShell 5.1 or newer is required.'
}

$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($null -eq $sshd -or $sshd.Status -ne 'Running') {
    throw 'Windows OpenSSH Server (sshd) is not running. Complete the SSH setup guide first.'
}

$source = $PSScriptRoot
$root = $InstallRoot
$inboxRoot = Join-Path $root 'inbox'
$resolvedReceiveRoot = [IO.Path]::GetFullPath($ReceiveRoot)

$existingStop = Join-Path $root 'stop.ps1'
if (Test-Path -LiteralPath $existingStop) {
    & $existingStop
}

foreach ($pattern in 'outbound.*.files*.msg', 'outbound.*.files*.tmp', 'upload.*.files.tmp', 'file-worker.*.pid') {
    Get-ChildItem -LiteralPath $root -Filter $pattern -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
}
$existingInbox = Join-Path $root 'inbox'
Get-ChildItem -LiteralPath $existingInbox -Filter '*.msg' -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '^[a-f0-9]{32}\.(files|files-offer|files-dismiss)\.msg$'
    } |
    Remove-Item -Force
foreach ($name in 'file-requests', 'outgoing', 'outbound-file-offers', 'outbound-file-demands', 'incoming', 'file-offers', 'file-demands', 'file-dismissals', 'progress', 'cancel') {
    Remove-Item -LiteralPath (Join-Path $root $name) -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null

foreach ($name in 'agent.ps1', 'file-worker.ps1', 'lazy-files.cs', 'progress.ps1', 'remote.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'uninstall.ps1') {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $root $name) -Force
}
[IO.File]::WriteAllText(
    (Join-Path $root 'receive-root.txt'),
    $resolvedReceiveRoot,
    [Text.UTF8Encoding]::new($false)
)

$security = [Security.AccessControl.DirectorySecurity]::new()
$security.SetAccessRuleProtection($true, $false)
$inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$propagation = [Security.AccessControl.PropagationFlags]::None
$fullControl = [Security.AccessControl.FileSystemRights]::FullControl
$allow = [Security.AccessControl.AccessControlType]::Allow
$identities = @(
    [Security.Principal.WindowsIdentity]::GetCurrent().User,
    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
)
foreach ($identity in $identities) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        $fullControl,
        $inheritance,
        $propagation,
        $allow
    )
    $security.AddAccessRule($rule)
}
[IO.Directory]::SetAccessControl($root, $security)

$shortcutPath = Join-Path $StartupDirectory 'MacWindowsSSHClipboard.lnk'
if ($NoAutoStart) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Force -Path $StartupDirectory | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\start.ps1`""
    $shortcut.WorkingDirectory = $root
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Start MacWinClip agent'
    $shortcut.Save()
}

if (-not $NoStart) {
    & (Join-Path $root 'start.ps1')
}
Write-Host "Installed to: $root"
if ($NoStart) {
    Write-Host 'Files installed; agent start was intentionally skipped.'
} else {
    Write-Host 'The agent is running in the current Windows GUI session.'
}
if ($NoAutoStart) {
    Write-Host 'Automatic start after Windows sign-in is disabled.'
} else {
    Write-Host 'The agent will start automatically after this Windows user signs in.'
}
