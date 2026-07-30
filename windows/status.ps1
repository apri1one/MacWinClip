$root = $PSScriptRoot
$pidFile = Join-Path $root 'agent.pid'
$supervisorPidFile = Join-Path $root 'supervisor.pid'
$healthStateFile = Join-Path $root 'health-state.json'
$inboxRoot = Join-Path $root 'inbox'
$progressRoot = Join-Path $root 'progress'
$running = $false
$agentPid = $null
$supervisorRunning = $false
$supervisorPid = $null
$healthState = $null

if (Test-Path -LiteralPath $pidFile) {
    $agentPid = [int](Get-Content -LiteralPath $pidFile -Raw)
    $running = $null -ne (Get-Process -Id $agentPid -ErrorAction SilentlyContinue)
}
if (Test-Path -LiteralPath $supervisorPidFile) {
    try {
        $supervisorPid = [int](Get-Content -LiteralPath $supervisorPidFile -Raw)
        $supervisorRunning = $null -ne (
            Get-Process -Id $supervisorPid -ErrorAction SilentlyContinue
        )
    } catch {
        $supervisorRunning = $false
    }
}
if (Test-Path -LiteralPath $healthStateFile -PathType Leaf) {
    try {
        $healthState = Get-Content -LiteralPath $healthStateFile -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        $healthState = $null
    }
}

[pscustomobject]@{
    Running = $running
    ProcessId = $agentPid
    SessionId = if ($running) { (Get-Process -Id $agentPid).SessionId } else { $null }
    SupervisorRunning = $supervisorRunning
    SupervisorProcessId = $supervisorPid
    HealthState = if ($null -ne $healthState) { [string]$healthState.state } else { $null }
    HealthFailures = if ($null -ne $healthState) { [int]$healthState.failures } else { $null }
    PendingMacToWindows = @(Get-ChildItem -LiteralPath $inboxRoot -Filter '*.msg' -File -ErrorAction SilentlyContinue).Count
    PendingWindowsToMac = @(Get-ChildItem -LiteralPath $root -Filter 'outbound.*.msg' -File -ErrorAction SilentlyContinue).Count
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
