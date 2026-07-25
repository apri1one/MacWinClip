param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('PrepareOutbound')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$MessageId
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$requestRoot = Join-Path $root 'file-requests'
$outgoingRoot = Join-Path $root 'outgoing'
$progressRoot = Join-Path $root 'progress'
$cancelRoot = Join-Path $root 'cancel'
$requestPath = Join-Path $requestRoot "$MessageId.json"
$transferRoot = Join-Path $outgoingRoot $MessageId
$manifestTemporary = Join-Path $root "outbound.$MessageId.files.tmp"
$manifestPath = Join-Path $root "outbound.$MessageId.files.msg"
$statePath = Join-Path $progressRoot "$MessageId.json"
$cancelPath = Join-Path $cancelRoot "$MessageId.request"
$workerPidFile = Join-Path $root "file-worker.$MessageId.pid"
$maxFileBytes = [int64]10737418240

foreach ($directory in $requestRoot, $outgoingRoot, $progressRoot, $cancelRoot) {
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
    if ($safe -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
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

    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
    $sources = @($request.sources)
    if ($sources.Count -eq 0 -or $sources.Count -gt 1000) {
        throw 'File selection must contain between 1 and 1000 files.'
    }

    $items = @()
    $total = [int64]0
    $usedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($source in $sources) {
        $item = Get-Item -LiteralPath ([string]$source) -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Folders and symbolic links are not supported.'
        }
        if ([int64]$item.Length -gt ($maxFileBytes - $total)) {
            throw 'The selected files exceed the 10 GiB transfer limit.'
        }
        $total += [int64]$item.Length
        $items += [pscustomobject]@{
            Source = $item.FullName
            Name = Get-SafeName $item.Name $usedNames
            Size = [int64]$item.Length
        }
    }

    if ($total -le 0) {
        throw 'Empty files are not supported in the first file-transfer release.'
    }

    New-Item -ItemType Directory -Force -Path $transferRoot | Out-Null
    $displayName = if ($items.Count -eq 1) { $items[0].Name } else { "$($items.Count) files" }
    Write-State 'Preparing' 0 $total $displayName 'Preparing files...'

    $transferred = [int64]0
    $manifestFiles = @()
    for ($index = 0; $index -lt $items.Count; $index++) {
        $payloadName = '{0:d6}.payload' -f $index
        $payloadPath = Join-Path $transferRoot $payloadName
        $hash = Copy-WithHash `
            $items[$index].Source `
            $payloadPath `
            ([ref]$transferred) `
            $total `
            $displayName
        $manifestFiles += [ordered]@{
            index = $index
            name = $items[$index].Name
            size = $items[$index].Size
            sha256 = $hash
        }
    }

    $manifest = [ordered]@{
        version = 1
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
    Remove-Item -LiteralPath $requestPath -Force
    Write-State 'Waiting' $total $total $displayName 'Waiting for Mac...'
} catch [OperationCanceledException] {
    Remove-Item -LiteralPath $transferRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requestPath, $manifestTemporary, $manifestPath -Force -ErrorAction SilentlyContinue
    Write-State 'Canceled' 0 0 '' 'Transfer canceled.'
} catch {
    Remove-Item -LiteralPath $transferRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requestPath, $manifestTemporary, $manifestPath -Force -ErrorAction SilentlyContinue
    Write-State 'Error' 0 0 '' $_.Exception.Message
}
Remove-Item -LiteralPath $workerPidFile -Force -ErrorAction SilentlyContinue
