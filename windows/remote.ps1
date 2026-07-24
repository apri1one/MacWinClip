param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('health', 'stream')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
$maxTextBytes = 1048576
$maxImageBytes = 16777216
$maxProtocolLineLength = 24000000
New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null

if ($Action -eq 'health') {
    [Console]::Out.Write('OK')
    exit 0
}

function Send-ProtocolLine([string]$Line) {
    [Console]::Out.WriteLine($Line)
    [Console]::Out.Flush()
}

function Get-TypeLimit([string]$Type) {
    if ($Type -eq 'PNG') {
        return $maxImageBytes
    }
    return $maxTextBytes
}

function Read-AllBytesShared([string]$Path) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}

function Receive-MacMessage([string]$MessageId, [string]$Type, [string]$Encoded) {
    if ($MessageId -notmatch '^[a-f0-9]{32}$') {
        return
    }
    if ($Type -notin 'TEXT', 'PNG') {
        return
    }

    try {
        $bytes = [Convert]::FromBase64String($Encoded)
    } catch {
        return
    }

    $limit = Get-TypeLimit $Type
    if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) {
        return
    }

    $typeName = $Type.ToLowerInvariant()
    $temporary = Join-Path $inboxRoot "$MessageId.$typeName.tmp"
    $message = Join-Path $inboxRoot "$MessageId.$typeName.msg"
    [IO.File]::WriteAllBytes($temporary, $bytes)
    Move-Item -LiteralPath $temporary -Destination $message -Force
    Send-ProtocolLine "ACK $MessageId"
}

function Acknowledge-WindowsMessage([string]$MessageId) {
    if ($MessageId -notmatch '^[a-f0-9]{32}$') {
        return
    }

    Get-ChildItem -LiteralPath $root -Filter "outbound.$MessageId.*.msg" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root "outbound.$MessageId.msg") -Force -ErrorAction SilentlyContinue
}

$inputStream = [Console]::OpenStandardInput()
$readBuffer = New-Object byte[] 4096
$readTask = $inputStream.ReadAsync($readBuffer, 0, $readBuffer.Length)
$inputText = [Text.StringBuilder]::new()
$pendingId = $null
$lastSentAt = [DateTime]::MinValue

while ($true) {
    if ($readTask.IsCompleted) {
        $bytesRead = $readTask.Result
        if ($bytesRead -eq 0) {
            break
        }

        [void]$inputText.Append([Text.Encoding]::ASCII.GetString($readBuffer, 0, $bytesRead))
        $buffered = $inputText.ToString()
        $lineEnd = $buffered.IndexOf("`n")
        while ($lineEnd -ge 0) {
            $line = $buffered.Substring(0, $lineEnd).TrimEnd("`r")
            $buffered = $buffered.Substring($lineEnd + 1)
            if ($line.Length -gt $maxProtocolLineLength) {
                throw 'Protocol input line is too large.'
            }

            if ($line -match '^SET ([a-f0-9]{32}) (TEXT|PNG) ([A-Za-z0-9+/]+={0,2})$') {
                Receive-MacMessage $Matches[1] $Matches[2] $Matches[3]
            } elseif ($line -match '^ACK ([a-f0-9]{32})$') {
                Acknowledge-WindowsMessage $Matches[1]
                if ($pendingId -eq $Matches[1]) {
                    $pendingId = $null
                }
            }

            $lineEnd = $buffered.IndexOf("`n")
        }

        [void]$inputText.Clear()
        [void]$inputText.Append($buffered)
        if ($inputText.Length -gt $maxProtocolLineLength) {
            throw 'Protocol input line is too large.'
        }
        $readTask = $inputStream.ReadAsync($readBuffer, 0, $readBuffer.Length)
    }

    $outbound = Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -ne $outbound) {
        $match = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.(text|png)\.msg$')
        $legacyMatch = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.msg$')
        if ($match.Success -or $legacyMatch.Success) {
            if ($match.Success) {
                $messageId = $match.Groups[1].Value
                $type = $match.Groups[2].Value.ToUpperInvariant()
            } else {
                $messageId = $legacyMatch.Groups[1].Value
                $type = 'TEXT'
            }

            $now = [DateTime]::UtcNow
            if ($pendingId -ne $messageId -or ($now - $lastSentAt).TotalSeconds -ge 1) {
                try {
                    $bytes = Read-AllBytesShared $outbound.FullName
                    $limit = Get-TypeLimit $type
                    if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) {
                        Remove-Item -LiteralPath $outbound.FullName -Force -ErrorAction SilentlyContinue
                    } else {
                        $encoded = [Convert]::ToBase64String($bytes)
                        Send-ProtocolLine "SET $messageId $type $encoded"
                        $pendingId = $messageId
                        $lastSentAt = $now
                    }
                } catch [IO.IOException] {
                }
            }
        }
    } else {
        $pendingId = $null
    }

    Start-Sleep -Milliseconds 50
}
