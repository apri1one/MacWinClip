param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'MacWindowsSSHClipboard'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [switch]$NoStart
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
New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null

foreach ($name in 'agent.ps1', 'remote.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'uninstall.ps1') {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $root $name) -Force
}

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

New-Item -ItemType Directory -Force -Path $StartupDirectory | Out-Null
$shortcutPath = Join-Path $StartupDirectory 'MacWindowsSSHClipboard.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\start.ps1`""
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle = 7
$shortcut.Description = 'Start Mac-Windows SSH Clipboard agent'
$shortcut.Save()

if (-not $NoStart) {
    & (Join-Path $root 'start.ps1')
}
Write-Host "Installed to: $root"
if ($NoStart) {
    Write-Host 'Files and startup shortcut installed; agent start was intentionally skipped.'
} else {
    Write-Host 'The agent will start when this Windows user signs in.'
}
