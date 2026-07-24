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

function Wait-ForProtocolLine(
    [Diagnostics.Process]$Process,
    [string]$Expected,
    [string]$Stage
) {
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $line = Read-LineWithTimeout $Process 3000 $Stage
        if ($line -eq $Expected) {
            return
        }
    }
    throw "Expected protocol line was not received at $Stage."
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
    $windowsImageId = [Guid]::NewGuid().ToString('N')
    $windowsTextId = [Guid]::NewGuid().ToString('N')
    $macTextId = [Guid]::NewGuid().ToString('N')
    $macImageId = [Guid]::NewGuid().ToString('N')
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new(2, 2)
    $imageMemory = [IO.MemoryStream]::new()
    try {
        $bitmap.SetPixel(0, 0, [Drawing.Color]::Red)
        $bitmap.SetPixel(1, 1, [Drawing.Color]::Blue)
        $bitmap.Save($imageMemory, [Drawing.Imaging.ImageFormat]::Png)
        $windowsBytes = $imageMemory.ToArray()
    } finally {
        $imageMemory.Dispose()
        $bitmap.Dispose()
    }
    $windowsTextBytes = [Text.Encoding]::UTF8.GetBytes('controlled-windows-text-direction')
    $macTextBytes = [Text.Encoding]::UTF8.GetBytes('controlled-mac-text-direction')
    $macImageBytes = $windowsBytes
    [IO.File]::WriteAllBytes(
        (Join-Path $relayRoot "outbound.$windowsImageId.png.msg"),
        $windowsBytes
    )

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

    $expected = 'SET ' + $windowsImageId + ' PNG ' + [Convert]::ToBase64String($windowsBytes)
    Wait-ForProtocolLine $process $expected 'Windows-to-Mac image frame'

    $ack = & (Join-Path $relayRoot 'remote.ps1') ack $windowsImageId
    Assert-True ($ack -eq "ACK $windowsImageId") 'Windows image acknowledgement failed.'

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $outboundPath = Join-Path $relayRoot "outbound.$windowsImageId.png.msg"
    while ((Test-Path -LiteralPath $outboundPath) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    Assert-True (-not (Test-Path -LiteralPath $outboundPath)) 'Acknowledged outbound payload remains.'

    [IO.File]::WriteAllBytes(
        (Join-Path $relayRoot "upload.$macTextId.text.tmp"),
        $macTextBytes
    )
    $ack = & (Join-Path $relayRoot 'remote.ps1') receive $macTextId TEXT
    Assert-True ($ack -eq "ACK $macTextId") 'Mac text receipt was not acknowledged.'

    $receivedBytes = [IO.File]::ReadAllBytes(
        (Join-Path $relayRoot "inbox\$macTextId.text.msg")
    )
    Assert-True (
        [Convert]::ToBase64String($receivedBytes) -eq [Convert]::ToBase64String($macTextBytes)
    ) 'Mac-to-Windows text payload mismatch.'

    [IO.File]::WriteAllBytes(
        (Join-Path $relayRoot "outbound.$windowsTextId.text.msg"),
        $windowsTextBytes
    )
    $expected = 'SET ' + $windowsTextId + ' TEXT ' +
        [Convert]::ToBase64String($windowsTextBytes)
    Wait-ForProtocolLine $process $expected 'Windows-to-Mac text frame'
    $ack = & (Join-Path $relayRoot 'remote.ps1') ack $windowsTextId
    Assert-True ($ack -eq "ACK $windowsTextId") 'Windows text acknowledgement failed.'

    [IO.File]::WriteAllBytes(
        (Join-Path $relayRoot "upload.$macImageId.png.tmp"),
        $macImageBytes
    )
    $ack = & (Join-Path $relayRoot 'remote.ps1') receive $macImageId PNG
    Assert-True ($ack -eq "ACK $macImageId") 'Mac image receipt was not acknowledged.'

    $receivedBytes = [IO.File]::ReadAllBytes(
        (Join-Path $relayRoot "inbox\$macImageId.png.msg")
    )
    Assert-True (
        [Convert]::ToBase64String($receivedBytes) -eq [Convert]::ToBase64String($macImageBytes)
    ) 'Mac-to-Windows image payload mismatch.'

    if (-not $process.HasExited) {
        $process.Kill()
        [void]$process.WaitForExit(3000)
    }
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
