param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        'health',
        'stream',
        'receive',
        'offer-files',
        'drop-offer',
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

foreach ($directory in $inboxRoot, $outgoingRoot, $incomingRoot, $progressRoot, $cancelRoot, $offerRoot, $demandRoot, $dismissRoot) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

function Assert-MessageId([string]$Value) {
    if ($Value -notmatch '^[a-f0-9]{32}$') {
        throw 'Invalid message id.'
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
    if ([int]$manifest.version -ne 1 -or [string]$manifest.id -ne $ExpectedId) {
        throw 'File manifest version or id is invalid.'
    }

    $files = @($manifest.files)
    if ($files.Count -eq 0 -or $files.Count -gt 1000) {
        throw 'File manifest item count is invalid.'
    }

    $total = [int64]0
    $usedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $name = [string]$file.name
        $size = [int64]$file.size
        $hash = [string]$file.sha256
        if ([int]$file.index -ne $index) {
            throw 'File manifest index is invalid.'
        }
        if (
            [string]::IsNullOrWhiteSpace($name) -or
            $name.Length -gt 259 -or
            [IO.Path]::GetFileName($name) -ne $name -or
            $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $name.EndsWith('.') -or
            $name.EndsWith(' ') -or
            $name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or
            -not $usedNames.Add($name)
        ) {
            throw 'File manifest name is invalid.'
        }
        $validHash = $hash -match '^[a-f0-9]{64}$' -or ($AllowMissingHash -and $hash -eq '')
        if ($size -lt 0 -or -not $validHash) {
            throw 'File manifest size or hash is invalid.'
        }
        if ($size -gt ($maxFileBytes - $total)) {
            throw 'File manifest exceeds the 10 GiB limit.'
        }
        $total += $size
    }

    if ($total -le 0 -or [int64]$manifest.totalBytes -ne $total) {
        throw 'File manifest total is invalid.'
    }
    return $manifest
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
    Write-Output "OK V5 $($agentProcess.SessionId)"
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

    foreach ($suffix in 'request', 'done', 'failed', 'canceled') {
        Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.$suffix") -Force -ErrorAction SilentlyContinue
    }
    $offer = Join-Path $offerRoot "$MessageId.json"
    $message = Join-Path $inboxRoot "$MessageId.files-offer.msg"
    Copy-Item -LiteralPath $upload -Destination $offer -Force
    Move-Item -LiteralPath $upload -Destination $message -Force
    Write-Output "OFFERED $MessageId"
    exit 0
}

if ($Action -eq 'drop-offer') {
    Assert-MessageId $MessageId
    Remove-Item -LiteralPath (Join-Path $offerRoot "$MessageId.json") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $inboxRoot "$MessageId.files-offer.msg") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText(
        (Join-Path $demandRoot "$MessageId.failed"),
        'dismissed',
        [Text.UTF8Encoding]::new($false)
    )
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'begin-files') {
    Assert-MessageId $MessageId
    $upload = Join-Path $root "upload.$MessageId.files.tmp"
    $manifest = Read-Manifest $upload $MessageId
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
    Move-Item -LiteralPath $upload -Destination (Join-Path $transferRoot 'manifest.json')
    Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.request") -Force -ErrorAction SilentlyContinue
    $name = if (@($manifest.files).Count -eq 1) {
        [string]$manifest.files[0].name
    } else {
        "$(@($manifest.files).Count) files"
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
        'Done' { 'Transfer complete.' }
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
    Remove-Item -LiteralPath (Join-Path $incomingRoot $MessageId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Outbound $MessageId
    if (Test-Path -LiteralPath (Join-Path $offerRoot "$MessageId.json")) {
        [IO.File]::WriteAllText(
            (Join-Path $demandRoot "$MessageId.canceled"),
            'canceled',
            [Text.UTF8Encoding]::new($false)
        )
    }
    $state = Read-State $MessageId
    if ($null -ne $state) {
        Write-State $MessageId 'Canceled' 0 ([int64]$state.total) ([string]$state.name) 'Transfer canceled.' ([string]$state.direction)
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

    $destination = Join-Path (Join-Path $receiveRoot 'MacWinClip') $MessageId
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $paths = @()
    foreach ($file in @($manifest.files)) {
        $part = Join-Path $transferRoot ('{0:d6}.part' -f [int]$file.index)
        $final = Join-Path $destination ([string]$file.name)
        Move-Item -LiteralPath $part -Destination $final
        $paths += $final
    }

    $offerPath = Join-Path $offerRoot "$MessageId.json"
    if (Test-Path -LiteralPath $offerPath -PathType Leaf) {
        [IO.File]::WriteAllText(
            (Join-Path $demandRoot "$MessageId.done"),
            'done',
            [Text.UTF8Encoding]::new($false)
        )
        Remove-Item -LiteralPath $offerPath -Force
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
    Remove-Item -LiteralPath $transferRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-State $MessageId 'Done' ([int64]$manifest.totalBytes) ([int64]$manifest.totalBytes) $displayName 'Transfer complete.' 'Receiving from Mac'
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
        $match = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.(text|png|files)\.msg$')
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
                    $limit = Get-TypeLimit $payloadType
                    if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) {
                        Remove-Item -LiteralPath $outbound.FullName -Force -ErrorAction SilentlyContinue
                    } else {
                        $encoded = [Convert]::ToBase64String($bytes)
                        Send-ProtocolLine "SET $id $payloadType $encoded"
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
