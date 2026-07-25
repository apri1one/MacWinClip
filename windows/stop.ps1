$root = $PSScriptRoot
$pidFile = Join-Path $root 'agent.pid'
$stopRequest = Join-Path $root 'stop.request'
$cancelRoot = Join-Path $root 'cancel'

$agentRunning = Test-Path -LiteralPath $pidFile
$workerPidFiles = @(
    Get-ChildItem -LiteralPath $root -Filter 'file-worker.*.pid' -File -ErrorAction SilentlyContinue
)
if (-not $agentRunning -and $workerPidFiles.Count -eq 0) {
    Write-Host 'Windows clipboard agent is not running.'
    exit 0
}

if ($agentRunning) {
    [IO.File]::WriteAllText($stopRequest, 'stop', [Text.UTF8Encoding]::new($false))
}
New-Item -ItemType Directory -Force -Path $cancelRoot | Out-Null
foreach ($workerPidFile in $workerPidFiles) {
    $match = [regex]::Match($workerPidFile.Name, '^file-worker\.([a-f0-9]{32})\.pid$')
    if ($match.Success) {
        [IO.File]::WriteAllText(
            (Join-Path $cancelRoot "$($match.Groups[1].Value).request"),
            'cancel',
            [Text.UTF8Encoding]::new($false)
        )
    }
}
$deadline = (Get-Date).AddSeconds(8)
while (
    (
        (Test-Path -LiteralPath $pidFile) -or
        @(Get-ChildItem -LiteralPath $root -Filter 'file-worker.*.pid' -File -ErrorAction SilentlyContinue).Count -gt 0
    ) -and
    (Get-Date) -lt $deadline
) {
    Start-Sleep -Milliseconds 200
}

if (Test-Path -LiteralPath $pidFile) {
    throw 'Agent did not stop in time. Do not delete its files while it is running.'
}
if (@(Get-ChildItem -LiteralPath $root -Filter 'file-worker.*.pid' -File -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'A file transfer worker did not stop in time.'
}

Write-Host 'Windows clipboard agent stopped.'
