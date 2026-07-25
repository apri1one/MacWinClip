$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mwsc-validation-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot 'installed'
$startupRoot = Join-Path $testRoot 'startup'
$receiveRoot = Join-Path $testRoot 'downloads'
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
        -ReceiveRoot $receiveRoot `
        -NoStart

    foreach ($name in 'agent.ps1', 'file-worker.ps1', 'lazy-files.cs', 'progress.ps1', 'remote.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'uninstall.ps1', 'receive-root.txt') {
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot $name)) "Missing installed file: $name"
    }

    $shortcutPath = Join-Path $startupRoot 'MacWindowsSSHClipboard.lnk'
    Assert-True (Test-Path -LiteralPath $shortcutPath) 'Startup shortcut was not created.'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    Assert-True ($shortcut.Arguments -like "*$installRoot\start.ps1*") 'Startup shortcut targets the wrong install.'

    $staleFilesId = [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Force -Path (Join-Path $installRoot 'file-requests') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $installRoot 'outgoing') | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $installRoot "outbound.$staleFilesId.files.msg"),
        '{"version":1}',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $installRoot "file-requests\$staleFilesId.json"),
        '{"version":1}',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $installRoot "inbox\$staleFilesId.files-offer.msg"),
        '{"version":1}',
        [Text.UTF8Encoding]::new($false)
    )

    & (Join-Path $projectRoot 'windows\install.ps1') `
        -InstallRoot $installRoot `
        -StartupDirectory $startupRoot `
        -ReceiveRoot $receiveRoot `
        -NoStart `
        -NoAutoStart
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'NoAutoStart left the startup shortcut installed.'
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path $installRoot "outbound.$staleFilesId.files.msg"))
    ) 'Upgrade left a stale v1 outbound file manifest.'
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path $installRoot "file-requests\$staleFilesId.json"))
    ) 'Upgrade left a stale v1 file request.'
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path $installRoot "inbox\$staleFilesId.files-offer.msg"))
    ) 'Upgrade left a stale v1 file offer.'

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
    $controlledRoot = Join-Path $testRoot 'controlled.focusee'
    $controlledEmpty = Join-Path $controlledRoot 'empty'
    New-Item -ItemType Directory -Path $controlledEmpty | Out-Null
    $controlledFile = Join-Path $controlledRoot $unicodeFileName
    $controlledBytes = [byte[]](0..255)
    [IO.File]::WriteAllBytes($controlledFile, $controlledBytes)
    $request = [ordered]@{
        id = $windowsFilesId
        sources = @($controlledRoot)
    }
    [IO.File]::WriteAllText(
        (Join-Path $fileRequestRoot "$windowsFilesId.json"),
        ($request | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $relayRoot 'file-worker.ps1') `
        -Mode OfferOutbound `
        -MessageId $windowsFilesId

    $offerMessage = Join-Path $relayRoot "outbound.$windowsFilesId.files-offer.msg"
    Assert-True (Test-Path -LiteralPath $offerMessage) 'Windows file offer was not queued.'
    $offerManifestBytes = [IO.File]::ReadAllBytes($offerMessage)
    $offerManifest = [Text.Encoding]::UTF8.GetString($offerManifestBytes) | ConvertFrom-Json
    Assert-True ([int64]$offerManifest.totalBytes -eq $controlledBytes.Length) 'Windows file offer total is wrong.'
    Assert-True (@($offerManifest.files | Where-Object { -not [string]::IsNullOrEmpty([string]$_.sha256) }).Count -eq 0) 'Windows file offer exposed payload hashes.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $relayRoot "outgoing\$windowsFilesId"))) 'Windows staged file bytes before a paste request.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $relayRoot "progress\$windowsFilesId.json"))) 'Windows opened transfer progress before a paste request.'

    $expected = 'OFFER ' + $windowsFilesId + ' FILES ' +
        [Convert]::ToBase64String($offerManifestBytes)
    Wait-ForProtocolLine $process $expected 'Windows-to-Mac file offer frame'
    $ack = & (Join-Path $relayRoot 'remote.ps1') ack-file-event $windowsFilesId offer
    Assert-True ($ack -eq "ACK $windowsFilesId") 'Windows file offer acknowledgement failed.'

    $fetch = & (Join-Path $relayRoot 'remote.ps1') fetch-files $windowsFilesId
    Assert-True ($fetch -eq "FETCHING $windowsFilesId") 'Windows file fetch request was rejected.'
    Assert-True (Test-Path -LiteralPath (Join-Path $relayRoot "outbound-file-demands\$windowsFilesId.request")) 'Windows file fetch demand was not recorded.'
    & (Join-Path $relayRoot 'file-worker.ps1') `
        -Mode PrepareOutbound `
        -MessageId $windowsFilesId

    $filesMessage = Join-Path $relayRoot "outbound.$windowsFilesId.files.msg"
    Assert-True (Test-Path -LiteralPath $filesMessage) 'Windows file manifest was not queued.'
    $filesManifestBytes = [IO.File]::ReadAllBytes($filesMessage)
    $filesManifest = [Text.Encoding]::UTF8.GetString($filesManifestBytes) | ConvertFrom-Json
    Assert-True ([int64]$filesManifest.totalBytes -eq $controlledBytes.Length) 'Windows file manifest total is wrong.'
    Assert-True ([int]$filesManifest.version -eq 2) 'Windows directory manifest version is wrong.'
    Assert-True (@($filesManifest.files | Where-Object { $_.kind -eq 'directory' }).Count -eq 2) 'Windows empty directory was not preserved.'
    $windowsFileEntry = @($filesManifest.files | Where-Object { $_.kind -eq 'file' })[0]
    Assert-True ([string]$windowsFileEntry.name -eq "controlled.focusee/$unicodeFileName") 'Windows Unicode nested file name was corrupted.'
    $windowsPayloadName = '{0:d6}.payload' -f [int]$windowsFileEntry.index
    $windowsPayload = Join-Path (Join-Path $relayRoot "outgoing\$windowsFilesId") $windowsPayloadName
    Assert-True (Test-Path -LiteralPath $windowsPayload) 'Windows file payload was not staged.'
    Assert-True (
        (Get-FileHash -LiteralPath $windowsPayload -Algorithm SHA256).Hash.ToLowerInvariant() -eq
        [string]$windowsFileEntry.sha256
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
    $macRootName = 'controlled.focusee'
    $macEmptyName = "$macRootName/empty"
    $macNestedName = "$macRootName/$unicodeFileName"
    $macManifest = [ordered]@{
        version = 2
        id = $macFilesId
        totalBytes = $controlledBytes.Length
        files = @(
            [ordered]@{
                index = 0
                name = $macRootName
                kind = 'directory'
                size = 0
                sha256 = ''
            },
            [ordered]@{
                index = 1
                name = $macEmptyName
                kind = 'directory'
                size = 0
                sha256 = ''
            },
            [ordered]@{
                index = 2
                name = $macNestedName
                kind = 'file'
                size = $controlledBytes.Length
                sha256 = $macFileHash
            }
        )
    }
    $macOffer = [ordered]@{
        version = 2
        id = $macFilesId
        totalBytes = $controlledBytes.Length
        files = @(
            [ordered]@{
                index = 0
                name = $macRootName
                kind = 'directory'
                size = 0
                sha256 = ''
            },
            [ordered]@{
                index = 1
                name = $macEmptyName
                kind = 'directory'
                size = 0
                sha256 = ''
            },
            [ordered]@{
                index = 2
                name = $macNestedName
                kind = 'file'
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
        [string[]]@($macRootName, $macEmptyName, $macNestedName),
        [int64[]]@(0, 0, $controlledBytes.Length),
        [bool[]]@($true, $true, $false),
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

    $emptyDirectoryId = [Guid]::NewGuid().ToString('N')
    $emptyDirectoryManifest = [ordered]@{
        version = 2
        id = $emptyDirectoryId
        totalBytes = 0
        files = @(
            [ordered]@{
                index = 0
                name = 'empty-only'
                kind = 'directory'
                size = 0
                sha256 = ''
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$emptyDirectoryId.files.tmp"),
        ($emptyDirectoryManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $emptyOffered = & (Join-Path $relayRoot 'remote.ps1') offer-files $emptyDirectoryId
    Assert-True ($emptyOffered -eq "OFFERED $emptyDirectoryId") 'All-directory offer was rejected.'
    $emptyDirectoryObject = [MacWinClip.LazyFileDataObject]::new(
        $emptyDirectoryId,
        [string[]]@('empty-only'),
        [int64[]]@(0),
        [bool[]]@($true),
        (Join-Path $relayRoot 'file-demands'),
        (Join-Path $receiveRoot 'MacWinClip'),
        (Join-Path $testRoot 'no-progress-ui-in-isolated-test.ps1'),
        (Join-Path $relayRoot 'progress'),
        (Join-Path $relayRoot 'cancel')
    )
    $emptyFormats = [Runtime.InteropServices.ComTypes.FORMATETC[]]::new(3)
    $emptyFetched = [int[]]::new(1)
    [void]$emptyDirectoryObject.EnumFormatEtc(
        [Runtime.InteropServices.ComTypes.DATADIR]::DATADIR_GET
    ).Next(3, $emptyFormats, $emptyFetched)
    $emptyDescriptor = $emptyFormats[0]
    $emptyMedium = [Runtime.InteropServices.ComTypes.STGMEDIUM]::new()
    $emptyDirectoryObject.GetData([ref]$emptyDescriptor, [ref]$emptyMedium)
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "file-demands\$emptyDirectoryId.request")
    ) 'An all-directory offer did not request protocol completion.'
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$emptyDirectoryId.files.tmp"),
        ($emptyDirectoryManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $emptyRetry = & (Join-Path $relayRoot 'remote.ps1') offer-files $emptyDirectoryId
    Assert-True ($emptyRetry -eq "OFFERED $emptyDirectoryId") 'Idempotent offer retry failed.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "file-demands\$emptyDirectoryId.request")
    ) 'Offer retry deleted an active paste demand.'
    Wait-ForProtocolLine $process "FETCH $emptyDirectoryId" 'All-directory lazy demand'
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$emptyDirectoryId.files.tmp"),
        ($emptyDirectoryManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $emptyReady = & (Join-Path $relayRoot 'remote.ps1') begin-files $emptyDirectoryId
    Assert-True ($emptyReady -eq "READY $emptyDirectoryId") 'All-directory receiver did not become ready.'
    $emptyAck = & (Join-Path $relayRoot 'remote.ps1') commit-files $emptyDirectoryId
    Assert-True ($emptyAck -eq "ACK $emptyDirectoryId") 'All-directory commit failed.'
    Assert-True (
        Test-Path -LiteralPath (
            Join-Path $receiveRoot "MacWinClip\$emptyDirectoryId\empty-only"
        ) -PathType Container
    ) 'All-directory transfer did not create the empty directory.'

    $directoryFormat = $formats[1]
    $directoryFormat.lindex = 0
    Assert-True (
        $lazyObject.QueryGetData([ref]$directoryFormat) -ne 0
    ) 'Lazy clipboard incorrectly exposed file contents for a directory.'
    $fileQueryFormat = $formats[1]
    $fileQueryFormat.lindex = 2
    Assert-True (
        $lazyObject.QueryGetData([ref]$fileQueryFormat) -eq 0
    ) 'Lazy clipboard did not expose file contents for a nested file.'

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
    $incomingPart = Join-Path $relayRoot "incoming\$macFilesId\000002.part"
    [IO.File]::WriteAllBytes($incomingPart, $controlledBytes)
    $partSize = & (Join-Path $relayRoot 'remote.ps1') file-size $macFilesId 2 0
    Assert-True ([int64]$partSize -eq $controlledBytes.Length) 'Windows incoming file progress is wrong.'
    $ack = & (Join-Path $relayRoot 'remote.ps1') commit-files $macFilesId
    Assert-True ($ack -eq "ACK $macFilesId") 'Windows incoming file commit failed.'
    $fileClipboardMessage = Join-Path $relayRoot "inbox\$macFilesId.files.msg"
    Assert-True (-not (Test-Path -LiteralPath $fileClipboardMessage)) 'Lazy transfer replaced the virtual clipboard with an eager file list.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "file-demands\$macFilesId.done")
    ) 'Lazy file completion marker is missing.'
    $receivedRoot = Join-Path $receiveRoot "MacWinClip\$macFilesId\$macRootName"
    $receivedFile = Join-Path $receivedRoot $unicodeFileName
    Assert-True (Test-Path -LiteralPath $receivedFile) 'Windows received file is missing.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $receivedRoot 'empty') -PathType Container
    ) 'Windows received empty directory is missing.'
    Assert-True (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($receivedFile)) -eq
        [Convert]::ToBase64String($controlledBytes)
    ) 'Windows received file payload mismatch.'
    $unicodeState = Get-Content -LiteralPath (Join-Path $relayRoot "progress\$macFilesId.json") `
        -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ([string]$unicodeState.name -eq $macRootName) 'Windows progress state corrupted a directory name.'
    $contentFormat = $formats[1]
    $contentFormat.lindex = 2
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
        version = 2
        id = $unsafeFilesId
        totalBytes = 1
        files = @(
            [ordered]@{
                index = 0
                name = 'root/../escape.bin'
                kind = 'file'
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

    $missingParentId = [Guid]::NewGuid().ToString('N')
    $missingParentManifest = [ordered]@{
        version = 2
        id = $missingParentId
        totalBytes = 1
        files = @(
            [ordered]@{
                index = 0
                name = 'missing/child.bin'
                kind = 'file'
                size = 1
                sha256 = ('0' * 64)
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$missingParentId.files.tmp"),
        ($missingParentManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $missingParentRejected = $false
    try {
        & (Join-Path $relayRoot 'remote.ps1') begin-files $missingParentId
    } catch {
        $missingParentRejected = $true
    }
    Assert-True $missingParentRejected 'A child without a directory entry was accepted.'

    $canceledFilesId = [Guid]::NewGuid().ToString('N')
    $cancelAck = & (Join-Path $relayRoot 'remote.ps1') cancel-files $canceledFilesId
    Assert-True ($cancelAck -eq "ACK $canceledFilesId") 'File cancellation was not acknowledged.'
    Assert-True (
        Test-Path -LiteralPath (Join-Path $relayRoot "cancel\$canceledFilesId.canceled")
    ) 'File cancellation did not leave a durable tombstone.'
    $canceledManifest = [ordered]@{
        version = 2
        id = $canceledFilesId
        totalBytes = 0
        files = @(
            [ordered]@{
                index = 0
                name = 'must-not-commit'
                kind = 'directory'
                size = 0
                sha256 = ''
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $relayRoot "upload.$canceledFilesId.files.tmp"),
        ($canceledManifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $canceledBeginRejected = $false
    try {
        & (Join-Path $relayRoot 'remote.ps1') begin-files $canceledFilesId
    } catch {
        $canceledBeginRejected = $true
    }
    Assert-True $canceledBeginRejected 'A canceled transfer was allowed to restart.'

    $oversizeFilesId = [Guid]::NewGuid().ToString('N')
    $oversizeManifest = [ordered]@{
        version = 2
        id = $oversizeFilesId
        totalBytes = 10737418241
        files = @(
            [ordered]@{
                index = 0
                name = 'oversize.bin'
                kind = 'file'
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
        -StartupDirectory $startupRoot
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Uninstall left the application directory.'
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'Uninstall left the startup shortcut.'

    Write-Output 'PASS Windows isolated install, autostart, ACL, text/image/lazy-directory protocol, limits, and uninstall'
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
