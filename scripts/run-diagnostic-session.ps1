# Run one reproducible gameplay session and capture logs/pipeline evidence outside the checkout.
#
# Example:
#   .\scripts\run-diagnostic-session.ps1 -Exe D:\game\game.exe -Console series-s -Machine auto -Windowed -CaptureFailedShaderDumps -WarmUsedPipelines

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Exe,

    [ValidateSet('series-s', 'series-x')]
    [string]$Console = 'series-s',

    [ValidateSet('auto', '7900xtx', '4070', '4090', 'laptop')]
    [string]$Machine = 'auto',

    [ValidateSet('diag', 'release')]
    [string]$Build = 'diag',

    [switch]$Windowed,
    [switch]$NoPanel,
    [switch]$Safe,
    [switch]$RayTracing,
    [switch]$SkipShaders,
    [switch]$CaptureFailedShaderDumps,
    [switch]$WarmUsedPipelines,

    [string]$ReportRoot = $(if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'Vice-Tay\sessions'
    } else {
        Join-Path $HOME '.cache\vice-tay\sessions'
    })
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$exePath = (Resolve-Path -LiteralPath $Exe).Path
$victoryExe = Join-Path $repoRoot "target\$Build\victory.exe"
$playScript = Join-Path $PSScriptRoot 'play.ps1'
if (-not (Test-Path -LiteralPath $victoryExe -PathType Leaf)) {
    throw "Missing $victoryExe. Build first: cargo build --locked --profile $Build -p victory --features diagnostics"
}
if (-not (Test-Path -LiteralPath $playScript -PathType Leaf)) {
    throw "Missing launcher script: $playScript"
}

$reportRootPath = [System.IO.Path]::GetFullPath($ReportRoot)
$repoPrefix = $repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$insideRepo = $reportRootPath.Equals($repoRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $reportRootPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)
if ($insideRepo) {
    throw 'ReportRoot must be outside the repository. Use LocalAppData or another external folder.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionDir = Join-Path $reportRootPath "session-$stamp"
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$consoleLog = Join-Path $sessionDir 'console.log'
$warmLog = Join-Path $sessionDir 'pipeline-warm.log'
$failureDumpDir = Join-Path $sessionDir 'failed-shaders'

$more = @{ VICTORY_PIPELINE_BOOK = '1' }
if ($CaptureFailedShaderDumps) {
    New-Item -ItemType Directory -Path $failureDumpDir -Force | Out-Null
    $more.VICTORY_FAIL_DUMP = $failureDumpDir
}

$playArgs = @{
    Exe = $exePath
    Console = $Console
    Machine = $Machine
    Build = $Build
    More = $more
}
foreach ($switchName in @('Windowed', 'NoPanel', 'Safe', 'RayTracing', 'SkipShaders')) {
    if ($PSBoundParameters.ContainsKey($switchName)) { $playArgs[$switchName] = $true }
}

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$cpu = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name })
$gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [ordered]@{ Name = $_.Name; DriverVersion = $_.DriverVersion }
})
$titleHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
$victoryHash = (Get-FileHash -LiteralPath $victoryExe -Algorithm SHA256).Hash
$start = Get-Date
$exitCode = 0
$warmExit = $null

Write-Host "Session directory: $sessionDir"
Write-Host "Title SHA-256: $titleHash"
Write-Host "Vice-Tay SHA-256: $victoryHash"
Write-Host 'Pipeline-book recording is enabled for this run.'
if ($CaptureFailedShaderDumps) { Write-Host "Failed shader dumps: $failureDumpDir" }

Push-Location $repoRoot
try {
    try {
        & $playScript @playArgs *>&1 | Tee-Object -FilePath $consoleLog
        $exitCode = $LASTEXITCODE
    } catch {
        $_ | Out-String | Add-Content -LiteralPath $consoleLog -Encoding UTF8
        $exitCode = 1
    }

    if ($WarmUsedPipelines) {
        & $victoryExe warm --used *>&1 | Tee-Object -FilePath $warmLog
        $warmExit = $LASTEXITCODE
    }
} finally {
    Pop-Location
}

$result = [ordered]@{
    StartedAt = $start.ToString('o')
    EndedAt = (Get-Date).ToString('o')
    DurationSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
    ExitCode = $exitCode
    PipelineWarmExitCode = $warmExit
    OS = $os.Caption
    OSBuild = $os.BuildNumber
    CPU = $cpu
    PhysicalMemoryGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
    GPUs = $gpus
    ConsoleProfile = $Console
    MachineProfile = $Machine
    BuildProfile = $Build
    Windowed = [bool]$Windowed
    NoPanel = [bool]$NoPanel
    Safe = [bool]$Safe
    RayTracing = [bool]$RayTracing
    SkipShaders = [bool]$SkipShaders
    PipelineBook = $true
    WarmUsedPipelines = [bool]$WarmUsedPipelines
    FailedShaderDumps = [bool]$CaptureFailedShaderDumps
    TitleExecutable = $exePath
    TitleSha256 = $titleHash
    ViceTayExecutable = $victoryExe
    ViceTaySha256 = $victoryHash
    ConsoleLog = $consoleLog
    PipelineWarmLog = $warmLog
    FailedShaderDumpDirectory = $(if ($CaptureFailedShaderDumps) { $failureDumpDir } else { $null })
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $sessionDir 'session.json') -Encoding UTF8

Write-Host "Session evidence saved to: $sessionDir"
Write-Host "Game exit code: $exitCode"
if ($null -ne $warmExit) { Write-Host "Pipeline warm exit code: $warmExit" }
if ($exitCode -ne 0 -or ($null -ne $warmExit -and $warmExit -ne 0)) { exit 1 }
