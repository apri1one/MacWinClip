$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$agentScript = Join-Path $root 'agent.ps1'
$agentPidFile = Join-Path $root 'agent.pid'
$supervisorPidFile = Join-Path $root 'supervisor.pid'
$stopRequest = Join-Path $root 'supervisor.stop.request'
$recoveryRequest = Join-Path $root 'supervisor.recover.request'
$stateFile = Join-Path $root 'health-state.json'
$logFile = Join-Path $root 'health.jsonl'
$baseDelaySeconds = 2
$maximumDelaySeconds = 300
$failureThreshold = 8
$stableSeconds = 300
$createdNew = $false
$mutex = [Threading.Mutex]::new(
    $true,
    'Local\MacWindowsSSHClipboardSupervisor',
    [ref]$createdNew
)

function Write-HealthEvent(
    [string]$Level,
    [string]$Event,
    [string]$State,
    [int]$Failures,
    [string]$Detail
) {
    if (
        (Test-Path -LiteralPath $logFile -PathType Leaf) -and
        (Get-Item -LiteralPath $logFile).Length -ge 1048576
    ) {
        Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force
    }
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        event = $Event
        state = $State
        failures = $Failures
        detail = $Detail
        sessionId = (Get-Process -Id $PID).SessionId
    }
    $json = $entry | ConvertTo-Json -Compress
    [IO.File]::AppendAllText(
        $logFile,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Write-HealthState(
    [string]$State,
    [int]$Failures,
    [int]$NextRetrySeconds,
    [string]$Detail
) {
    $entry = [ordered]@{
        updatedUtc = [DateTime]::UtcNow.ToString('o')
        state = $State
        failures = $Failures
        nextRetrySeconds = $NextRetrySeconds
        detail = $Detail
        sessionId = (Get-Process -Id $PID).SessionId
    }
    $temporary = "$stateFile.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($entry | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $stateFile -Force
}

function Get-AgentProcess {
    if (-not (Test-Path -LiteralPath $agentPidFile -PathType Leaf)) {
        return $null
    }
    try {
        $agentPid = [int](Get-Content -LiteralPath $agentPidFile -Raw)
        $process = Get-Process -Id $agentPid -ErrorAction Stop
        $currentSession = (Get-Process -Id $PID).SessionId
        if ($process.SessionId -eq 0 -or $process.SessionId -ne $currentSession) {
            return $null
        }
        return $process
    } catch {
        return $null
    }
}

function Start-Agent {
    Remove-Item -LiteralPath $agentPidFile -Force -ErrorAction SilentlyContinue
    $quotedAgent = '"' + $agentScript + '"'
    Start-Process `
        -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', $quotedAgent `
        -WindowStyle Hidden | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $agent = Get-AgentProcess
        if ($null -ne $agent) {
            return $agent
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'agent_start_timeout'
}

function Wait-WithRecoveryRequest([int]$Seconds) {
    for ($elapsed = 0; $elapsed -lt $Seconds; $elapsed++) {
        if (Test-Path -LiteralPath $stopRequest -PathType Leaf) {
            return
        }
        if (Test-Path -LiteralPath $recoveryRequest -PathType Leaf) {
            Remove-Item -LiteralPath $recoveryRequest -Force -ErrorAction SilentlyContinue
            return
        }
        Start-Sleep -Seconds 1
    }
}

if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $agentScript -PathType Leaf)) {
        throw 'agent_script_missing'
    }
    $sessionId = (Get-Process -Id $PID).SessionId
    if ($sessionId -eq 0) {
        Write-HealthEvent 'error' 'supervisor_rejected' 'failed' 1 'session_zero'
        Write-HealthState 'failed' 1 0 'session_zero'
        exit 2
    }

    Remove-Item -LiteralPath $stopRequest, $recoveryRequest -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText(
        $supervisorPidFile,
        [string]$PID,
        [Text.UTF8Encoding]::new($false)
    )
    Write-HealthEvent 'info' 'supervisor_started' 'recovering' 0 'startup'
    Write-HealthState 'recovering' 0 0 'startup'

    $failures = 0
    while (-not (Test-Path -LiteralPath $stopRequest -PathType Leaf)) {
        $agent = Get-AgentProcess
        if ($null -eq $agent) {
            try {
                Write-HealthEvent 'info' 'agent_starting' 'recovering' $failures 'agent_not_running'
                $agent = Start-Agent
                Write-HealthEvent 'info' 'agent_started' 'healthy' $failures 'agent_started'
                Write-HealthState 'healthy' $failures 0 'agent_running'
            } catch {
                $failures++
                $delay = [Math]::Min(
                    $maximumDelaySeconds,
                    [int]($baseDelaySeconds * [Math]::Pow(2, [Math]::Min($failures - 1, 8)))
                )
                $state = if ($failures -ge $failureThreshold) { 'failed' } else { 'recovering' }
                Write-HealthEvent 'error' 'agent_start_failed' $state $failures 'agent_start_failed'
                Write-HealthState $state $failures $delay 'agent_start_failed'
                Wait-WithRecoveryRequest $delay
                continue
            }
        }

        $healthySince = [DateTime]::UtcNow
        while (
            -not (Test-Path -LiteralPath $stopRequest -PathType Leaf) -and
            -not $agent.HasExited
        ) {
            if (
                $failures -gt 0 -and
                ([DateTime]::UtcNow - $healthySince).TotalSeconds -ge $stableSeconds
            ) {
                $failures = 0
                Write-HealthEvent 'info' 'failure_counter_reset' 'healthy' 0 'stable_agent'
                Write-HealthState 'healthy' 0 0 'agent_running'
            }
            Start-Sleep -Seconds 2
            $agent.Refresh()
        }
        if (Test-Path -LiteralPath $stopRequest -PathType Leaf) {
            break
        }

        $failures++
        $delay = [Math]::Min(
            $maximumDelaySeconds,
            [int]($baseDelaySeconds * [Math]::Pow(2, [Math]::Min($failures - 1, 8)))
        )
        $state = if ($failures -ge $failureThreshold) { 'failed' } else { 'recovering' }
        Write-HealthEvent 'error' 'agent_exited' $state $failures 'agent_exited'
        Write-HealthState $state $failures $delay 'agent_exited'
        Wait-WithRecoveryRequest $delay
    }
} catch {
    try {
        Write-HealthEvent 'error' 'supervisor_failed' 'failed' 1 'supervisor_exception'
        Write-HealthState 'failed' 1 0 'supervisor_exception'
    } catch {
    }
    exit 1
} finally {
    Remove-Item -LiteralPath $supervisorPidFile, $stopRequest -Force -ErrorAction SilentlyContinue
    try {
        $mutex.ReleaseMutex()
    } catch {
    }
    $mutex.Dispose()
}
