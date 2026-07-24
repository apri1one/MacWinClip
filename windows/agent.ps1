$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
$stopRequest = Join-Path $root 'stop.request'
$pidFile = Join-Path $root 'agent.pid'
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\MacWindowsSSHClipboardAgent', [ref]$createdNew)

if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null
Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($pidFile, [string]$PID, [Text.UTF8Encoding]::new($false))

function Get-TextClipboard {
    try {
        $value = Get-Clipboard -Raw -Format Text -ErrorAction Stop
        if ($value -is [string]) {
            return $value
        }
    } catch {
        return $null
    }
}

function Write-Outbound([string]$value) {
    $id = [Guid]::NewGuid().ToString('N')
    $temporary = Join-Path $root "outbound.$id.tmp"
    $message = Join-Path $root "outbound.$id.msg"
    [IO.File]::WriteAllText($temporary, $value, [Text.UTF8Encoding]::new($false))
    Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
    Move-Item -LiteralPath $temporary -Destination $message
}

$lastValue = Get-TextClipboard

try {
    while (-not (Test-Path -LiteralPath $stopRequest)) {
        $messages = Get-ChildItem -LiteralPath $inboxRoot -Filter '*.msg' -File -ErrorAction SilentlyContinue |
            Sort-Object Name

        foreach ($message in $messages) {
            try {
                $value = Get-Content -LiteralPath $message.FullName -Raw -Encoding utf8
                Set-Clipboard -Value $value
                $lastValue = $value
                Remove-Item -LiteralPath $message.FullName -Force
            } catch {
                break
            }
        }

        $currentValue = Get-TextClipboard
        if ($null -ne $currentValue -and $currentValue -ne $lastValue) {
            if ($currentValue.Length -gt 0) {
                Write-Outbound $currentValue
            }
            $lastValue = $currentValue
        }

        Start-Sleep -Milliseconds 250
    }
} finally {
    Remove-Item -LiteralPath $pidFile, $stopRequest -Force -ErrorAction SilentlyContinue
    try {
        $mutex.ReleaseMutex()
    } catch {
    }
    $mutex.Dispose()
}
