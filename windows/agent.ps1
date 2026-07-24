$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inboxRoot = Join-Path $root 'inbox'
$stopRequest = Join-Path $root 'stop.request'
$pidFile = Join-Path $root 'agent.pid'
$maxTextBytes = 1048576
$maxImageBytes = 16777216
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\MacWindowsSSHClipboardAgent', [ref]$createdNew)

if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
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

New-Item -ItemType Directory -Force -Path $inboxRoot | Out-Null
Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($pidFile, [string]$PID, [Text.UTF8Encoding]::new($false))

function Get-ClipboardSequence {
    return [uint32][MacWinClipNative]::GetClipboardSequenceNumber()
}

function Get-ClipboardSnapshot {
    try {
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

    throw "Unsupported clipboard payload type: $Type"
}

function Write-Outbound([string]$Type, [byte[]]$Bytes) {
    $id = [Guid]::NewGuid().ToString('N')
    $typeName = $Type.ToLowerInvariant()
    $temporary = Join-Path $root "outbound.$id.$typeName.tmp"
    $message = Join-Path $root "outbound.$id.$typeName.msg"
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
    Move-Item -LiteralPath $temporary -Destination $message
}

$lastSequence = Get-ClipboardSequence

try {
    while (-not (Test-Path -LiteralPath $stopRequest)) {
        $messages = Get-ChildItem -LiteralPath $inboxRoot -Filter '*.msg' -File -ErrorAction SilentlyContinue |
            Sort-Object Name

        foreach ($message in $messages) {
            $match = [regex]::Match($message.Name, '^[a-f0-9]{32}\.(text|png)\.msg$')
            if (-not $match.Success) {
                continue
            }

            $type = $match.Groups[1].Value.ToUpperInvariant()
            try {
                $bytes = [IO.File]::ReadAllBytes($message.FullName)
                $limit = if ($type -eq 'PNG') { $maxImageBytes } else { $maxTextBytes }
                if ($bytes.Length -eq 0 -or $bytes.Length -gt $limit) {
                    Remove-Item -LiteralPath $message.FullName -Force
                    continue
                }
                Set-ClipboardSnapshot $type $bytes
                $lastSequence = Get-ClipboardSequence
                Remove-Item -LiteralPath $message.FullName -Force
            } catch [Runtime.InteropServices.ExternalException] {
                break
            } catch {
                Remove-Item -LiteralPath $message.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        $currentSequence = Get-ClipboardSequence
        if ($currentSequence -ne $lastSequence) {
            $snapshot = Get-ClipboardSnapshot
            if ($null -ne $snapshot) {
                if ($snapshot.Type -eq 'TEXT') {
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
