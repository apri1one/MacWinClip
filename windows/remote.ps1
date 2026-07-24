param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('health', 'stream')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null

if ($Action -eq 'health') {
    [Console]::Out.Write('OK')
    exit 0
}

function Send-ProtocolLine([string]$Line) {
    [Console]::Out.WriteLine($Line)
    [Console]::Out.Flush()
}

function Receive-MacMessage([string]$MessageId, [string]$Encoded) {
    if ($MessageId -notmatch '^[a-f0-9]{32}$') {
        return
    }

    try {
        $bytes = [Convert]::FromBase64String($Encoded)
    } catch {
        return
    }

    if ($bytes.Length -eq 0 -or $bytes.Length -gt 1048576) {
        return
    }

    $temporary = Join-Path $inboxRoot "$MessageId.tmp"
    $message = Join-Path $inboxRoot "$MessageId.msg"
    [IO.File]::WriteAllBytes($temporary, $bytes)
    Move-Item -LiteralPath $temporary -Destination $message -Force
    Send-ProtocolLine "ACK $MessageId"
}

function Acknowledge-WindowsMessage([string]$MessageId) {
    if ($MessageId -notmatch '^[a-f0-9]{32}$') {
        return
    }

    $message = Join-Path $root "outbound.$MessageId.msg"
    Remove-Item -LiteralPath $message -Force -ErrorAction SilentlyContinue
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

            if ($line -match '^SET ([a-f0-9]{32}) ([A-Za-z0-9+/]+={0,2})$') {
                Receive-MacMessage $Matches[1] $Matches[2]
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
        if ($inputText.Length -gt 2097152) {
            throw 'Protocol input line is too large.'
        }
        $readTask = $inputStream.ReadAsync($readBuffer, 0, $readBuffer.Length)
    }

    $outbound = Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if ($null -ne $outbound) {
        $match = [regex]::Match($outbound.Name, '^outbound\.([a-f0-9]{32})\.msg$')
        if ($match.Success) {
            $messageId = $match.Groups[1].Value
            $now = [DateTime]::UtcNow
            if ($pendingId -ne $messageId -or ($now - $lastSentAt).TotalSeconds -ge 1) {
                try {
                    $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outbound.FullName))
                    if ($encoded.Length -gt 0) {
                        Send-ProtocolLine "SET $messageId $encoded"
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
