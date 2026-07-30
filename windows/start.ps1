$root = $PSScriptRoot
$supervisor = Join-Path $root 'supervisor.ps1'
$supervisorPidFile = Join-Path $root 'supervisor.pid'

if (-not (Test-Path -LiteralPath $supervisor)) {
    throw "Supervisor script not found: $supervisor"
}

$running = $false
if (Test-Path -LiteralPath $supervisorPidFile -PathType Leaf) {
    try {
        $supervisorPid = [int](Get-Content -LiteralPath $supervisorPidFile -Raw)
        $supervisorProcess = Get-Process -Id $supervisorPid -ErrorAction Stop
        $running = $supervisorProcess.SessionId -ne 0
    } catch {
        $running = $false
    }
}
if ($running) {
    Write-Host 'Windows clipboard supervisor is already running.'
    exit 0
}

$quotedSupervisor = '"' + $supervisor + '"'
Start-Process `
    -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedSupervisor `
    -WindowStyle Hidden

$agentPidFile = Join-Path $root 'agent.pid'
for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if (
        (Test-Path -LiteralPath $supervisorPidFile -PathType Leaf) -and
        (Test-Path -LiteralPath $agentPidFile -PathType Leaf)
    ) {
        break
    }
    Start-Sleep -Milliseconds 100
}
if (
    -not (Test-Path -LiteralPath $supervisorPidFile -PathType Leaf) -or
    -not (Test-Path -LiteralPath $agentPidFile -PathType Leaf)
) {
    throw 'Windows clipboard supervisor did not start the agent.'
}

Write-Host 'Windows clipboard supervisor and agent started.'
