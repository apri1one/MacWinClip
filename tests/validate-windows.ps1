$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mwsc-validation-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot 'installed'
$startupRoot = Join-Path $testRoot 'startup'
$process = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Read-LineWithTimeout([Diagnostics.Process]$Process, [int]$Milliseconds, [string]$Stage) {
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($Milliseconds)) {
        throw "Timed out waiting for a protocol line at $Stage."
    }
    return $task.Result
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'windows') -Filter '*.ps1' | ForEach-Object {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $_.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        Assert-True ($parseErrors.Count -eq 0) "PowerShell parse failed: $($_.Name)"
    }

    & (Join-Path $projectRoot 'windows\install.ps1') `
        -InstallRoot $installRoot `
        -StartupDirectory $startupRoot `
        -NoStart

    foreach ($name in 'agent.ps1', 'remote.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'uninstall.ps1') {
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot $name)) "Missing installed file: $name"
    }

    $shortcutPath = Join-Path $startupRoot 'MacWindowsSSHClipboard.lnk'
    Assert-True (Test-Path -LiteralPath $shortcutPath) 'Startup shortcut was not created.'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    Assert-True ($shortcut.Arguments -like "*$installRoot\start.ps1*") 'Startup shortcut targets the wrong install.'

    & (Join-Path $projectRoot 'windows\install.ps1') `
        -InstallRoot $installRoot `
        -StartupDirectory $startupRoot `
        -NoStart `
        -NoAutoStart
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'NoAutoStart left the startup shortcut installed.'

    $acl = [IO.Directory]::GetAccessControl($installRoot)
    Assert-True $acl.AreAccessRulesProtected 'Install directory still inherits ACL entries.'
    $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    $requiredSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    foreach ($sid in $requiredSids) {
        Assert-True ($rules.IdentityReference.Value -contains $sid) "Required ACL principal is missing: $sid"
    }

    $status = & (Join-Path $installRoot 'status.ps1')
    Assert-True (-not $status.Running) 'NoStart installation unexpectedly started the clipboard agent.'
    Assert-True ($status.PendingMacToWindows -eq 0) 'Fresh inbox is not empty.'
    Assert-True ($status.PendingWindowsToMac -eq 0) 'Fresh outbound queue is not empty.'

    $relayRoot = Join-Path $testRoot 'relay'
    New-Item -ItemType Directory -Path $relayRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows\remote.ps1') -Destination $relayRoot
    $windowsId = [Guid]::NewGuid().ToString('N')
    $macId = [Guid]::NewGuid().ToString('N')
    $windowsBytes = [Text.Encoding]::UTF8.GetBytes('controlled-windows-direction')
    $macBytes = [Text.Encoding]::UTF8.GetBytes('controlled-mac-direction')
    [IO.File]::WriteAllBytes((Join-Path $relayRoot "outbound.$windowsId.msg"), $windowsBytes)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $relayRoot 'remote.ps1') + '" stream'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    Assert-True $process.Start() 'Could not start the isolated stream relay.'

    $line = Read-LineWithTimeout $process 3000 'Windows-to-Mac frame'
    $expected = 'SET ' + $windowsId + ' ' + [Convert]::ToBase64String($windowsBytes)
    Assert-True ($line -eq $expected) 'Windows-to-Mac protocol frame mismatch.'

    $process.StandardInput.WriteLine("ACK $windowsId")
    $process.StandardInput.WriteLine(('SET ' + $macId + ' ' + [Convert]::ToBase64String($macBytes)))
    $process.StandardInput.Flush()

    $receivedAck = $false
    for ($attempt = 0; $attempt -lt 4 -and -not $receivedAck; $attempt++) {
        $line = Read-LineWithTimeout $process 3000 'Mac-to-Windows acknowledgement'
        if ($line -eq "ACK $macId") {
            $receivedAck = $true
        }
    }
    Assert-True $receivedAck 'Mac-to-Windows acknowledgement was not received.'

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $outboundPath = Join-Path $relayRoot "outbound.$windowsId.msg"
    while ((Test-Path -LiteralPath $outboundPath) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    Assert-True (-not (Test-Path -LiteralPath $outboundPath)) 'Acknowledged outbound payload remains.'

    $receivedBytes = [IO.File]::ReadAllBytes((Join-Path $relayRoot "inbox\$macId.msg"))
    Assert-True (
        [Convert]::ToBase64String($receivedBytes) -eq [Convert]::ToBase64String($macBytes)
    ) 'Mac-to-Windows payload mismatch.'

    $process.StandardInput.Close()
    Assert-True $process.WaitForExit(3000) 'Relay did not stop when stdin closed.'
    Assert-True ($process.ExitCode -eq 0) ('Relay failed: ' + $process.StandardError.ReadToEnd())
    $process.Dispose()
    $process = $null

    & (Join-Path $installRoot 'uninstall.ps1') `
        -InstallRoot $installRoot `
        -StartupDirectory $startupRoot
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Uninstall left the application directory.'
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'Uninstall left the startup shortcut.'

    Write-Output 'PASS Windows isolated install, optional autostart, ACL, status, protocol, and uninstall'
} finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            $process.Kill()
        }
        $process.Dispose()
    }

    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if (
        $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTest) -like 'mwsc-validation-*'
    ) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue
    }
}
