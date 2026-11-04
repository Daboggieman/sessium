# ci_smoke.ps1 - hermetic engine round-trip for the Windows port.
# Runs on CI (windows-latest, pwsh) and works anywhere pwsh runs.
#
# Builds a fake ~/.claude for machines A and B sharing one fake Drive, points
# sessium.ps1 at them via the SESSIUM_* env overrides, and drives the real
# CLI through a push/pull/sync/conflict sequence - the PowerShell twin of
# what test_sessium.py proves on Linux.

$ErrorActionPreference = "Stop"

$repo = $PSScriptRoot | Split-Path
$ps1 = Join-Path $repo "windows\sessium.ps1"

# --- tiny assertion helpers -------------------------------------------------

$script:failed = 0
function Assert-True([bool]$Cond, [string]$What) {
    if ($Cond) { Write-Host "  ok   $What" }
    else { Write-Host "  FAIL $What" -ForegroundColor Red; $script:failed++ }
}
function Assert-Equal([string]$Expected, [string]$Actual, [string]$What) {
    Assert-True ($Expected -ceq $Actual) "$What (expected: $Expected / got: $Actual)"
}
function Run-Sessium([string[]]$CliArgs) {
    $out = & $ps1 @CliArgs 2>&1
    $code = $LASTEXITCODE
    Write-Host ("  $ sessium " + ($CliArgs -join ' ') + "  ->  rc=$code")
    return @{ code = $code; text = ($out | Out-String) }
}

# --- fixture ----------------------------------------------------------------

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sessium-ci-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$proj = "-home-test-proj"
$claudeA = Join-Path $tmp "machine-a\.claude"
$claudeB = Join-Path $tmp "machine-b\.claude"
$drive = Join-Path $tmp "drive"
New-Item -ItemType Directory -Path (Join-Path $claudeA "projects\$proj") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $claudeB "projects\$proj") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $drive "backup\projects\$proj") -Force | Out-Null

# a two-turn transcript as jsonl (summary + meta + command + real user + assistant)
$lines = @(
    '{"type":"summary","summary":"ignored summary line"}',
    '{"type":"user","isMeta":true,"message":{"content":"meta text"}}',
    '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}',
    '{"type":"user","message":{"content":"hey, build me a spaceship"}}',
    '{"type":"assistant","message":{"content":"ok"}}'
)
$sessionText = ($lines -join "`n") + "`n"
$sessionA = Join-Path $claudeA "projects\$proj\aaa.jsonl"
Set-Content -LiteralPath $sessionA -Value $sessionText -Encoding UTF8

# config + env
Set-Content -Path (Join-Path $tmp "config.json") -Value '{"rclone_remote":"fake","drive_folder":"backup"}' -Encoding UTF8
$env:SESSIUM_CLAUDE_DIR = $claudeA
$env:SESSIUM_STATE = Join-Path $tmp "machine-a\state.json"
$env:SESSIUM_CONFIG = Join-Path $tmp "config.json"
$env:SESSIUM_RCLONE_BIN = Join-Path $repo "tests\fake_rclone.cmd"
$env:FAKE_DRIVE_ROOT = $drive

Write-Host "== roundtrip: A pushes, B pulls =="

# 1. A status: remote has nothing yet -> new-here
Set-Content -LiteralPath (Join-Path $tmp "config.json") -Value '{"rclone_remote":"fake","drive_folder":"backup"}' -Encoding UTF8
$r = Run-Sessium @("status")
Assert-True ($r.code -eq 0) "status exits 0"
Assert-True ($r.text -match "new-here") "status classifies new-here"

# 2. A push
$r = Run-Sessium @("push")
Assert-True ($r.code -eq 0) "push exits 0"
$driveFile = Join-Path $drive "backup\projects\$proj\aaa.jsonl"
Assert-True (Test-Path $driveFile) "session landed on the fake Drive"
Assert-True ($r.text -match "pushed: 1") "push reports 1"

# 3. B pulls
$env:SESSIUM_CLAUDE_DIR = $claudeB
$env:SESSIUM_STATE = Join-Path $tmp "machine-b\state.json"
$r = Run-Sessium @("pull")
Assert-True ($r.code -eq 0) "B pull exits 0"
$sessionB = Join-Path $claudeB "projects\$proj\aaa.jsonl"
Assert-True (Test-Path $sessionB) "session downloaded on B"
Assert-Equal $sessionText (Get-Content $sessionB -Raw) "content survives the round-trip"

$r = Run-Sessium @("status")
Assert-True ($r.text -match "in-sync") "B sees in-sync after pull"

# 4. A edits -> sync pushes it up; B sync pulls it down
$env:SESSIUM_CLAUDE_DIR = $claudeA
Add-Content -LiteralPath $sessionA -Value "A's extra line" -Encoding utf8
$r = Run-Sessium @("sync")
Assert-True ($r.text -match "pushed: 1") "A sync pushes the edit"
Assert-True ((Get-Content $driveFile -Raw).Contains("A's extra line")) "edit reached Drive"

$env:SESSIUM_CLAUDE_DIR = $claudeB
$r = Run-Sessium @("sync")
Assert-True ((Get-Content $sessionB -Raw).Contains("A's extra line")) "B syncs the edit down"

# 5. conflict: both edit, B pushes last -> A's sync resolves newest-wins
$env:SESSIUM_CLAUDE_DIR = $claudeA
Set-Content -LiteralPath $sessionA -Value "A was here" -Encoding utf8
$env:SESSIUM_CLAUDE_DIR = $claudeB
Set-Content -LiteralPath $sessionB -Value "B was here" -Encoding utf8
$null = Run-Sessium @("push")

$r = Run-Sessium @("sync")
Assert-True ($r.code -eq 0) "conflict sync exits 0"
Assert-True ($r.text -match "remote wins") "newest-wins picks remote (B pushed last)"
Assert-Equal "B was here" (Get-Content $sessionA -Raw) "A's local copy replaced by remote"
Assert-True (Test-Path (Join-Path $claudeA "projects\$proj\revert")) "loser kept in revert/"

# 6. diff works
$r = Run-Sessium @("diff", "aaa")
Assert-True ($r.code -eq 0) "diff exits 0"
Assert-True ($r.text -match "remote") "diff shows both sides"

Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "SMOKE FAILED: $script:failed assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host "smoke round-trip passed"
