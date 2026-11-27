# Shader and pipeline triage

Use the report collector after building the diagnostics executable. It records
machine details, runs the offline shader-cache pass, produces per-program
translation diagnostics, and optionally warms pipelines recorded by earlier
game sessions.

From PowerShell at the repository root:

```powershell
cargo build --locked --profile diag -p victory --features diagnostics

.\scripts\collect-shader-report.ps1 `
  -Exe .\target\diag\victory.exe `
  -Jobs 4 `
  -WarmUsedPipelines
```

The report is written under
`%LOCALAPPDATA%\Vice-Tay\reports\shader-report-<timestamp>`, outside the
checkout. It contains:

- `shader-failures.txt`: shader hashes, source paths and precompile failures.
- `shader-precompile.log`: cache hit/write/failure totals.
- `shader-translation.log`: per-program translation outcomes and failure reasons.
- `pipeline-warm.log`: optional results for previously used host pipelines.
- `system.json`: OS, CPU, RAM and display-adapter/driver details.
- `result.json`: command exit codes and report paths.

Pass explicit shader source paths with `-Paths` to narrow an investigation.
Use `-ValidateDxil` when the Windows SDK DXIL validator is installed. Use
`-WarmUsedPipelines` only when the pipeline book already contains pipelines
recorded by a previous run with `VICTORY_PIPELINE_BOOK=1`.

The report does not copy title executables, game assets, translated shader
binaries or pipeline-library binaries. Logs may still contain local paths,
device details and title-relative addresses; review and redact them before
posting publicly.

## Capture a game session

Run the game through the normal launcher while retaining console output and
the exact build, title executable hash, hardware and settings used for that
session:

```powershell
.\scripts\run-diagnostic-session.ps1 `
  -Exe 'D:\victory-data\game\game.exe' `
  -Console series-s `
  -Machine auto `
  -Windowed `
  -CaptureFailedShaderDumps `
  -WarmUsedPipelines
```

The wrapper always records a pipeline book for the run, so `warm --used` can
revisit pipelines observed during gameplay. Failed shader dumps are optional
because they contain game-derived shader data; they are kept outside the
checkout. The session folder contains `console.log`, `session.json`, an
optional `failed-shaders` directory, and an optional `pipeline-warm.log`.

Share the full folder only after reviewing local paths and any title-derived
shader dumps. For public bug reports, remove the `failed-shaders` directory
unless the receiving maintainer specifically asks for those binaries.

A successful command exit means the offline operation completed according to
its cache contract. It does not prove that every shader is supported or that
the game renders correctly. Compare the failure list, the game's diagnostic
log and matched screenshots when investigating visual defects.
