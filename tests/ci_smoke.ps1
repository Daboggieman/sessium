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

# exact-byte writes: no BOM, no automatic CRLF translation (Set-Content
# would add both on Windows and break the round-trip comparisons)
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Exact([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

$sessionA = Join-Path $claudeA "projects\$proj\aaa.jsonl"
Write-Exact $sessionA $sessionText

# config + env
Write-Exact (Join-Path $tmp "config.json") '{"rclone_remote":"fake","drive_folder":"backup"}'
$env:SESSIUM_CLAUDE_DIR = $claudeA
$env:SESSIUM_STATE = Join-Path $tmp "machine-a\state.json"
$env:SESSIUM_CONFIG = Join-Path $tmp "config.json"
$env:SESSIUM_RCLONE_BIN = Join-Path $repo "tests\fake_rclone.cmd"
$env:FAKE_DRIVE_ROOT = $drive

Write-Host "== roundtrip: A pushes, B pulls =="

# 1. A status: remote has nothing yet -> new-here
Write-Exact (Join-Path $tmp "config.json") '{"rclone_remote":"fake","drive_folder":"backup"}'
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
Assert-Equal $sessionText ((Get-Content $sessionB -Raw) -replace "`r`n", "`n") "content survives the round-trip"

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
Write-Exact $sessionA "A was here`n"
$env:SESSIUM_CLAUDE_DIR = $claudeB
Write-Exact $sessionB "B was here`n"
$null = Run-Sessium @("push")

$env:SESSIUM_CLAUDE_DIR = $claudeA
$r = Run-Sessium @("sync")
Assert-True ($r.code -eq 0) "conflict sync exits 0"
Assert-True ($r.text -match "remote wins") "newest-wins picks remote (B pushed last)"
Assert-Equal "B was here`n" ((Get-Content $sessionA -Raw) -replace "`r`n", "`n") "A's local copy replaced by remote"
Assert-True (Test-Path (Join-Path $claudeA "projects\$proj\revert")) "loser kept in revert/"

# 6. diff works
$r = Run-Sessium @("diff", "aaa")
Assert-True ($r.code -eq 0) "diff exits 0"
Assert-True ($r.text -match "remote") "diff shows both sides"

# --- batch 3 foundations -----------------------------------------------------

Write-Host "== batch 3 foundations =="

# version
$r = Run-Sessium @("version")
Assert-True ($r.code -eq 0) "version exits 0"
Assert-True ($r.text -match "^sessium ") "version prints the banner"

# list --json: one JSON doc, schema keys present
$r = Run-Sessium @("list", "--json")
Assert-True ($r.code -eq 0) "list --json exits 0"
$json = @($r.text | ConvertFrom-Json)
Assert-True ($json.Count -ge 1) "list --json returns rows"
Assert-True ($null -ne $json[0].project -and $null -ne $json[0].id) "rows carry project/id"
Assert-True ($json[0].mtime -match "Z$") "mtime is UTC ISO"

# list --json --titles adds title
$r = Run-Sessium @("list", "--json", "--titles")
$json = @($r.text | ConvertFrom-Json)
Assert-True ($json[0].title -eq "hey, build me a spaceship") "--titles extracts the title"

# status --json
$r = Run-Sessium @("status", "--json")
Assert-True ($r.code -eq 0) "status --json exits 0"
$json = $r.text | ConvertFrom-Json
Assert-True ($json.reachable -eq $true) "status --json reports reachable"
Assert-True ($json.sessions -ge 1) "status --json counts sessions"
Assert-True ($json.rows[0].state -eq "in-sync") "rows carry state"
Assert-True ($null -ne $json.rows[0].local.md5) "rows carry local md5"

# diff --json
$r = Run-Sessium @("diff", "aaa", "--json")
Assert-True ($r.code -eq 0) "diff --json exits 0"
$json = $r.text | ConvertFrom-Json
Assert-True ($json.id -like "aaa*") "diff --json resolves the id"
Assert-True ($json.local.messages -ge 1) "diff --json counts messages"
Assert-True ($null -ne $json.remote -and $null -ne $json.ledger) "diff --json has remote + ledger"

# push --dry-run: prints intent, touches nothing
Add-Content -LiteralPath $sessionA -Value "A dry-run edit" -Encoding utf8
$r = Run-Sessium @("push", "--dry-run")
Assert-True ($r.text -match "would push") "push --dry-run prints intent"
Assert-True (-not (Get-Content $driveFile -Raw).Contains("A dry-run edit")) "dry-run touched nothing"

# real push clears the pending change, then --quiet is silent when in-sync
$null = Run-Sessium @("push")
$r = Run-Sessium @("push", "--quiet")
Assert-True ($r.code -eq 0) "push --quiet exits 0"
Assert-True ($r.text.Trim() -eq "") "push --quiet prints nothing when in-sync"

# lockfile: a fresh lock blocks a second transfer
$lockPath = Join-Path (Split-Path -Parent $env:SESSIUM_STATE) "sync.lock"
Set-Content -LiteralPath $lockPath -Value "held" -Encoding ASCII
$r = Run-Sessium @("push")
Assert-True ($r.code -eq 1) "fresh lock blocks a concurrent push"
Remove-Item -LiteralPath $lockPath -Force

# revert --dry-run: lists copies, prompts nothing (A lost its copy in step 5)
$r = Run-Sessium @("revert", "aaa", "--dry-run")
Assert-True ($r.code -eq 0) "revert --dry-run exits 0"
Assert-True ($r.text -match "would prompt") "revert --dry-run stops before the prompt"

# open prints the resume command (no cwd stamp -> flagged guess, still prints)
$r = Run-Sessium @("open", "aaa")
Assert-True ($r.code -eq 0) "open exits 0"
Assert-True ($r.text -match "claude --resume aaa") "open prints the resume line"

# log with no id behaves like list
$r = Run-Sessium @("log")
Assert-True ($r.code -eq 0) "log (no id) exits 0"
Assert-True ($r.text -match "aaa") "log lists sessions"

# log <id> with no snapshots yet is a friendly no-op
$r = Run-Sessium @("log", "aaa")
Assert-True ($r.code -eq 0) "log <id> exits 0"
Assert-True ($r.text -match "no history yet") "log <id> explains missing history"

Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "SMOKE FAILED: $script:failed assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host "smoke round-trip passed"
