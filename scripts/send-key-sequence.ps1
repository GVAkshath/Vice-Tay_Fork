# Replay a timed sequence of keyboard inputs through Vice-Tay's GameInput test hook.
#
# Start the game with -More @{ VICTORY_KEYS_FILE = '<same path>' }, wait until it is
# at the menu/scene you want to test, then run this script in another PowerShell window.
# Plan CSV columns: AtSeconds,Key,HoldSeconds

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$KeyFile,

    [Parameter(Mandatory)]
    [string]$Plan,

    [ValidateRange(1, 120)]
    [int]$ConsumeTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
$keyPath = [System.IO.Path]::GetFullPath($KeyFile)
$planPath = (Resolve-Path -LiteralPath $Plan).Path
$takenPath = "$keyPath.taken"
$tempPath = "$keyPath.$PID.tmp"
$directory = Split-Path -Parent $keyPath
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
if (Test-Path -LiteralPath $keyPath -or Test-Path -LiteralPath $takenPath) {
    throw "The key channel is already in use: $keyPath"
}

$rows = @(Import-Csv -LiteralPath $planPath)
if ($rows.Count -eq 0) { throw "The input plan is empty: $planPath" }
$allowedNamedKeys = @('Enter', 'Esc', 'Tab', 'Back', 'Up', 'Down', 'Left', 'Right')
$events = foreach ($row in $rows) {
    $at = 0.0
    $hold = 0.0
    $numberStyle = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse([string]$row.AtSeconds, $numberStyle, $culture, [ref]$at)) {
        throw "Invalid AtSeconds value: '$($row.AtSeconds)'"
    }
    if (-not [double]::TryParse([string]$row.HoldSeconds, $numberStyle, $culture, [ref]$hold)) {
        throw "Invalid HoldSeconds value: '$($row.HoldSeconds)'"
    }
    if ([double]::IsNaN($at) -or [double]::IsInfinity($at) -or $at -lt 0 -or $at -gt 3600) {
        throw "AtSeconds must be between 0 and 3600: '$($row.AtSeconds)'"
    }
    if ([double]::IsNaN($hold) -or [double]::IsInfinity($hold) -or $hold -lt 0.05 -or $hold -gt 30) {
        throw "HoldSeconds must be between 0.05 and 30: '$($row.HoldSeconds)'"
    }
    $key = ([string]$row.Key).Trim()
    if (-not ($key -in $allowedNamedKeys) -and $key -notmatch '^[A-Za-z0-9]$') {
        throw "Unsupported key '$key'. Use a letter, digit, Enter, Esc, Tab, Back, Up, Down, Left or Right."
    }
    [pscustomobject]@{ AtSeconds = $at; Key = $key; HoldSeconds = $hold }
}
$events = @($events | Sort-Object AtSeconds)

Write-Host "Replaying $($events.Count) key events from: $planPath"
Write-Host "GameInput inbox: $keyPath"
Write-Host 'Start this sender after the game reaches the menu or scene you want to reproduce.'

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$index = 0
while ($index -lt $events.Count) {
    $at = $events[$index].AtSeconds
    while ($clock.Elapsed.TotalSeconds -lt $at) {
        Start-Sleep -Milliseconds 10
    }

    $batch = [System.Collections.Generic.List[object]]::new()
    while ($index -lt $events.Count -and $events[$index].AtSeconds -eq $at) {
        $batch.Add($events[$index])
        $index++
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($ConsumeTimeoutSeconds)
    while ((Test-Path -LiteralPath $keyPath) -or (Test-Path -LiteralPath $takenPath)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for the previous key batch to be consumed. Check that the game was launched with VICTORY_KEYS_FILE='$keyPath'."
        }
        Start-Sleep -Milliseconds 20
    }

    $lines = foreach ($event in $batch) {
        $duration = $event.HoldSeconds.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
        "$($event.Key) $duration"
    }
    [System.IO.File]::WriteAllLines($tempPath, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $keyPath

    $deadline = [DateTime]::UtcNow.AddSeconds($ConsumeTimeoutSeconds)
    while ((Test-Path -LiteralPath $keyPath) -or (Test-Path -LiteralPath $takenPath)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for GameInput to consume batch at $at seconds. Check the game log and key-file path."
        }
        Start-Sleep -Milliseconds 20
    }
    Write-Host ("Sent {0} key(s) at {1:0.###} s: {2}" -f $batch.Count, $at, (($batch | ForEach-Object { "$($_.Key)=$($_.HoldSeconds)s" }) -join ', '))
}

Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
Write-Host "Completed input plan in $($clock.Elapsed.TotalSeconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)) s."
