$root = $PSScriptRoot
$pidFile = Join-Path $root 'agent.pid'
$inboxRoot = Join-Path $root 'inbox'
$progressRoot = Join-Path $root 'progress'
$running = $false
$agentPid = $null

if (Test-Path -LiteralPath $pidFile) {
    $agentPid = [int](Get-Content -LiteralPath $pidFile -Raw)
    $running = $null -ne (Get-Process -Id $agentPid -ErrorAction SilentlyContinue)
}

[pscustomobject]@{
    Running = $running
    ProcessId = $agentPid
    SessionId = if ($running) { (Get-Process -Id $agentPid).SessionId } else { $null }
    PendingMacToWindows = @(Get-ChildItem -LiteralPath $inboxRoot -Filter '*.msg' -File -ErrorAction SilentlyContinue).Count
    PendingWindowsToMac = @(Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue).Count
    PendingWindowsFileOffers = @(
        Get-ChildItem -LiteralPath (Join-Path $root 'outbound-file-offers') -Filter '*.json' -File -ErrorAction SilentlyContinue
    ).Count
    PendingWindowsFileFetches = @(
        Get-ChildItem -LiteralPath (Join-Path $root 'outbound-file-demands') -Filter '*.request' -File -ErrorAction SilentlyContinue
    ).Count
    ActiveFileTransfers = @(
        Get-ChildItem -LiteralPath $progressRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    (
                        Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 |
                            ConvertFrom-Json
                    ).stage -notin 'Done', 'Error', 'Canceled'
                } catch {
                    $false
                }
            }
    ).Count
}
