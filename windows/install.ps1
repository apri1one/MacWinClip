param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'MacWindowsSSHClipboard'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [string]$ReceiveRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
    [string]$RecoveryTaskName = 'MacWindowsSSHClipboard Recovery',
    [switch]$NoStart,
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'

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

New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null

foreach ($name in 'agent.ps1', 'file-worker.ps1', 'lazy-files.cs', 'progress.ps1', 'remote.ps1', 'start.ps1', 'stop.ps1', 'supervisor.ps1', 'status.ps1', 'uninstall.ps1') {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $root $name) -Force
}
[IO.File]::WriteAllText(
    (Join-Path $root 'receive-root.txt'),
    $resolvedReceiveRoot,
    [Text.UTF8Encoding]::new($false)
)
[IO.File]::WriteAllText(
    (Join-Path $root 'recovery-task-name.txt'),
    $RecoveryTaskName,
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
    [void](Invoke-TaskScheduler @('/Delete', '/TN', $RecoveryTaskName, '/F'))
} else {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    $powerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $escapedRoot = [Security.SecurityElement]::Escape($root)
    $escapedPowerShell = [Security.SecurityElement]::Escape($powerShell)
    $escapedSid = [Security.SecurityElement]::Escape($currentSid)
    $taskXmlPath = Join-Path $root 'recovery-task.xml'
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keep the MacWinClip desktop agent self-healing.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$escapedSid</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedPowerShell</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$escapedRoot\supervisor.ps1"</Arguments>
      <WorkingDirectory>$escapedRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    [IO.File]::WriteAllText(
        $taskXmlPath,
        $taskXml,
        [Text.UnicodeEncoding]::new($false, $true)
    )
    try {
        $createResult = Invoke-TaskScheduler @(
            '/Create', '/TN', $RecoveryTaskName, '/XML', $taskXmlPath, '/F'
        )
        if ($createResult -ne 0) {
            throw 'Could not create the interactive recovery task.'
        }
    } finally {
        Remove-Item -LiteralPath $taskXmlPath -Force -ErrorAction SilentlyContinue
    }
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
