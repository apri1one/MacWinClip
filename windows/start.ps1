$root = $PSScriptRoot
$agent = Join-Path $root 'agent.ps1'

if (-not (Test-Path -LiteralPath $agent)) {
    throw "Agent script not found: $agent"
}

$quotedAgent = '"' + $agent + '"'
Start-Process `
    -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedAgent `
    -WindowStyle Hidden

Start-Sleep -Milliseconds 700
$pidFile = Join-Path $root 'agent.pid'
if (-not (Test-Path -LiteralPath $pidFile)) {
    throw 'Windows clipboard agent did not start.'
}

Write-Host 'Windows clipboard agent started.'
