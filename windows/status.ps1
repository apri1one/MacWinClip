$root = $PSScriptRoot
$pidFile = Join-Path $root 'agent.pid'
$inboxRoot = Join-Path $root 'inbox'
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
}
