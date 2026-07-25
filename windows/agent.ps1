$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
$requestRoot = Join-Path $root 'file-requests'
$outgoingRoot = Join-Path $root 'outgoing'
$incomingRoot = Join-Path $root 'incoming'
$progressRoot = Join-Path $root 'progress'
$cancelRoot = Join-Path $root 'cancel'
$demandRoot = Join-Path $root 'file-demands'
$dismissRoot = Join-Path $root 'file-dismissals'
$receiveRootFile = Join-Path $root 'receive-root.txt'
$stopRequest = Join-Path $root 'stop.request'
$pidFile = Join-Path $root 'agent.pid'
$maxTextBytes = 1048576
$maxImageBytes = 16777216
$maxFileBytes = [int64]10737418240
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\MacWindowsSSHClipboardAgent', [ref]$createdNew)

if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $root 'lazy-files.cs')
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class MacWinClipNative {
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
'@

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Windows clipboard agent must run in an STA PowerShell process.'
}

foreach ($directory in $inboxRoot, $requestRoot, $outgoingRoot, $incomingRoot, $progressRoot, $cancelRoot, $demandRoot, $dismissRoot) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($pidFile, [string]$PID, [Text.UTF8Encoding]::new($false))

function Get-ClipboardSequence {
    return [uint32][MacWinClipNative]::GetClipboardSequenceNumber()
}

function Get-ClipboardSnapshot {
    try {
        if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $paths = @()
            foreach ($path in [Windows.Forms.Clipboard]::GetFileDropList()) {
                $paths += [string]$path
            }
            return [pscustomobject]@{
                Type = 'FILES'
                Paths = $paths
            }
        }

        if ([Windows.Forms.Clipboard]::ContainsImage()) {
            $image = [Windows.Forms.Clipboard]::GetImage()
            if ($null -eq $image) {
                return $null
            }
            $memory = [IO.MemoryStream]::new()
            try {
                $image.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
                return [pscustomobject]@{
                    Type = 'PNG'
                    Bytes = $memory.ToArray()
                }
            } finally {
                $memory.Dispose()
                $image.Dispose()
            }
        }

        if ([Windows.Forms.Clipboard]::ContainsText([Windows.Forms.TextDataFormat]::UnicodeText)) {
            $text = [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
            return [pscustomobject]@{
                Type = 'TEXT'
                Bytes = [Text.Encoding]::UTF8.GetBytes($text)
            }
        }

        return [pscustomobject]@{
            Type = 'EMPTY'
            Bytes = [byte[]]@()
        }
    } catch [Runtime.InteropServices.ExternalException] {
        return $null
    }
}

function Set-ClipboardSnapshot([string]$Type, [byte[]]$Bytes) {
    if ($Type -eq 'TEXT') {
        $text = [Text.Encoding]::UTF8.GetString($Bytes)
        [Windows.Forms.Clipboard]::SetText($text, [Windows.Forms.TextDataFormat]::UnicodeText)
        return
    }

    if ($Type -eq 'PNG') {
        $memory = [IO.MemoryStream]::new($Bytes, $false)
        $sourceImage = $null
        $bitmap = $null
        try {
            $sourceImage = [Drawing.Image]::FromStream($memory)
            $bitmap = [Drawing.Bitmap]::new($sourceImage)
            [Windows.Forms.Clipboard]::SetImage($bitmap)
        } finally {
            if ($null -ne $bitmap) {
                $bitmap.Dispose()
            }
            if ($null -ne $sourceImage) {
                $sourceImage.Dispose()
            }
            $memory.Dispose()
        }
        return
    }

    if ($Type -eq 'FILES') {
        $manifest = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
        $paths = [Collections.Specialized.StringCollection]::new()
        foreach ($path in @($manifest.paths)) {
            $resolved = [IO.Path]::GetFullPath([string]$path)
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw 'A received file is missing.'
            }
            [void]$paths.Add($resolved)
        }
        if ($paths.Count -eq 0) {
            throw 'Received file list is empty.'
        }
        [Windows.Forms.Clipboard]::SetFileDropList($paths)
        return
    }

    throw "Unsupported clipboard payload type: $Type"
}

function Set-LazyFileOffer([string]$MessageId, [byte[]]$Bytes) {
    if (-not (Test-Path -LiteralPath $receiveRootFile -PathType Leaf)) {
        throw 'Receive directory configuration is missing.'
    }
    $manifest = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    if ([int]$manifest.version -ne 1 -or [string]$manifest.id -ne $MessageId) {
        throw 'Invalid file offer.'
    }
    $files = @($manifest.files)
    if ($files.Count -eq 0 -or $files.Count -gt 1000) {
        throw 'Invalid file offer.'
    }
    $names = [string[]]::new($files.Count)
    $sizes = [int64[]]::new($files.Count)
    $total = [int64]0
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $name = [string]$file.name
        $size = [int64]$file.size
        if (
            [int]$file.index -ne $index -or
            [string]::IsNullOrWhiteSpace($name) -or
            $name.Length -gt 259 -or
            $size -lt 0 -or
            $size -gt ($maxFileBytes - $total)
        ) {
            throw 'Invalid file offer.'
        }
        $names[$index] = $name
        $sizes[$index] = $size
        $total += $size
    }
    if ($total -le 0 -or [int64]$manifest.totalBytes -ne $total) {
        throw 'Invalid file offer.'
    }

    foreach ($suffix in 'request', 'done', 'failed', 'canceled') {
        Remove-Item -LiteralPath (Join-Path $demandRoot "$MessageId.$suffix") -Force -ErrorAction SilentlyContinue
    }
    $receiveRoot = [IO.Path]::GetFullPath(
        (Get-Content -LiteralPath $receiveRootFile -Raw -Encoding UTF8).Trim()
    )
    $destinationRoot = Join-Path $receiveRoot 'MacWinClip'
    $script:lazyFileClipboard = [MacWinClip.LazyFileClipboard]::Set(
        $MessageId,
        $names,
        $sizes,
        $demandRoot,
        $destinationRoot,
        (Join-Path $root 'progress.ps1'),
        $progressRoot,
        $cancelRoot
    )
    $script:lazyFileMessageId = $MessageId
}

function Dismiss-LazyFileOffer {
    if ([string]::IsNullOrEmpty($script:lazyFileMessageId)) {
        return
    }
    $temporary = Join-Path $dismissRoot "$($script:lazyFileMessageId).tmp"
    $request = Join-Path $dismissRoot "$($script:lazyFileMessageId).request"
    [IO.File]::WriteAllText($temporary, 'dismiss', [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $request -Force
    $script:lazyFileClipboard = $null
    $script:lazyFileMessageId = ''
}

function Write-Outbound([string]$Type, [byte[]]$Bytes) {
    $id = [Guid]::NewGuid().ToString('N')
    $typeName = $Type.ToLowerInvariant()
    $temporary = Join-Path $root "outbound.$id.$typeName.tmp"
    $message = Join-Path $root "outbound.$id.$typeName.msg"
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^outbound\.[a-f0-9]{32}\.(text|png)\.msg$' } |
        Remove-Item -Force
    Move-Item -LiteralPath $temporary -Destination $message
}

function Start-OutboundFiles([string[]]$Paths) {
    $active = @(
        Get-ChildItem -LiteralPath $root -Filter 'outbound.*.files.msg' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $requestRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
    ).Count
    if ($active -gt 0) {
        return
    }

    $id = [Guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $requestRoot "$id.json"
    $temporary = "$requestPath.tmp"
    $request = [ordered]@{
        id = $id
        sources = @($Paths)
    }
    [IO.File]::WriteAllText(
        $temporary,
        ($request | ConvertTo-Json -Depth 3 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $requestPath -Force

    $quotedWorker = '"' + (Join-Path $root 'file-worker.ps1') + '"'
    Start-Process `
        -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedWorker,
            '-Mode', 'PrepareOutbound', '-MessageId', $id `
        -WindowStyle Hidden
}

function Start-PendingProgressWindows {
    $progressScript = Join-Path $root 'progress.ps1'
    foreach ($state in Get-ChildItem -LiteralPath $progressRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $id = [IO.Path]::GetFileNameWithoutExtension($state.Name)
        if ($id -notmatch '^[a-f0-9]{32}$') {
            continue
        }
        $shown = Join-Path $progressRoot "$id.shown"
        if (Test-Path -LiteralPath $shown) {
            continue
        }
        [IO.File]::WriteAllText($shown, 'shown', [Text.UTF8Encoding]::new($false))
        $quotedProgress = '"' + $progressScript + '"'
        $quotedState = '"' + $state.FullName + '"'
        $quotedCancel = '"' + (Join-Path $cancelRoot "$id.request") + '"'
        Start-Process `
            -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File',
                $quotedProgress, '-StateFile', $quotedState, '-CancelFile', $quotedCancel `
            -WindowStyle Hidden
    }
}

function Remove-ExpiredProgressState {
    $cutoff = [DateTime]::UtcNow.AddMinutes(-1)
    foreach ($stateFile in Get-ChildItem -LiteralPath $progressRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        if ($stateFile.LastWriteTimeUtc -gt $cutoff) {
            continue
        }
        try {
            $state = Get-Content -LiteralPath $stateFile.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json
            if ($state.stage -in 'Done', 'Error', 'Canceled') {
                $id = [IO.Path]::GetFileNameWithoutExtension($stateFile.Name)
                Remove-Item -LiteralPath $stateFile.FullName -Force
                Remove-Item -LiteralPath (Join-Path $progressRoot "$id.shown") -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $cancelRoot "$id.request") -Force -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }
}

$lastSequence = Get-ClipboardSequence
$lazyFileClipboard = $null
$lazyFileMessageId = ''

try {
    while (-not (Test-Path -LiteralPath $stopRequest)) {
        $messages = Get-ChildItem -LiteralPath $inboxRoot -Filter '*.msg' -File -ErrorAction SilentlyContinue |
            Sort-Object Name

        foreach ($message in $messages) {
            $match = [regex]::Match($message.Name, '^([a-f0-9]{32})\.(text|png|files|files-offer|files-dismiss)\.msg$')
            if (-not $match.Success) {
                continue
            }

            $messageId = $match.Groups[1].Value
            $type = $match.Groups[2].Value.ToUpperInvariant()
            try {
                if ($type -eq 'FILES-DISMISS') {
                    if ($messageId -eq $lazyFileMessageId) {
                        [Windows.Forms.Clipboard]::Clear()
                        $lazyFileClipboard = $null
                        $lazyFileMessageId = ''
                        $lastSequence = Get-ClipboardSequence
                    }
                    Remove-Item -LiteralPath $message.FullName -Force
                    continue
                }
                $bytes = [IO.File]::ReadAllBytes($message.FullName)
                if ($type -eq 'FILES-OFFER') {
                    if ($bytes.Length -eq 0 -or $bytes.Length -gt $maxTextBytes) {
                        Remove-Item -LiteralPath $message.FullName -Force
                        continue
                    }
                    Set-LazyFileOffer $messageId $bytes
                    $lastSequence = Get-ClipboardSequence
                    Remove-Item -LiteralPath $message.FullName -Force
                    continue
                }
                $limit = if ($type -eq 'PNG') {
                    $maxImageBytes
                } elseif ($type -eq 'FILES') {
                    $maxTextBytes
                } else {
                    $maxTextBytes
                }
                if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) {
                    Remove-Item -LiteralPath $message.FullName -Force
                    continue
                }
                $lazyFileClipboard = $null
                $lazyFileMessageId = ''
                Set-ClipboardSnapshot $type $bytes
                $lastSequence = Get-ClipboardSequence
                Remove-Item -LiteralPath $message.FullName -Force
                if ($type -eq 'FILES') {
                    $statePath = Join-Path $progressRoot "$messageId.json"
                    if (Test-Path -LiteralPath $statePath) {
                        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
                            ConvertFrom-Json
                        $state.stage = 'Done'
                        $state.transferred = [int64]$state.total
                        $state.message = 'Transfer complete.'
                        $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
                        $temporary = "$statePath.tmp"
                        [IO.File]::WriteAllText(
                            $temporary,
                            ($state | ConvertTo-Json -Compress),
                            [Text.UTF8Encoding]::new($false)
                        )
                        Move-Item -LiteralPath $temporary -Destination $statePath -Force
                    }
                }
            } catch [Runtime.InteropServices.ExternalException] {
                break
            } catch {
                Remove-Item -LiteralPath $message.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        $currentSequence = Get-ClipboardSequence
        if ($currentSequence -ne $lastSequence) {
            Dismiss-LazyFileOffer
            $snapshot = Get-ClipboardSnapshot
            if ($null -ne $snapshot) {
                if ($snapshot.Type -eq 'FILES') {
                    Start-OutboundFiles $snapshot.Paths
                } elseif ($snapshot.Type -eq 'TEXT') {
                    if ($snapshot.Bytes.Length -gt 0 -and $snapshot.Bytes.Length -le $maxTextBytes) {
                        Write-Outbound $snapshot.Type $snapshot.Bytes
                    }
                } elseif ($snapshot.Type -eq 'PNG') {
                    if ($snapshot.Bytes.Length -gt 0 -and $snapshot.Bytes.Length -le $maxImageBytes) {
                        Write-Outbound $snapshot.Type $snapshot.Bytes
                    }
                }
                $lastSequence = $currentSequence
            }
        }

        Start-PendingProgressWindows
        Remove-ExpiredProgressState
        [Windows.Forms.Application]::DoEvents()
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
