param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        'health',
        'stream',
        'receive',
        'offer-files',
        'drop-offer',
        'ack-file-event',
        'fetch-files',
        'drop-outbound',
        'ack',
        'begin-files',
        'commit-files',
        'progress',
        'file-size',
        'cancel-files',
        'fail-files'
    )]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$MessageId,

    [Parameter(Position = 2)]
    [string]$Argument,

    [Parameter(Position = 3)]
    [string]$Extra
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
$outgoingRoot = Join-Path $root 'outgoing'
$requestRoot = Join-Path $root 'file-requests'
$outboundOfferRoot = Join-Path $root 'outbound-file-offers'
$outboundDemandRoot = Join-Path $root 'outbound-file-demands'
$incomingRoot = Join-Path $root 'incoming'
$progressRoot = Join-Path $root 'progress'
$cancelRoot = Join-Path $root 'cancel'
$offerRoot = Join-Path $root 'file-offers'
$demandRoot = Join-Path $root 'file-demands'
$dismissRoot = Join-Path $root 'file-dismissals'
$receiveRootFile = Join-Path $root 'receive-root.txt'
$maxTextBytes = 1048576
$maxImageBytes = 16777216
$maxManifestBytes = 1048576
$maxFileBytes = [int64]10737418240

foreach ($directory in $inboxRoot, $outgoingRoot, $requestRoot, $outboundOfferRoot, $outboundDemandRoot, $incomingRoot, $progressRoot, $cancelRoot, $offerRoot, $demandRoot, $dismissRoot) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

function Assert-MessageId([string]$Value) {
    if ($Value -notmatch '^[a-f0-9]{32}$') {
        throw 'Invalid message id.'
    }
}

function Enter-MessageMutex([string]$Id) {
    $mutex = [Threading.Mutex]::new($false, "Local\MacWinClipFile_$Id")
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw 'Timed out waiting for the file-transfer lock.'
    }
    return $mutex
}

function Exit-MessageMutex([Threading.Mutex]$Mutex) {
    try {
        $Mutex.ReleaseMutex()
    } finally {
        $Mutex.Dispose()
    }
}

function Get-TypeLimit([string]$PayloadType) {
    if ($PayloadType -eq 'PNG') {
        return $maxImageBytes
    }
    if ($PayloadType -eq 'FILES') {
        return $maxManifestBytes
    }
    return $maxTextBytes
}

function Send-ProtocolLine([string]$Line) {
    [Console]::Out.WriteLine($Line)
    [Console]::Out.Flush()
}

function Get-StatePath([string]$Id) {
    return Join-Path $progressRoot "$Id.json"
}

function Write-State(
    [string]$Id,
    [string]$Stage,
    [int64]$Transferred,
    [int64]$Total,
    [string]$Name,
    [string]$Message,
    [string]$Direction
) {
    $path = Get-StatePath $Id
    $state = [ordered]@{
        stage = $Stage
        direction = $Direction
        transferred = $Transferred
        total = $Total
        name = $Name
        message = $Message
        updatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = "$path.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($state | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Read-State([string]$Id) {
    $path = Get-StatePath $Id
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Remove-Outbound([string]$Id) {
    Get-ChildItem -LiteralPath $root -Filter "outbound.$Id.*.msg" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root "outbound.$Id.msg") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $outgoingRoot $Id) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath `
        (Join-Path $requestRoot "$Id.json"), `
        (Join-Path $outboundOfferRoot "$Id.json"), `
        (Join-Path $outboundDemandRoot "$Id.request"), `
        (Join-Path $outboundDemandRoot "$Id.started") `
        -Force -ErrorAction SilentlyContinue
}

function Read-Manifest(
    [string]$Path,
    [string]$ExpectedId,
    [switch]$AllowMissingHash
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'File manifest is missing.'
    }
    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -le 0 -or $length -gt $maxManifestBytes) {
        throw 'File manifest size is invalid.'
    }

    $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.version -ne 2 -or [string]$manifest.id -ne $ExpectedId) {
        throw 'File manifest version or id is invalid.'
    }

    $files = @($manifest.files)
    if ($files.Count -eq 0 -or $files.Count -gt 1000) {
        throw 'File manifest item count is invalid.'
    }

    $total = [int64]0
    $entryKinds = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $name = [string]$file.name
        $kind = [string]$file.kind
        $size = [int64]$file.size
        $hash = [string]$file.sha256
        if ([int]$file.index -ne $index) {
            throw 'File manifest index is invalid.'
        }
        if (
            [string]::IsNullOrWhiteSpace($name) -or
            $name.Length -gt 259 -or
            $name.StartsWith('/') -or
            $name.Contains('\') -or
            $kind -notin 'file', 'directory' -or
            $entryKinds.ContainsKey($name)
        ) {
            throw 'File manifest name is invalid.'
        }
        $components = @($name.Split('/'))
        if ($components.Count -eq 0 -or $components -contains '' -or $components -contains '.' -or $components -contains '..') {
            throw 'File manifest path is invalid.'
        }
        foreach ($component in $components) {
            if (
                [string]::IsNullOrWhiteSpace($component) -or
                [Text.Encoding]::UTF8.GetByteCount($component) -gt 255 -or
                $component.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                $component.EndsWith('.') -or
                $component.EndsWith(' ') -or
                $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|$)'
            ) {
                throw 'File manifest path component is invalid.'
            }
        }
        if ($components.Count -gt 1) {
            $parent = [string]::Join('/', $components[0..($components.Count - 2)])
            if (-not $entryKinds.ContainsKey($parent) -or $entryKinds[$parent] -ne 'directory') {
                throw 'File manifest parent directory is missing.'
            }
        }

        if ($kind -eq 'directory') {
            if ($size -ne 0 -or $hash -ne '') {
                throw 'Directory manifest entry is invalid.'
            }
        } else {
            $validHash = $hash -match '^[a-f0-9]{64}$' -or ($AllowMissingHash -and $hash -eq '')
            if ($size -lt 0 -or -not $validHash) {
                throw 'File manifest size or hash is invalid.'
            }
            if ($size -gt ($maxFileBytes - $total)) {
                throw 'File manifest exceeds the 10 GiB limit.'
            }
            $total += $size
        }
        $entryKinds.Add($name, $kind)
    }

    if ([int64]$manifest.totalBytes -ne $total) {
        throw 'File manifest total is invalid.'
    }
    return $manifest
}

function Assert-ReceivePaths($Manifest, [string]$Id) {
    if (-not (Test-Path -LiteralPath $receiveRootFile -PathType Leaf)) {
        throw 'Receive directory configuration is missing.'
    }
    $configuredRoot = [IO.Path]::GetFullPath(
        (Get-Content -LiteralPath $receiveRootFile -Raw -Encoding UTF8).Trim()
    )
    $destination = Join-Path (Join-Path $configuredRoot 'MacWinClip') "$Id.partial"
    $destinationPrefix = $destination.TrimEnd('\') + '\'
    foreach ($file in @($Manifest.files)) {
        $relative = ([string]$file.name).Replace(
            [char]'/', [IO.Path]::DirectorySeparatorChar
        )
        $full = [IO.Path]::GetFullPath((Join-Path $destination $relative))
        if (
            $full.Length -gt 259 -or
            -not $full.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)
        ) {
            throw 'A received item path is unsafe or too long for Windows PowerShell 5.1.'
        }
    }
}

if ($Action -eq 'health') {
    $pidFile = Join-Path $root 'agent.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) {
        exit 1
    }
    try {
        $agentPid = [int](Get-Content -LiteralPath $pidFile -Raw)
        $agentProcess = Get-Process -Id $agentPid -ErrorAction Stop
    } catch {
        exit 1
    }
    if ($agentProcess.SessionId -eq 0) {
        exit 1
    }
    Write-Output "OK V7 $($agentProcess.SessionId)"
    exit 0
}

if ($Action -eq 'ack-file-event') {
    Assert-MessageId $MessageId
    if ($Argument -notin 'offer', 'failed', 'withdraw') {
        throw 'Invalid file event.'
    }
    Remove-Item -LiteralPath (Join-Path $root "outbound.$MessageId.files-$Argument.msg") -Force -ErrorAction SilentlyContinue
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'fetch-files') {
    Assert-MessageId $MessageId
    if (
        -not (Test-Path -LiteralPath (Join-Path $requestRoot "$MessageId.json") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $outboundOfferRoot "$MessageId.json") -PathType Leaf)
    ) {
        throw 'The Windows file offer is no longer available.'
    }
    if (
        -not (Test-Path -LiteralPath (Join-Path $root "outbound.$MessageId.files.msg") -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $outboundDemandRoot "$MessageId.started") -PathType Leaf)
    ) {
        [IO.File]::WriteAllText(
            (Join-Path $outboundDemandRoot "$MessageId.request"),
            'fetch',
            [Text.UTF8Encoding]::new($false)
        )
    }
    Write-Output "FETCHING $MessageId"
    exit 0
}

if ($Action -eq 'drop-outbound') {
    Assert-MessageId $MessageId
    [IO.File]::WriteAllText(
        (Join-Path $cancelRoot "$MessageId.request"),
        'cancel',
        [Text.UTF8Encoding]::new($false)
    )
    Remove-Outbound $MessageId
    Remove-Item -LiteralPath `
        (Join-Path $root "outbound.$MessageId.files-offer.msg"), `
        (Join-Path $root "outbound.$MessageId.files-failed.msg"), `
        (Join-Path $root "outbound.$MessageId.files-withdraw.msg") `
        -Force -ErrorAction SilentlyContinue
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'ack') {
    Assert-MessageId $MessageId
    $state = Read-State $MessageId
    if ($null -ne $state) {
        Write-State `
            $MessageId `
            'Done' `
            ([int64]$state.total) `
            ([int64]$state.total) `
            ([string]$state.name) `
            'Transfer complete.' `
            ([string]$state.direction)
    }
    Remove-Outbound $MessageId
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'receive') {
    Assert-MessageId $MessageId
    if ($Argument -notin 'TEXT', 'PNG') {
        throw 'Invalid payload type.'
    }
    $typeName = $Argument.ToLowerInvariant()
    $upload = Join-Path $root "upload.$MessageId.$typeName.tmp"
    if (-not (Test-Path -LiteralPath $upload)) {
        throw 'Uploaded payload is missing.'
    }
    $length = (Get-Item -LiteralPath $upload).Length
    $limit = Get-TypeLimit $Argument
    if ($length -eq 0 -or $length -gt $limit) {
        Remove-Item -LiteralPath $upload -Force -ErrorAction SilentlyContinue
        throw 'Uploaded payload size is invalid.'
    }
    $message = Join-Path $inboxRoot "$MessageId.$typeName.msg"
    Move-Item -LiteralPath $upload -Destination $message -Force
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'offer-files') {
    Assert-MessageId $MessageId
    $upload = Join-Path $root "upload.$MessageId.files.tmp"
    $manifest = Read-Manifest $upload $MessageId -AllowMissingHash
    foreach ($file in @($manifest.files)) {
        if (-not [string]::IsNullOrEmpty([string]$file.sha256)) {
            Remove-Item -LiteralPath $upload -Force -ErrorAction SilentlyContinue
            throw 'A file offer must not contain file hashes.'
        }
    }
    Assert-ReceivePaths $manifest $MessageId

    $offer = Join-Path $offerRoot "$MessageId.json"
    $existingOffer = Test-Path -LiteralPath $offer -PathType Leaf
    if ($existingOffer) {
        $previousOffer = Read-Manifest $offer $MessageId -AllowMissingHash
        if (
            [int64]$previousOffer.totalBytes -ne [int64]$manifest.totalBytes -or
            @($previousOffer.files).Count -ne @($manifest.files).Count
        ) {
            throw 'A repeated file offer changed.'
        }
        for ($index = 0; $index -lt @($manifest.files).Count; $index++) {
            if (
                [string]$previousOffer.files[$index].name -ne [string]$manifest.files[$index].name -or
                [string]$previousOffer.files[$index].kind -ne [string]$manifest.files[$index].kind -or
                [int64]$previousOffer.files[$index].size -ne [int64]$manifest.files[$index].size
            ) {
                throw 'A repeated file offer changed.'
            }
        }
    } else {
        foreach ($suffix in 'request', 'done', 'failed', 'canceled') {
            Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.$suffix") -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath `
            (Join-Path $cancelRoot "$MessageId.request"), `
            (Join-Path $cancelRoot "$MessageId.canceled") `
            -Force -ErrorAction SilentlyContinue
    }
    $message = Join-Path $inboxRoot "$MessageId.files-offer.msg"
    Copy-Item -LiteralPath $upload -Destination $offer -Force
    Move-Item -LiteralPath $upload -Destination $message -Force
    Write-Output "OFFERED $MessageId"
    exit 0
}

if ($Action -eq 'drop-offer') {
    Assert-MessageId $MessageId
    $activeTransfer = (
        (Test-Path -LiteralPath (Join-Path $incomingRoot $MessageId)) -or
        (Test-Path -LiteralPath (Join-Path $demandRoot "$MessageId.request"))
    )
    if ($activeTransfer) {
        [IO.File]::WriteAllText(
            (Join-Path $cancelRoot "$MessageId.request"),
            'cancel',
            [Text.UTF8Encoding]::new($false)
        )
    }
    $messageMutex = Enter-MessageMutex $MessageId
    try {
        $state = Read-State $MessageId
        if ($activeTransfer -and ($null -eq $state -or [string]$state.stage -ne 'Done')) {
            [IO.File]::WriteAllText(
                (Join-Path $cancelRoot "$MessageId.canceled"),
                'canceled',
                [Text.UTF8Encoding]::new($false)
            )
        }
        Remove-Item -LiteralPath (Join-Path $offerRoot "$MessageId.json") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $inboxRoot "$MessageId.files-offer.msg") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText(
            (Join-Path $demandRoot "$MessageId.failed"),
            'dismissed',
            [Text.UTF8Encoding]::new($false)
        )
        $temporary = Join-Path $inboxRoot "$MessageId.files-dismiss.tmp"
        $message = Join-Path $inboxRoot "$MessageId.files-dismiss.msg"
        [IO.File]::WriteAllText(
            $temporary,
            'dismiss',
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $message -Force
    } finally {
        Exit-MessageMutex $messageMutex
    }
    Remove-Item -LiteralPath (Join-Path $cancelRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'begin-files') {
    Assert-MessageId $MessageId
    if (Test-Path -LiteralPath (Join-Path $cancelRoot "$MessageId.canceled")) {
        throw 'The file transfer was canceled.'
    }
    $upload = Join-Path $root "upload.$MessageId.files.tmp"
    $manifest = Read-Manifest $upload $MessageId
    Assert-ReceivePaths $manifest $MessageId
    $offerPath = Join-Path $offerRoot "$MessageId.json"
    if (Test-Path -LiteralPath $offerPath -PathType Leaf) {
        $offer = Read-Manifest $offerPath $MessageId -AllowMissingHash
        if (
            [int64]$offer.totalBytes -ne [int64]$manifest.totalBytes -or
            @($offer.files).Count -ne @($manifest.files).Count
        ) {
            throw 'The source files changed after they were copied.'
        }
        for ($index = 0; $index -lt @($manifest.files).Count; $index++) {
            if (
                [string]$offer.files[$index].name -ne [string]$manifest.files[$index].name -or
                [string]$offer.files[$index].kind -ne [string]$manifest.files[$index].kind -or
                [int64]$offer.files[$index].size -ne [int64]$manifest.files[$index].size
            ) {
                throw 'The source files changed after they were copied.'
            }
        }
    }
    $transferRoot = Join-Path $incomingRoot $MessageId
    if (Test-Path -LiteralPath $transferRoot) {
        Remove-Item -LiteralPath $transferRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $transferRoot | Out-Null
    if (Test-Path -LiteralPath $offerPath -PathType Leaf) {
        [IO.File]::WriteAllText(
            (Join-Path $transferRoot 'lazy-offer.flag'),
            'lazy',
            [Text.UTF8Encoding]::new($false)
        )
    }
    Move-Item -LiteralPath $upload -Destination (Join-Path $transferRoot 'manifest.json')
    Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
    $topLevel = @($manifest.files | Where-Object { ([string]$_.name).IndexOf('/') -lt 0 })
    $name = if ($topLevel.Count -eq 1) {
        [string]$topLevel[0].name
    } else {
        "$($topLevel.Count) items"
    }
    Write-State $MessageId 'Transferring' 0 ([int64]$manifest.totalBytes) $name 'Receiving from Mac...' 'Receiving from Mac'
    Write-Output "READY $MessageId"
    exit 0
}

if ($Action -eq 'file-size') {
    Assert-MessageId $MessageId
    if ($Argument -notmatch '^[0-9]{1,6}$') {
        throw 'Invalid file index.'
    }
    if (Test-Path -LiteralPath (Join-Path $cancelRoot "$MessageId.request")) {
        Write-Output 'CANCEL'
        exit 0
    }
    $part = Join-Path (Join-Path $incomingRoot $MessageId) ('{0:d6}.part' -f [int]$Argument)
    if (Test-Path -LiteralPath $part -PathType Leaf) {
        $partSize = [int64](Get-Item -LiteralPath $part).Length
    } else {
        $partSize = [int64]0
    }
    if ($Extra -match '^[0-9]{1,20}$') {
        $state = Read-State $MessageId
        if ($null -ne $state) {
            $overall = [Math]::Min(
                ([int64]$Extra + $partSize),
                [int64]$state.total
            )
            Write-State $MessageId 'Transferring' $overall ([int64]$state.total) ([string]$state.name) 'Receiving from Mac...' ([string]$state.direction)
        }
    }
    Write-Output ([string]$partSize)
    exit 0
}

if ($Action -eq 'progress') {
    Assert-MessageId $MessageId
    if ($Argument -notmatch '^[0-9]{1,20}$' -or $Extra -notin 'Transferring', 'Verifying', 'Done', 'Error', 'Canceled') {
        throw 'Invalid progress update.'
    }
    $state = Read-State $MessageId
    if ($null -eq $state) {
        throw 'Progress state is missing.'
    }
    $transferred = [Math]::Min([int64]$Argument, [int64]$state.total)
    $message = switch ($Extra) {
        'Transferring' { 'Mac is receiving...' }
        'Verifying' { 'Mac is verifying files...' }
        'Done' { 'Transferred to the Mac cache; Finder is finalizing the paste.' }
        'Canceled' { 'Transfer canceled.' }
        default { 'Transfer failed.' }
    }
    Write-State $MessageId $Extra $transferred ([int64]$state.total) ([string]$state.name) $message ([string]$state.direction)
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'cancel-files') {
    Assert-MessageId $MessageId
    [IO.File]::WriteAllText(
        (Join-Path $cancelRoot "$MessageId.request"),
        'cancel',
        [Text.UTF8Encoding]::new($false)
    )
    $messageMutex = Enter-MessageMutex $MessageId
    try {
        $state = Read-State $MessageId
        if ($null -eq $state -or [string]$state.stage -ne 'Done') {
            [IO.File]::WriteAllText(
                (Join-Path $cancelRoot "$MessageId.canceled"),
                'canceled',
                [Text.UTF8Encoding]::new($false)
            )
            Remove-Item -LiteralPath (Join-Path $incomingRoot $MessageId) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Outbound $MessageId
            if (Test-Path -LiteralPath (Join-Path $offerRoot "$MessageId.json")) {
                [IO.File]::WriteAllText(
                    (Join-Path $demandRoot "$MessageId.canceled"),
                    'canceled',
                    [Text.UTF8Encoding]::new($false)
                )
            }
            if ($null -ne $state) {
                Write-State $MessageId 'Canceled' 0 ([int64]$state.total) ([string]$state.name) 'Transfer canceled.' ([string]$state.direction)
            }
        }
    } finally {
        Exit-MessageMutex $messageMutex
    }
    Remove-Item -LiteralPath (Join-Path $cancelRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'fail-files') {
    Assert-MessageId $MessageId
    Remove-Item -LiteralPath (Join-Path $incomingRoot $MessageId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Outbound $MessageId
    if (Test-Path -LiteralPath (Join-Path $offerRoot "$MessageId.json")) {
        [IO.File]::WriteAllText(
            (Join-Path $demandRoot "$MessageId.failed"),
            'failed',
            [Text.UTF8Encoding]::new($false)
        )
    }
    $state = Read-State $MessageId
    if ($null -ne $state) {
        Write-State $MessageId 'Error' 0 ([int64]$state.total) ([string]$state.name) 'Transfer failed.' ([string]$state.direction)
    }
    Remove-Item -LiteralPath (Join-Path $cancelRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'commit-files') {
    Assert-MessageId $MessageId
    $transferRoot = Join-Path $incomingRoot $MessageId
    $manifestPath = Join-Path $transferRoot 'manifest.json'
    $manifest = Read-Manifest $manifestPath $MessageId
    if (-not (Test-Path -LiteralPath $receiveRootFile -PathType Leaf)) {
        throw 'Receive directory configuration is missing.'
    }
    $receiveRoot = [IO.Path]::GetFullPath(
        (Get-Content -LiteralPath $receiveRootFile -Raw -Encoding UTF8).Trim()
    )
    if ([string]::IsNullOrWhiteSpace($receiveRoot)) {
        throw 'Receive directory configuration is invalid.'
    }

    $state = Read-State $MessageId
    $displayName = if ($null -ne $state) { [string]$state.name } else { 'Files' }
    Write-State $MessageId 'Verifying' ([int64]$manifest.totalBytes) ([int64]$manifest.totalBytes) $displayName 'Verifying files...' 'Receiving from Mac'

    foreach ($file in @($manifest.files)) {
        if ([string]$file.kind -eq 'directory') {
            continue
        }
        $part = Join-Path $transferRoot ('{0:d6}.part' -f [int]$file.index)
        if (-not (Test-Path -LiteralPath $part -PathType Leaf)) {
            throw 'A transferred file is missing.'
        }
        if ((Get-Item -LiteralPath $part).Length -ne [int64]$file.size) {
            throw 'A transferred file has the wrong size.'
        }
        $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne [string]$file.sha256) {
            throw 'A transferred file failed SHA-256 verification.'
        }
    }

    $destinationRoot = Join-Path $receiveRoot 'MacWinClip'
    $destination = Join-Path $destinationRoot $MessageId
    $partialDestination = Join-Path $destinationRoot "$MessageId.partial"
    New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
    if (Test-Path -LiteralPath $destination) {
        throw 'The receive destination already exists.'
    }
    Remove-Item -LiteralPath $partialDestination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $partialDestination | Out-Null
    $partialPrefix = $partialDestination.TrimEnd('\') + '\'
    $paths = @()
    $messageMutex = $null
    try {
        foreach ($file in @($manifest.files)) {
            if (
                (Test-Path -LiteralPath (Join-Path $cancelRoot "$MessageId.request")) -or
                (Test-Path -LiteralPath (Join-Path $cancelRoot "$MessageId.canceled"))
            ) {
                throw 'The file transfer was canceled.'
            }
            $relative = ([string]$file.name).Replace(
                [char]'/', [IO.Path]::DirectorySeparatorChar
            )
            $final = [IO.Path]::GetFullPath((Join-Path $partialDestination $relative))
            if (-not $final.StartsWith($partialPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'A manifest path escaped the receive directory.'
            }
            if ([string]$file.kind -eq 'directory') {
                New-Item -ItemType Directory -Force -Path $final | Out-Null
                continue
            }
            $part = Join-Path $transferRoot ('{0:d6}.part' -f [int]$file.index)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $final) | Out-Null
            Move-Item -LiteralPath $part -Destination $final
        }
        foreach ($file in @($manifest.files)) {
            if (([string]$file.name).IndexOf('/') -ge 0) {
                continue
            }
            $relative = ([string]$file.name).Replace(
                [char]'/', [IO.Path]::DirectorySeparatorChar
            )
            $paths += [IO.Path]::GetFullPath((Join-Path $destination $relative))
        }

        $messageMutex = Enter-MessageMutex $MessageId
        if (
            (Test-Path -LiteralPath (Join-Path $cancelRoot "$MessageId.request")) -or
            (Test-Path -LiteralPath (Join-Path $cancelRoot "$MessageId.canceled"))
        ) {
            throw 'The file transfer was canceled.'
        }
        Move-Item -LiteralPath $partialDestination -Destination $destination

        $offerPath = Join-Path $offerRoot "$MessageId.json"
        $lazyTransfer = Test-Path -LiteralPath (Join-Path $transferRoot 'lazy-offer.flag') -PathType Leaf
        if ($lazyTransfer -and (Test-Path -LiteralPath $offerPath -PathType Leaf)) {
            [IO.File]::WriteAllText(
                (Join-Path $demandRoot "$MessageId.done"),
                'done',
                [Text.UTF8Encoding]::new($false)
            )
            Remove-Item -LiteralPath $offerPath -Force
        } elseif ($lazyTransfer) {
            throw 'The lazy file offer was dismissed before commit.'
        } else {
            $clipboardMessage = [ordered]@{
                id = $MessageId
                totalBytes = [int64]$manifest.totalBytes
                paths = $paths
            }
            $temporary = Join-Path $inboxRoot "$MessageId.files.tmp"
            $message = Join-Path $inboxRoot "$MessageId.files.msg"
            [IO.File]::WriteAllText(
                $temporary,
                ($clipboardMessage | ConvertTo-Json -Depth 4 -Compress),
                [Text.UTF8Encoding]::new($false)
            )
            Move-Item -LiteralPath $temporary -Destination $message -Force
        }
        Write-State $MessageId 'Done' ([int64]$manifest.totalBytes) ([int64]$manifest.totalBytes) $displayName 'Transfer complete.' 'Receiving from Mac'
    } catch {
        Remove-Item -LiteralPath $partialDestination -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($null -ne $messageMutex) {
            Exit-MessageMutex $messageMutex
        }
    }
    Remove-Item -LiteralPath $transferRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "ACK $MessageId"
    exit 0
}

$lastSentId = $null
$lastSentAt = [DateTime]::MinValue
$lastPingAt = [DateTime]::MinValue
$deadline = [DateTime]::UtcNow.AddMinutes(5)

while ([DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow
    if (($now - $lastPingAt).TotalSeconds -ge 5) {
        Send-ProtocolLine 'PING'
        $lastPingAt = $now
    }

    $cancelRequest = Get-ChildItem -LiteralPath $cancelRoot -Filter '*.request' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^[a-f0-9]{32}$' } |
        Select-Object -First 1
    if ($null -ne $cancelRequest) {
        Send-ProtocolLine "CANCEL $($cancelRequest.BaseName)"
    }

    $dismissRequest = Get-ChildItem -LiteralPath $dismissRoot -Filter '*.request' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^[a-f0-9]{32}$' } |
        Select-Object -First 1
    if ($null -ne $dismissRequest) {
        $dismissId = $dismissRequest.BaseName
        Send-ProtocolLine "DISMISS $dismissId"
        Remove-Item -LiteralPath $dismissRequest.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath (Join-Path $demandRoot "$dismissId.request"))) {
            Remove-Item -LiteralPath (Join-Path $offerRoot "$dismissId.json") -Force -ErrorAction SilentlyContinue
        }
    }

    $demandRequest = Get-ChildItem -LiteralPath $demandRoot -Filter '*.request' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^[a-f0-9]{32}$' } |
        Select-Object -First 1
    if ($null -ne $demandRequest) {
        Send-ProtocolLine "FETCH $($demandRequest.BaseName)"
    }

    $outbound = Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -ne $outbound) {
        $match = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.(text|png|files|files-offer|files-failed|files-withdraw)\.msg$')
        $legacyMatch = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.msg$')
        if ($match.Success -or $legacyMatch.Success) {
            if ($match.Success) {
                $id = $match.Groups[1].Value
                $payloadType = $match.Groups[2].Value.ToUpperInvariant()
            } else {
                $id = $legacyMatch.Groups[1].Value
                $payloadType = 'TEXT'
            }

            if ($lastSentId -ne $id -or ($now - $lastSentAt).TotalSeconds -ge 1) {
                try {
                    $bytes = [IO.File]::ReadAllBytes($outbound.FullName)
                    $limit = if ($payloadType -in 'FILES-OFFER', 'FILES-FAILED', 'FILES-WITHDRAW') {
                        $maxManifestBytes
                    } else {
                        Get-TypeLimit $payloadType
                    }
                    if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) {
                        Remove-Item -LiteralPath $outbound.FullName -Force -ErrorAction SilentlyContinue
                    } else {
                        if ($payloadType -eq 'FILES-OFFER') {
                            $encoded = [Convert]::ToBase64String($bytes)
                            Send-ProtocolLine "OFFER $id FILES $encoded"
                        } elseif ($payloadType -eq 'FILES-FAILED') {
                            Send-ProtocolLine "FAILED $id FILES"
                        } elseif ($payloadType -eq 'FILES-WITHDRAW') {
                            Send-ProtocolLine "WITHDRAW $id FILES"
                        } else {
                            $encoded = [Convert]::ToBase64String($bytes)
                            Send-ProtocolLine "SET $id $payloadType $encoded"
                        }
                        $lastSentId = $id
                        $lastSentAt = $now
                    }
                } catch [IO.IOException] {
                }
            }
        }
    } else {
        $lastSentId = $null
    }

    Start-Sleep -Milliseconds 50
}
