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

## Replay a timed input plan

Vice-Tay's GameInput layer includes a test hook for timed keyboard input. It
reads a file named by `VICTORY_KEYS_FILE`; each line contains `<key> <seconds>`.
The game takes the file by renaming it to `.taken`, reads it, then removes it.
This avoids losing a batch written while the previous batch is being consumed.

Start Vice-Tay with a dedicated file path (keep it outside the checkout):

```powershell
$keys = Join-Path $env:TEMP 'vice-tay-keys.txt'
.\scripts\play.ps1 -Exe 'D:\victory-data\game\game.exe' -Console series-s -Machine auto -Windowed -More @{ VICTORY_KEYS_FILE = $keys }
```

Wait until the game is at the menu or scene you want to reproduce. In a second
PowerShell window, prepare a CSV input plan:

```csv
AtSeconds,Key,HoldSeconds
0.0,Enter,0.15
4.0,Enter,0.15
8.0,W,1.0
10.0,Right,0.25
```

Run the sender using the same key-file path:

```powershell
.\scripts\send-key-sequence.ps1 -KeyFile (Join-Path $env:TEMP 'vice-tay-keys.txt') -Plan .\my-route.csv
```

`AtSeconds` is relative to the sender's start; rows with the same offset are
sent together. `HoldSeconds` must be 0.05–30 seconds. Supported names are a
single letter or digit, `Enter`, `Esc`, `Tab`, `Back`, `Up`, `Down`, `Left`,
and `Right`. The game polls at most every 50 ms. Start the sender after the
game reaches the desired start screen so offsets are relative to a repeatable
scene rather than variable startup time.

Use the same save/checkpoint, camera, resolution and profile when comparing
runs. The script drives input only; it does not verify that a menu action or
movement succeeded. Record the session with
`run-diagnostic-session.ps1` and inspect the video/logs for the actual result.

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
