param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('health', 'stream', 'receive', 'ack')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$MessageId,

    [Parameter(Position = 2)]
    [ValidateSet('TEXT', 'PNG')]
    [string]$Type
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
$maxTextBytes = 1048576
$maxImageBytes = 16777216
New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null

function Assert-MessageId([string]$Value) {
    if ($Value -notmatch '^[a-f0-9]{32}$') {
        throw 'Invalid message id.'
    }
}

function Get-TypeLimit([string]$PayloadType) {
    if ($PayloadType -eq 'PNG') {
        return $maxImageBytes
    }
    return $maxTextBytes
}

function Send-ProtocolLine([string]$Line) {
    [Console]::Out.WriteLine($Line)
    [Console]::Out.Flush()
}

function Remove-Outbound([string]$Id) {
    Get-ChildItem -LiteralPath $root -Filter "outbound.$Id.*.msg" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root "outbound.$Id.msg") -Force -ErrorAction SilentlyContinue
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

    Write-Output "OK V3 $($agentProcess.SessionId)"
    exit 0
}

if ($Action -eq 'ack') {
    Assert-MessageId $MessageId
    Remove-Outbound $MessageId
    Write-Output "ACK $MessageId"
    exit 0
}

if ($Action -eq 'receive') {
    Assert-MessageId $MessageId
    if ($Type -notin 'TEXT', 'PNG') {
        throw 'Invalid payload type.'
    }

    $typeName = $Type.ToLowerInvariant()
    $upload = Join-Path $root "upload.$MessageId.$typeName.tmp"
    if (-not (Test-Path -LiteralPath $upload)) {
        throw 'Uploaded payload is missing.'
    }

    $length = (Get-Item -LiteralPath $upload).Length
    $limit = Get-TypeLimit $Type
    if ($length -eq 0 -or $length -gt $limit) {
        Remove-Item -LiteralPath $upload -Force -ErrorAction SilentlyContinue
        throw 'Uploaded payload size is invalid.'
    }

    $message = Join-Path $inboxRoot "$MessageId.$typeName.msg"
    Move-Item -LiteralPath $upload -Destination $message -Force
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

    $outbound = Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -ne $outbound) {
        $match = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.(text|png)\.msg$')
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
