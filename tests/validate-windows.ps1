$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mwsc-validation-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot 'installed'
$startupRoot = Join-Path $testRoot 'startup'
$receiveRoot = Join-Path $testRoot 'downloads'
$recoveryTaskName = 'MacWinClip Validation ' + [Guid]::NewGuid().ToString('N')
$process = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

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
        -ReceiveRoot $receiveRoot `
        -RecoveryTaskName $recoveryTaskName `
        -NoStart

    foreach ($name in 'agent.ps1', 'file-worker.ps1', 'lazy-files.cs', 'progress.ps1', 'remote.ps1', 'start.ps1', 'stop.ps1', 'supervisor.ps1', 'status.ps1', 'uninstall.ps1', 'receive-root.txt', 'recovery-task-name.txt') {
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot $name)) "Missing installed file: $name"
    }

    $shortcutPath = Join-Path $startupRoot 'MacWindowsSSHClipboard.lnk'
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'Legacy startup shortcut was left installed.'
    Assert-True (
        (Invoke-TaskScheduler @('/Query', '/TN', $recoveryTaskName)) -eq 0
    ) 'Interactive recovery task was not created.'

    & (Join-Path $projectRoot 'windows\install.ps1') `
        -InstallRoot $installRoot `
        -StartupDirectory $startupRoot `
        -ReceiveRoot $receiveRoot `
        -RecoveryTaskName $recoveryTaskName `
        -NoStart `
        -NoAutoStart
    Assert-True (
        (Invoke-TaskScheduler @('/Query', '/TN', $recoveryTaskName)) -ne 0
    ) 'NoAutoStart left the recovery task installed.'

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
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows\file-worker.ps1') -Destination $relayRoot
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot 'receive-root.txt'),
        $receiveRoot,
        [Text.UTF8Encoding]::new($false)
    )
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

    $windowsFilesId = [Guid]::NewGuid().ToString('N')
    $fileRequestRoot = Join-Path $relayRoot 'file-requests'
    New-Item -ItemType Directory -Force -Path $fileRequestRoot | Out-Null
    $unicodeFileName = [Text.RegularExpressions.Regex]::Unescape(
        '\u5496\u5561\u5e97\u8bc4\u5206\u8868.csv'
    )
    $controlledFile = Join-Path $testRoot $unicodeFileName
    $controlledBytes = [byte[]](0..255)
    [IO.File]::WriteAllBytes($controlledFile, $controlledBytes)
    $request = [ordered]@{
        id = $windowsFilesId
        sources = @($controlledFile)
    }
    [IO.File]::WriteAllText(
        (Join-Path $fileRequestRoot "$windowsFilesId.json"),
        ($request | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $relayRoot 'file-worker.ps1') `
        -Mode PrepareOutbound `
        -MessageId $windowsFilesId

    $filesMessage = Join-Path $relayRoot "outbound.$windowsFilesId.files.msg"
    Assert-True (Test-Path -LiteralPath $filesMessage) 'Windows file manifest was not queued.'
    $filesManifestBytes = [IO.File]::ReadAllBytes($filesMessage)
    $filesManifest = [Text.Encoding]::UTF8.GetString($filesManifestBytes) | ConvertFrom-Json
    Assert-True ([int64]$filesManifest.totalBytes -eq $controlledBytes.Length) 'Windows file manifest total is wrong.'
    Assert-True ([string]$filesManifest.files[0].name -eq $unicodeFileName) 'Windows Unicode file name was corrupted.'
    $windowsPayload = Join-Path $relayRoot "outgoing\$windowsFilesId\000000.payload"
    Assert-True (Test-Path -LiteralPath $windowsPayload) 'Windows file payload was not staged.'
    Assert-True (
        (Get-FileHash -LiteralPath $windowsPayload -Algorithm SHA256).Hash.ToLowerInvariant() -eq
        [string]$filesManifest.files[0].sha256
    ) 'Windows staged file hash is wrong.'

    $expected = 'SET ' + $windowsFilesId + ' FILES ' +
        [Convert]::ToBase64String($filesManifestBytes)
    Wait-ForProtocolLine $process $expected 'Windows-to-Mac file manifest frame'
    $ack = & (Join-Path $relayRoot 'remote.ps1') ack $windowsFilesId
    Assert-True ($ack -eq "ACK $windowsFilesId") 'Windows file acknowledgement failed.'
    Assert-True (-not (Test-Path -LiteralPath $windowsPayload)) 'Acknowledged Windows file payload remains.'

    $macFilesId = [Guid]::NewGuid().ToString('N')
    $macFileHash = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash($controlledBytes)
    ).Replace('-', '').ToLowerInvariant()
    $macManifest = [ordered]@{
        version = 1
        id = $macFilesId
        totalBytes = $controlledBytes.Length
        files = @(
            [ordered]@{
                index = 0
                name = $unicodeFileName
                size = $controlledBytes.Length
                sha256 = $macFileHash
            }
        )
    }
    $macOffer = [ordered]@{
        version = 1
        id = $macFilesId
        totalBytes = $controlledBytes.Length
        files = @(
            [ordered]@{
                index = 0
                name = $unicodeFileName
                size = $controlledBytes.Length
                sha256 = ''
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$macFilesId.files.tmp"),
        ($macOffer | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $offered = & (Join-Path $relayRoot 'remote.ps1') offer-files $macFilesId
    Assert-True ($offered -eq "OFFERED $macFilesId") 'Windows did not accept the lazy file offer.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "inbox\$macFilesId.files-offer.msg")
    ) 'Lazy file offer was not queued for the GUI agent.'
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path $receiveRoot "MacWinClip\$macFilesId"))
    ) 'File bytes arrived before a paste demand.'

    Add-Type -Path (Join-Path $projectRoot 'windows\lazy-files.cs')
    $lazyObject = [MacWinClip.LazyFileDataObject]::new(
        $macFilesId,
        [string[]]@($unicodeFileName),
        [int64[]]@($controlledBytes.Length),
        (Join-Path $relayRoot 'file-demands'),
        (Join-Path $receiveRoot 'MacWinClip'),
        (Join-Path $testRoot 'no-progress-ui-in-isolated-test.ps1'),
        (Join-Path $relayRoot 'progress'),
        (Join-Path $relayRoot 'cancel')
    )
    $formatEnumerator = $lazyObject.EnumFormatEtc(
        [Runtime.InteropServices.ComTypes.DATADIR]::DATADIR_GET
    )
    $formats = [Runtime.InteropServices.ComTypes.FORMATETC[]]::new(3)
    $fetched = [int[]]::new(1)
    $enumResult = $formatEnumerator.Next(3, $formats, $fetched)
    Assert-True ($enumResult -eq 0 -and $fetched[0] -eq 3) 'Lazy clipboard formats are incomplete.'
    $descriptorFormat = $formats[0]
    $descriptorMedium = [Runtime.InteropServices.ComTypes.STGMEDIUM]::new()
    $lazyObject.GetData([ref]$descriptorFormat, [ref]$descriptorMedium)
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path $relayRoot "file-demands\$macFilesId.request"))
    ) 'Reading file metadata incorrectly triggered the file transfer.'

    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "file-demands\$macFilesId.request"),
        'fetch',
        [Text.UTF8Encoding]::new($false)
    )
    Wait-ForProtocolLine $process "FETCH $macFilesId" 'Mac-to-Windows lazy file demand'

    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$macFilesId.files.tmp"),
        ($macManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $ready = & (Join-Path $relayRoot 'remote.ps1') begin-files $macFilesId
    Assert-True ($ready -eq "READY $macFilesId") 'Windows file receiver did not become ready.'
    $incomingPart = Join-Path $relayRoot "incoming\$macFilesId\000000.part"
    [IO.File]::WriteAllBytes($incomingPart, $controlledBytes)
    $partSize = & (Join-Path $relayRoot 'remote.ps1') file-size $macFilesId 0 0
    Assert-True ([int64]$partSize -eq $controlledBytes.Length) 'Windows incoming file progress is wrong.'
    $ack = & (Join-Path $relayRoot 'remote.ps1') commit-files $macFilesId
    Assert-True ($ack -eq "ACK $macFilesId") 'Windows incoming file commit failed.'
    $fileClipboardMessage = Join-Path $relayRoot "inbox\$macFilesId.files.msg"
    Assert-True (-not (Test-Path -LiteralPath $fileClipboardMessage)) 'Lazy transfer replaced the virtual clipboard with an eager file list.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "file-demands\$macFilesId.done")
    ) 'Lazy file completion marker is missing.'
    $receivedFile = Join-Path (Join-Path $receiveRoot "MacWinClip\$macFilesId") $unicodeFileName
    Assert-True (Test-Path -LiteralPath $receivedFile) 'Windows received file is missing.'
    Assert-True (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($receivedFile)) -eq
        [Convert]::ToBase64String($controlledBytes)
    ) 'Windows received file payload mismatch.'
    $unicodeState = Get-Content -LiteralPath (Join-Path $relayRoot "progress\$macFilesId.json") `
        -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ([string]$unicodeState.name -eq $unicodeFileName) 'Windows progress state corrupted a Unicode file name.'
    $contentFormat = $formats[1]
    $contentFormat.lindex = 0
    $contentMedium = [Runtime.InteropServices.ComTypes.STGMEDIUM]::new()
    $lazyObject.GetData([ref]$contentFormat, [ref]$contentMedium)
    Assert-True (
        $contentMedium.tymed -eq [Runtime.InteropServices.ComTypes.TYMED]::TYMED_ISTREAM -and
        $contentMedium.unionmember -ne [IntPtr]::Zero
    ) 'Lazy clipboard did not return a file stream after transfer completion.'
    [void][Runtime.InteropServices.Marshal]::Release($contentMedium.unionmember)

    $dropped = & (Join-Path $relayRoot 'remote.ps1') drop-offer $macFilesId
    Assert-True ($dropped -eq "ACK $macFilesId") 'Lazy file offer dismissal was not acknowledged.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "inbox\$macFilesId.files-dismiss.msg")
    ) 'Lazy file offer dismissal was not queued for the GUI agent.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "file-demands\$macFilesId.failed")
    ) 'Lazy file offer dismissal did not create a failure marker.'

    $unsafeFilesId = [Guid]::NewGuid().ToString('N')
    $unsafeManifest = [ordered]@{
        version = 1
        id = $unsafeFilesId
        totalBytes = 1
        files = @(
            [ordered]@{
                index = 0
                name = '..\escape.bin'
                size = 1
                sha256 = ('0' * 64)
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$unsafeFilesId.files.tmp"),
        ($unsafeManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $unsafeRejected = $false
    try {
        & (Join-Path $relayRoot 'remote.ps1') begin-files $unsafeFilesId
    } catch {
        $unsafeRejected = $true
    }
    Assert-True $unsafeRejected 'Path traversal file name was accepted.'

    $oversizeFilesId = [Guid]::NewGuid().ToString('N')
    $oversizeManifest = [ordered]@{
        version = 1
        id = $oversizeFilesId
        totalBytes = 10737418241
        files = @(
            [ordered]@{
                index = 0
                name = 'oversize.bin'
                size = 10737418241
                sha256 = ('0' * 64)
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$oversizeFilesId.files.tmp"),
        ($oversizeManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $oversizeRejected = $false
    try {
        & (Join-Path $relayRoot 'remote.ps1') begin-files $oversizeFilesId
    } catch {
        $oversizeRejected = $true
    }
    Assert-True $oversizeRejected 'A file manifest over 10 GiB was accepted.'

    if (-not $process.HasExited) {
        $process.Kill()
        [void]$process.WaitForExit(3000)
    }
    $process.Dispose()
    $process = $null

    & (Join-Path $installRoot 'uninstall.ps1') `
        -InstallRoot $installRoot `
        -StartupDirectory $startupRoot `
        -RecoveryTaskName $recoveryTaskName
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Uninstall left the application directory.'
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'Uninstall left the startup shortcut.'

    Write-Output 'PASS Windows isolated install, autostart, ACL, text/image/lazy-file protocol, limits, and uninstall'
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
    [void](Invoke-TaskScheduler @('/Delete', '/TN', $recoveryTaskName, '/F'))
}
