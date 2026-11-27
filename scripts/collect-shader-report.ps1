# Collect repeatable shader and pipeline diagnostics without copying game assets.
#
# Example:
#   .\scripts\collect-shader-report.ps1 -Exe .\target\diag\victory.exe -WarmUsedPipelines

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Exe,

    [string[]]$Paths = @(),

    [ValidateRange(1, 64)]
    [int]$Jobs = 4,

    [string]$ReportRoot = $(if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'Vice-Tay\reports'
    } else {
        Join-Path $HOME '.cache\vice-tay\reports'
    }),

    [switch]$ValidateDxil,

    [switch]$WarmUsedPipelines
)

$ErrorActionPreference = 'Stop'

$exePath = (Resolve-Path -LiteralPath $Exe).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$reportRootPath = [System.IO.Path]::GetFullPath($ReportRoot)
$repoPrefix = $repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if ($reportRootPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReportRoot must be outside the repository. Use LocalAppData or another external folder.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $reportRootPath "shader-report-$stamp"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

function Invoke-Victory {
    param(
        [string[]]$Arguments,
        [string]$LogPath
    )
    & $exePath @Arguments *> $LogPath
    return $LASTEXITCODE
}

# Record enough machine detail to interpret adapter-specific shader output.
$computer = Get-CimInstance Win32_ComputerSystem
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$processors = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name })
$video = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [ordered]@{ Name = $_.Name; DriverVersion = $_.DriverVersion }
})
$system = [ordered]@{
    CapturedAt = (Get-Date).ToString('o')
    OS = $operatingSystem.Caption
    OSBuild = $operatingSystem.BuildNumber
    CPU = $processors
    PhysicalMemoryGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
    GPUs = $video
    VictoryExecutable = $exePath
    Jobs = $Jobs
}
$system | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $reportDir 'system.json') -Encoding UTF8

$configLog = Join-Path $reportDir 'config.log'
$configExit = Invoke-Victory -Arguments @('config') -LogPath $configLog
if ($configExit -ne 0) { throw "victory config failed with exit code $configExit. See $configLog" }

# Pretranslate all discovered shaders. The offline command now treats a
# failed cache write as a failure instead of claiming that the shader is cached.
$shaderFailures = Join-Path $reportDir 'shader-failures.txt'
$shaderLog = Join-Path $reportDir 'shader-precompile.log'
$shaderArgs = @('shaders', '--jobs', "$Jobs", '--list', $shaderFailures)
if ($Paths.Count -gt 0) { $shaderArgs += $Paths }
$shaderExit = Invoke-Victory -Arguments $shaderArgs -LogPath $shaderLog

# Generate the translator's per-program report: parsing, IR, structure,
# resource tracking, DXIL emission, and optional DXIL validation.
$translationLog = Join-Path $reportDir 'shader-translation.log'
$translationArgs = @('translate', '--jobs', "$Jobs", '--list')
if ($ValidateDxil) { $translationArgs += '--validate' }
if ($Paths.Count -gt 0) { $translationArgs += $Paths }
$translationExit = Invoke-Victory -Arguments $translationArgs -LogPath $translationLog

$warmExit = $null
$warmLog = $null
if ($WarmUsedPipelines) {
    $warmLog = Join-Path $reportDir 'pipeline-warm.log'
    $warmExit = Invoke-Victory -Arguments @('warm', '--used', '--jobs', "$Jobs") -LogPath $warmLog
}

$result = [ordered]@{
    ReportDirectory = $reportDir
    ShaderPrecompileExitCode = $shaderExit
    ShaderTranslationExitCode = $translationExit
    PipelineWarmExitCode = $warmExit
    ShaderFailureList = $shaderFailures
    ShaderPrecompileLog = $shaderLog
    ShaderTranslationLog = $translationLog
    PipelineWarmLog = $warmLog
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reportDir 'result.json') -Encoding UTF8

Write-Host "Shader report written to: $reportDir"
Write-Host "  Precompile exit: $shaderExit"
Write-Host "  Translation exit: $translationExit"
if ($null -ne $warmExit) { Write-Host "  Pipeline warm exit: $warmExit" }
Write-Host 'Review shader-failures.txt and shader-translation.log before sharing the report.'
if ($shaderExit -ne 0 -or $translationExit -ne 0 -or ($null -ne $warmExit -and $warmExit -ne 0)) {
    exit 1
}
