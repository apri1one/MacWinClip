$root = $PSScriptRoot
$pidFile = Join-Path $root 'agent.pid'
$stopRequest = Join-Path $root 'stop.request'

if (-not (Test-Path -LiteralPath $pidFile)) {
    Write-Host 'Windows clipboard agent is not running.'
    exit 0
}

[IO.File]::WriteAllText($stopRequest, 'stop', [Text.UTF8Encoding]::new($false))
$deadline = (Get-Date).AddSeconds(8)
while ((Test-Path -LiteralPath $pidFile) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
}

if (Test-Path -LiteralPath $pidFile) {
    throw 'Agent did not stop in time. Do not delete its files while it is running.'
}

Write-Host 'Windows clipboard agent stopped.'

