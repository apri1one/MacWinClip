param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('OfferOutbound', 'PrepareOutbound')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$MessageId
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$requestRoot = Join-Path $root 'file-requests'
$outgoingRoot = Join-Path $root 'outgoing'
$offerRoot = Join-Path $root 'outbound-file-offers'
$demandRoot = Join-Path $root 'outbound-file-demands'
$progressRoot = Join-Path $root 'progress'
$cancelRoot = Join-Path $root 'cancel'
$requestPath = Join-Path $requestRoot "$MessageId.json"
$transferRoot = Join-Path $outgoingRoot $MessageId
$manifestTemporary = Join-Path $root "outbound.$MessageId.files.tmp"
$manifestPath = Join-Path $root "outbound.$MessageId.files.msg"
$offerTemporary = Join-Path $root "outbound.$MessageId.files-offer.tmp"
$offerMessage = Join-Path $root "outbound.$MessageId.files-offer.msg"
$offerPath = Join-Path $offerRoot "$MessageId.json"
$failedTemporary = Join-Path $root "outbound.$MessageId.files-failed.tmp"
$failedMessage = Join-Path $root "outbound.$MessageId.files-failed.msg"
$demandPath = Join-Path $demandRoot "$MessageId.request"
$demandStartedPath = Join-Path $demandRoot "$MessageId.started"
$statePath = Join-Path $progressRoot "$MessageId.json"
$cancelPath = Join-Path $cancelRoot "$MessageId.request"
$workerPidFile = Join-Path $root "file-worker.$MessageId.pid"
$maxFileBytes = [int64]10737418240

foreach ($directory in $requestRoot, $outgoingRoot, $offerRoot, $demandRoot, $progressRoot, $cancelRoot) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
[IO.File]::WriteAllText(
    $workerPidFile,
    [string]$PID,
    [Text.UTF8Encoding]::new($false)
)

function Write-State(
    [string]$Stage,
    [int64]$Transferred,
    [int64]$Total,
    [string]$Name,
    [string]$Message
) {
    $state = [ordered]@{
        stage = $Stage
        direction = 'Sending to Mac'
        transferred = $Transferred
        total = $Total
        name = $Name
        message = $Message
        updatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = "$statePath.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($state | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
}

function Get-SafeName([string]$Name, [Collections.Generic.HashSet[string]]$UsedNames) {
    $safe = [regex]::Replace($Name, '[\x00-\x1f<>:"/\\|?*]', '_').Trim().TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'file'
    }
    if ($safe -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|$)') {
        $safe = "_$safe"
    }

    $candidate = $safe
    $base = [IO.Path]::GetFileNameWithoutExtension($safe)
    $extension = [IO.Path]::GetExtension($safe)
    $suffix = 2
    while (-not $UsedNames.Add($candidate)) {
        $candidate = "$base ($suffix)$extension"
        $suffix++
    }
    return $candidate
}

function Copy-WithHash(
    [string]$Source,
    [string]$Destination,
    [ref]$Transferred,
    [int64]$Total,
    [string]$DisplayName
) {
    $sourceStream = [IO.File]::Open(
        $Source,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $destinationStream = [IO.File]::Open(
        $Destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    $buffer = [byte[]]::new(1048576)
    $lastUpdate = [DateTime]::MinValue
    try {
        while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (Test-Path -LiteralPath $cancelPath) {
                throw [OperationCanceledException]::new('Transfer canceled.')
            }
            $destinationStream.Write($buffer, 0, $read)
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $Transferred.Value += $read
            if (([DateTime]::UtcNow - $lastUpdate).TotalMilliseconds -ge 250) {
                Write-State 'Preparing' $Transferred.Value $Total $DisplayName 'Preparing files...'
                $lastUpdate = [DateTime]::UtcNow
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $destinationStream.Dispose()
        $sourceStream.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $requestPath)) {
        throw 'File transfer request is missing.'
    }

    $request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sources = @($request.sources)
    if ($sources.Count -eq 0 -or $sources.Count -gt 1000) {
        throw 'File selection must contain between 1 and 1000 items.'
    }

    $items = [Collections.Generic.List[object]]::new()
    $total = [int64]0
    $usedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($source in $sources) {
        $rootItem = Get-Item -LiteralPath ([string]$source) -Force
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Symbolic links and reparse points are not supported.'
        }
        $rootName = Get-SafeName $rootItem.Name $usedNames
        $pending = [Collections.Generic.Queue[object]]::new()
        $pending.Enqueue([pscustomobject]@{
            Source = $rootItem.FullName
            Name = $rootName
        })

        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            $item = Get-Item -LiteralPath $current.Source -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Symbolic links and reparse points are not supported.'
            }
            if ([string]$current.Name -match '(^|/)(\.|\.\.)($|/)' -or ([string]$current.Name).Length -gt 259) {
                throw 'A relative path is unsafe or too long.'
            }
            foreach ($component in ([string]$current.Name).Split('/')) {
                if ([Text.Encoding]::UTF8.GetByteCount($component) -gt 255) {
                    throw 'A path component is too long for macOS.'
                }
            }
            if ($items.Count -ge 1000) {
                throw 'The selected directory tree exceeds the 1000 item limit.'
            }

            if ($item.PSIsContainer) {
                [void]$items.Add([pscustomobject]@{
                    Source = $item.FullName
                    Name = [string]$current.Name
                    Kind = 'directory'
                    Size = [int64]0
                })
                $childNames = [Collections.Generic.HashSet[string]]::new(
                    [StringComparer]::OrdinalIgnoreCase
                )
                $children = @(Get-ChildItem -LiteralPath $item.FullName -Force | Sort-Object Name)
                foreach ($child in $children) {
                    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        throw 'Symbolic links and reparse points are not supported.'
                    }
                    $childName = Get-SafeName $child.Name $childNames
                    $pending.Enqueue([pscustomobject]@{
                        Source = $child.FullName
                        Name = "$($current.Name)/$childName"
                    })
                }
            } else {
                if ([int64]$item.Length -gt ($maxFileBytes - $total)) {
                    throw 'The selected items exceed the 10 GiB transfer limit.'
                }
                $total += [int64]$item.Length
                [void]$items.Add([pscustomobject]@{
                    Source = $item.FullName
                    Name = [string]$current.Name
                    Kind = 'file'
                    Size = [int64]$item.Length
                })
            }
        }
    }

    $displayName = if ($sources.Count -eq 1) { $items[0].Name } else { "$($sources.Count) items" }

    $offerFiles = @()
    for ($index = 0; $index -lt $items.Count; $index++) {
        $offerFiles += [ordered]@{
            index = $index
            name = $items[$index].Name
            kind = $items[$index].Kind
            size = $items[$index].Size
            sha256 = ''
        }
    }
    $offerManifest = [ordered]@{
        version = 2
        id = $MessageId
        totalBytes = $total
        files = $offerFiles
    }

    if ($Mode -eq 'OfferOutbound') {
        if (Test-Path -LiteralPath $cancelPath) {
            throw [OperationCanceledException]::new('Transfer canceled.')
        }
        $offerJson = $offerManifest | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText(
            "$offerPath.tmp",
            $offerJson,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath "$offerPath.tmp" -Destination $offerPath -Force
        [IO.File]::WriteAllText(
            $offerTemporary,
            $offerJson,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $offerTemporary -Destination $offerMessage -Force
        Remove-Item -LiteralPath $workerPidFile -Force -ErrorAction SilentlyContinue
        exit 0
    }

    if (-not (Test-Path -LiteralPath $offerPath -PathType Leaf)) {
        throw 'The file offer is missing.'
    }
    $previousOffer = Get-Content -LiteralPath $offerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if (
        [int]$previousOffer.version -ne 2 -or
        [string]$previousOffer.id -ne $MessageId -or
        [int64]$previousOffer.totalBytes -ne $total -or
        @($previousOffer.files).Count -ne $items.Count
    ) {
        throw 'The selected files changed after they were copied.'
    }
    for ($index = 0; $index -lt $items.Count; $index++) {
        if (
            [int]$previousOffer.files[$index].index -ne $index -or
            [string]$previousOffer.files[$index].name -ne [string]$items[$index].Name -or
            [string]$previousOffer.files[$index].kind -ne [string]$items[$index].Kind -or
            [int64]$previousOffer.files[$index].size -ne [int64]$items[$index].Size
        ) {
            throw 'The selected files changed after they were copied.'
        }
    }

    New-Item -ItemType Directory -Force -Path $transferRoot | Out-Null
    Write-State 'Preparing' 0 $total $displayName 'Preparing files after paste request...'

    $transferred = [int64]0
    $manifestFiles = @()
    for ($index = 0; $index -lt $items.Count; $index++) {
        $hash = ''
        if ($items[$index].Kind -eq 'file') {
            $currentItem = Get-Item -LiteralPath $items[$index].Source -Force
            if (
                $currentItem.PSIsContainer -or
                ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                [int64]$currentItem.Length -ne [int64]$items[$index].Size
            ) {
                throw 'A source file changed after it was selected.'
            }
            $payloadName = '{0:d6}.payload' -f $index
            $payloadPath = Join-Path $transferRoot $payloadName
            $hash = Copy-WithHash `
                $items[$index].Source `
                $payloadPath `
                ([ref]$transferred) `
                $total `
                $displayName
        }
        $manifestFiles += [ordered]@{
            index = $index
            name = $items[$index].Name
            kind = $items[$index].Kind
            size = $items[$index].Size
            sha256 = $hash
        }
    }

    $manifest = [ordered]@{
        version = 2
        id = $MessageId
        totalBytes = $total
        files = $manifestFiles
    }
    [IO.File]::WriteAllText(
        $manifestTemporary,
        ($manifest | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $manifestTemporary -Destination $manifestPath -Force
    Remove-Item -LiteralPath $demandPath, $demandStartedPath -Force -ErrorAction SilentlyContinue
    Write-State 'Waiting' $total $total $displayName 'Waiting for Mac...'
} catch [OperationCanceledException] {
    Remove-Item -LiteralPath $transferRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requestPath, $manifestTemporary, $manifestPath, $offerTemporary, $offerMessage, $offerPath, $demandPath, $demandStartedPath -Force -ErrorAction SilentlyContinue
    if ($Mode -eq 'PrepareOutbound') {
        [IO.File]::WriteAllText(
            $failedTemporary,
            'failed',
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $failedTemporary -Destination $failedMessage -Force
        Write-State 'Canceled' 0 0 '' 'Transfer canceled.'
    }
} catch {
    Remove-Item -LiteralPath $transferRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requestPath, $manifestTemporary, $manifestPath, $offerTemporary, $offerMessage, $offerPath, $demandPath, $demandStartedPath -Force -ErrorAction SilentlyContinue
    if ($Mode -eq 'PrepareOutbound') {
        [IO.File]::WriteAllText(
            $failedTemporary,
            'failed',
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $failedTemporary -Destination $failedMessage -Force
        Write-State 'Error' 0 0 '' $_.Exception.Message
    } else {
        Write-State 'Error' 0 0 '' $_.Exception.Message
    }
}
Remove-Item -LiteralPath $workerPidFile -Force -ErrorAction SilentlyContinue
