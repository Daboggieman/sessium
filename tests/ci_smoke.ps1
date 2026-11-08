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
    # 2>&1 + 6>&1: errors AND Write-Host (pwsh's information stream is 6;
    # plain 2>&1 leaks tables to the console and leaves $r.text empty)
    $out = & $ps1 @CliArgs 2>&1 6>&1
    $code = $LASTEXITCODE
    Write-Host ("  $ sessium " + ($CliArgs -join ' ') + "  ->  rc=$code")
    return @{ code = $code; text = (($out | ForEach-Object { "$_" }) -join "`n") }
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

# Machine switch helper: ALWAYS move SESSIUM_CLAUDE_DIR and SESSIUM_STATE
# together. A stale SESSIUM_STATE makes one machine's sync classify against
# the other's ledger — A's edit-sync ran on B's ledger, recorded A's edited
# md5s there, and B's sync then re-pushed the pre-edit file over A's edit
# (every later assertion in the roundtrip failed). Use-Machine prevents it.
function Use-Machine([string]$Which) {
    if ($Which -eq "A") {
        $env:SESSIUM_CLAUDE_DIR = $claudeA
        $env:SESSIUM_STATE = Join-Path $tmp "machine-a\state.json"
    } else {
        $env:SESSIUM_CLAUDE_DIR = $claudeB
        $env:SESSIUM_STATE = Join-Path $tmp "machine-b\state.json"
    }
}

# config + env
Write-Exact (Join-Path $tmp "config.json") '{"rclone_remote":"fake","drive_folder":"backup"}'
Use-Machine "A"
$env:SESSIUM_CONFIG = Join-Path $tmp "config.json"
$env:SESSIUM_RCLONE_BIN = Join-Path $repo "tests\fake_rclone.cmd"
$env:FAKE_DRIVE_ROOT = $drive

Write-Host "== roundtrip: A pushes, B pulls =="

# 0. fresh remote: no backup/ folder at all is "empty", not "unreachable"
#    (regression: rc=3 directory-not-found from lsjson killed status/push/sync)
Remove-Item -LiteralPath (Join-Path $drive "backup") -Recurse -Force
$r = Run-Sessium @("status")
Assert-True ($r.code -eq 0) "fresh remote (no backup/ folder): status exits 0"
Assert-True ($r.text -match "new-here") "fresh remote: still classifies new-here"

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
Use-Machine "B"
$r = Run-Sessium @("pull")
Assert-True ($r.code -eq 0) "B pull exits 0"
$sessionB = Join-Path $claudeB "projects\$proj\aaa.jsonl"
Assert-True (Test-Path $sessionB) "session downloaded on B"
Assert-Equal $sessionText ((Get-Content $sessionB -Raw) -replace "`r`n", "`n") "content survives the round-trip"

$r = Run-Sessium @("status")
Assert-True ($r.text -match "in-sync") "B sees in-sync after pull"

# 4. A edits -> sync pushes it up; B sync pulls it down
Use-Machine "A"
Add-Content -LiteralPath $sessionA -Value "A's extra line" -Encoding utf8
$r = Run-Sessium @("sync")
Assert-True ($r.text -match "pushed: 1") "A sync pushes the edit"
Assert-True ((Get-Content $driveFile -Raw).Contains("A's extra line")) "edit reached Drive"

Use-Machine "B"
$r = Run-Sessium @("sync")
Assert-True ((Get-Content $sessionB -Raw).Contains("A's extra line")) "B syncs the edit down"

# 5. conflict: both edit, B pushes last -> A's sync resolves newest-wins
Use-Machine "A"
Write-Exact $sessionA "A was here`n"
Use-Machine "B"
Write-Exact $sessionB "B was here`n"
$null = Run-Sessium @("push")

Use-Machine "A"
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

# the conflict step left plain text in the session files; the title and
# message-count assertions below need a real transcript — restore it and
# push so the ledger matches again (in-sync for the --quiet test later)
Write-Exact $sessionA $sessionText
$null = Run-Sessium @("push")

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
# raw-text check, not the parsed value: ConvertFrom-Json coerces ISO date
# strings to [DateTime], which then prints culture-format ("11/07/2026…")
Assert-True ($r.text -match '"mtime": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') "mtime is UTC ISO"

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

# --- batch 4: history / checkout / gc / messages / search / deep check -------

Write-Host "== batch 4 =="

# log <id> lists the snapshot the step-5 conflict created (content-addressed)
$r = Run-Sessium @("log", "aaa")
Assert-True ($r.code -eq 0) "log <id> exits 0"
Assert-True ($r.text -match "history of aaa") "log <id> lists history"
Assert-True ($r.text -match "\d{4}-[0-9a-f]{8}") "snapshot names are <seq>-<md5[:8]>"
Assert-True ($r.text -match "sessium checkout") "log points at checkout"

# checkout --dry-run: names the file it would restore, touches nothing
$r = Run-Sessium @("checkout", "aaa", "1", "--dry-run")
Assert-True ($r.code -eq 0) "checkout --dry-run exits 0"
Assert-True ($r.text -match "would restore") "checkout --dry-run prints intent"

# checkout restores snapshot #1 (the conflict loser); the copy it displaces
# is snapshotted first, then the chosen snapshot MOVES out of history/ -
# so history holds exactly the displaced copy's snapshot afterwards
$histDir = Join-Path $claudeA "projects\$proj\aaa\history"
$r = Run-Sessium @("checkout", "aaa", "1")
Assert-True ($r.code -eq 0) "checkout exits 0"
Assert-True ($r.text -match "restored ") "checkout names the restored snapshot"
Assert-Equal "A was here`n" ((Get-Content $sessionA -Raw) -replace "`r`n", "`n") "checkout restored the conflict loser"
Assert-True (@(Get-ChildItem -LiteralPath $histDir -File -Filter "*.jsonl").Count -eq 1) "checkout leaves the displaced snapshot"
Assert-True (Test-Path (Join-Path $histDir "0002-*.jsonl")) "displaced copy got seq 2"

# bad seq: friendly listing, exit 1
$r = Run-Sessium @("checkout", "aaa", "99")
Assert-True ($r.code -eq 1) "checkout with unknown seq exits 1"
Assert-True ($r.text -match "no snapshot #99") "checkout names the missing seq"

# gc: default keep=10 has nothing to prune; --keep 1 pools revert/ + history/
# into one per-session pool and prunes beyond N TOTAL (matches Linux's
# test_gc_prunes_old_copies: 12 history + 2 revert, keep 2 -> prune 12). Here
# 2 reverts + 1 history exist, so keep=1 leaves exactly ONE copy. Which copy
# survives is NOT deterministic: the displaced canonical and its seq-2
# snapshot are identical copies with identical preserved mtimes, so their
# order in the pool is a sort-tie — assert the count, not the directory.
$r = Run-Sessium @("gc")
Assert-True ($r.code -eq 0) "gc exits 0"
Assert-True ($r.text -match "nothing to prune") "gc with default keep prunes nothing"

$r = Run-Sessium @("gc", "--keep", "1", "--dry-run")
Assert-True ($r.text -match "would prune") "gc --dry-run lists doomed files"
Assert-True ($r.text -match "2 file\(s\) would be pruned") "gc --dry-run summary counts 2"
$revCount = @(Get-ChildItem -LiteralPath (Join-Path $claudeA "projects\$proj\revert") -File -Filter "*.jsonl").Count
$histCount = @(Get-ChildItem -LiteralPath $histDir -File -Filter "*.jsonl").Count
Assert-True ($revCount -eq 2 -and $histCount -eq 1) "gc --dry-run touched nothing"

$r = Run-Sessium @("gc", "--keep", "1")
Assert-True ($r.text -match "pruned 2 file\(s\); kept 1 most recent per session") "gc reports the prune"
$revCount = @(Get-ChildItem -LiteralPath (Join-Path $claudeA "projects\$proj\revert") -File -Filter "*.jsonl").Count
$histCount = @(Get-ChildItem -LiteralPath $histDir -File -Filter "*.jsonl").Count
Assert-True (($revCount + $histCount) -eq 1) "gc kept exactly 1 copy per session pool"
Assert-True (Test-Path (Join-Path $claudeA "projects\$proj\aaa.jsonl")) "gc never touches canonical transcripts"

# diff --messages: rewrite A's copy as a fresh two-turn transcript; the Drive
# copy still holds the batch-3 realignment transcript (2 parseable messages,
# none shared with A's new first turn) -> common prefix 0, both sides add 2.
# The closing push below is then a clean local-changed-only push, which puts
# the session back in sync for the deep check's md5 spot-verify.
$lines4 = @(
    '{"type":"user","message":{"content":"seek me please"}}',
    '{"type":"assistant","message":{"content":"the body has zebra"}}'
)
Write-Exact $sessionA (($lines4 -join "`n") + "`n")

$r = Run-Sessium @("diff", "aaa", "--messages")
Assert-True ($r.code -eq 0) "diff --messages exits 0"
Assert-True ($r.text -match "common prefix: 0 message\(s\)") "diff --messages shows the divergence point"
Assert-True ($r.text -match "local adds 2") "diff --messages counts local adds"
Assert-True ($r.text -match "remote adds 2") "diff --messages counts remote adds"
Assert-True ($r.text -match "\+ user\s+seek me please") "diff --messages previews the message text"

$r = Run-Sessium @("diff", "aaa", "--json", "--messages")
Assert-True ($r.code -eq 0) "diff --json --messages exits 0"
$json = $r.text | ConvertFrom-Json
Assert-True ($json.preview.common -eq 0) "preview carries the common count"
Assert-True (@($json.preview.local_added).Count -eq 2) "preview lists local adds"
Assert-True ($json.preview.local_added[0][0] -eq "user") "preview entries are [role, text] pairs"
Assert-True (@($json.preview.remote_added).Count -eq 2) "preview lists remote adds"

# search: title match outranks body, snippets, --json schema, no-matches
$r = Run-Sessium @("search", "seek me please")
Assert-True ($r.code -eq 0) "search exits 0"
Assert-True ($r.text -match "1 match\(es\)") "search finds the title hit"
Assert-True ($r.text -match "title") "hit is tagged as a title match"

$r = Run-Sessium @("search", "zebra")
Assert-True ($r.text -match "1 match\(es\)") "search finds the body hit"
Assert-True ($r.text -match "body") "hit is tagged as a body match"
Assert-True ($r.text -match "zebra") "body hit shows a snippet"

$r = Run-Sessium @("search", "wumpus")
Assert-True ($r.text -match "no matches") "search reports no matches cleanly"

$r = Run-Sessium @("search", "seek me please", "--json")
$json = @($r.text | ConvertFrom-Json)
Assert-True ($json.Count -eq 1) "search --json returns one row"
Assert-True ($json[0].where -eq "title") "search --json carries where"
Assert-True ($json[0].project -eq $proj -and $json[0].id -like "aaa*") "search --json carries project/id"

# seek without a seeker config is a friendly failure
$r = Run-Sessium @("seek")
Assert-True ($r.code -eq 1) "seek without config exits 1"
Assert-True ($r.text -match "seeker not configured") "seek explains what to configure"
$r = Run-Sessium @("search", "x", "--semantic")
Assert-True ($r.code -eq 1) "search --semantic without config exits 1"

# push the fresh transcript, then the deep check verifies both sides agree
$null = Run-Sessium @("push")
$r = Run-Sessium @("check")
Assert-True ($r.code -eq 0) "check exits 0"
$r = Run-Sessium @("check", "--full")
Assert-True ($r.code -eq 0) "check --full exits 0"
Assert-True ($r.text -match "deep check \(--full\):") "check --full runs the deep check"
Assert-True ($r.text -match "no dead entries") "deep check: no dead ledger entries"
Assert-True ($r.text -match "no orphans on Drive") "deep check: no orphans"
Assert-True ($r.text -match "md5 matches on both sides") "deep check: spot-check entry"
Assert-True ($r.text -match "spot-check: 1 session\(s\) verified") "deep check: one session verified"

# sync --only memory: nothing yet -> intent -> push up -> pull down
$r = Run-Sessium @("sync", "--only", "memory")
Assert-True ($r.code -eq 0) "sync --only memory exits 0 with nothing present"
Assert-True ($r.text -match "nothing to sync for --only memory") "sync --only explains emptiness"

$memDir = Join-Path $claudeA "projects\$proj\memory"
New-Item -ItemType Directory -Path $memDir -Force | Out-Null
Write-Exact (Join-Path $memDir "note.md") "user notes live here`n"
$r = Run-Sessium @("sync", "--only", "memory", "--dry-run")
Assert-True ($r.text -match "would two-way sync") "sync --only --dry-run prints intent"
Assert-True (-not (Test-Path (Join-Path $drive "backup\projects\$proj\memory\note.md"))) "sync --only --dry-run touched nothing"

$r = Run-Sessium @("sync", "--only", "memory")
Assert-True ($r.text -match "\[OK\] synced memory: memory") "sync --only reports the pair"
Assert-True (Test-Path (Join-Path $drive "backup\projects\$proj\memory\note.md")) "memory file reached Drive"

Write-Exact (Join-Path $drive "backup\projects\$proj\memory\drive-note.md") "written on another machine`n"
$null = Run-Sessium @("sync", "--only", "memory")
Assert-True (Test-Path (Join-Path $memDir "drive-note.md")) "Drive-only memory pulled down"

# sync --only skills: config/skills two-ways
New-Item -ItemType Directory -Path (Join-Path $claudeA "skills") -Force | Out-Null
Write-Exact (Join-Path $claudeA "skills\my-skill.md") "skill body`n"
$null = Run-Sessium @("sync", "--only", "skills")
Assert-True (Test-Path (Join-Path $drive "backup\config\skills\my-skill.md")) "skills reached Drive"

# --- batch 5: schedule / hook / crypt -----------------------------------------

Write-Host "== batch 5 =="

# schedule --print: shows the schtasks command, installs nothing
$r = Run-Sessium @("schedule", "--print")
Assert-True ($r.code -eq 0) "schedule --print exits 0"
Assert-True ($r.text -match "schtasks /Create") "schedule --print shows the create command"
Assert-True ($r.text -match "/SC MINUTE /MO 30") "schedule --print defaults to 30 minutes"
Assert-True ($r.text -match "sessium.ps1`" sync") "schedule --print runs sessium sync"

# schedule install + off through a fake schtasks (hermetic: no real task).
# The stub is a .cmd on Windows and an executable sh script elsewhere —
# both append their args to schtasks-calls.log and exit 0. Without the
# platform match, a Linux run fails to exec the .cmd, $LASTEXITCODE stays
# stale at 0, and install "succeeds" without ever calling the stub.
$stubDir = Join-Path $tmp "fake-schtasks"
New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
if ($IsWindows) {
    $stub = Join-Path $stubDir "fake-schtasks.cmd"
    Write-Exact $stub "@echo off`necho %* >> `"%~dp0schtasks-calls.log`"`nexit /b 0`n"
} else {
    $stub = Join-Path $stubDir "fake-schtasks"
    Write-Exact $stub "#!/bin/sh`necho `"`$*`" >> `"`$(dirname `"`$0`")/schtasks-calls.log`"`nexit 0`n"
    [System.IO.File]::SetUnixFileMode($stub,
        [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
        [System.IO.UnixFileMode]::UserExecute -bor [System.IO.UnixFileMode]::GroupRead -bor
        [System.IO.UnixFileMode]::GroupExecute -bor [System.IO.UnixFileMode]::OtherRead -bor
        [System.IO.UnixFileMode]::OtherExecute)
}
$env:SESSIUM_SCHTASKS_BIN = $stub
$r = Run-Sessium @("schedule", "--interval", "15")
Assert-True ($r.code -eq 0) "schedule install exits 0"
Assert-True ($r.text -match "schedule installed") "schedule install reports success"
$stubLog = Join-Path $stubDir "schtasks-calls.log"
$stubText = Get-Content -LiteralPath $stubLog -Raw
Assert-True ($stubText -match "/Create /TN sessium-sync /SC MINUTE /MO 15") "schtasks got the create call"
$null = Run-Sessium @("schedule", "--off")
$stubText = Get-Content -LiteralPath $stubLog -Raw
Assert-True ($stubText -match "/Delete /TN sessium-sync /F") "schedule --off deletes the task"
Remove-Item -LiteralPath $stubLog -Force
Remove-Item Env:\SESSIUM_SCHTASKS_BIN

# hook: installs into settings.json alongside unrelated hooks, idempotent,
# --off removes only the sessium entry
$settingsPath = Join-Path $claudeA "settings.json"
Write-Exact $settingsPath '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo unrelated"}]}]}}'
$r = Run-Sessium @("hook")
Assert-True ($r.code -eq 0) "hook exits 0"
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$stopEntries = @($settings.hooks.Stop)
Assert-True ($stopEntries.Count -eq 2) "hook added one entry next to the existing one"
$sessiumEntries = @($stopEntries | Where-Object { (ConvertTo-Json $_ -Compress -Depth 5) -match "push --quiet" })
Assert-True ($sessiumEntries.Count -eq 1) "the added entry is the sessium push hook"
$null = Run-Sessium @("hook")
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
Assert-True (@($settings.hooks.Stop).Count -eq 2) "hook is idempotent (no duplicate)"
$r = Run-Sessium @("hook", "--off")
Assert-True ($r.code -eq 0) "hook --off exits 0"
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$stopEntries = @($settings.hooks.Stop)
Assert-True ($stopEntries.Count -eq 1) "hook --off removed only the sessium entry"
Assert-True ($stopEntries[0].hooks[0].command -eq "echo unrelated") "unrelated hook survived"

# hook --off on otherwise-empty settings leaves no hooks key behind
Remove-Item -LiteralPath $settingsPath -Force
$null = Run-Sessium @("hook")
$null = Run-Sessium @("hook", "--off")
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
Assert-True ($null -eq $settings.hooks) "hook --off leaves no empty hooks key"

# hook --print: previews, writes nothing
Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
$r = Run-Sessium @("hook", "--print")
Assert-True ($r.code -eq 0) "hook --print exits 0"
Assert-True ($r.text -match "would write") "hook --print previews"
Assert-True ($r.text -match "push --quiet") "hook --print shows the command"
Assert-True (-not (Test-Path -LiteralPath $settingsPath)) "hook --print touched nothing"

# setup --encrypted: crypt remote created over the plain one, config re-pointed,
# unknown keys preserved; LAST so later steps would see the crypt remote
Write-Exact (Join-Path $tmp "config.json") '{"rclone_remote":"fake","drive_folder":"backup","seeker_url":"http://seeker.example"}'
$r = Run-Sessium @("setup", "--encrypted")
Assert-True ($r.code -eq 0) "setup --encrypted exits 0"
Assert-True ($r.text -match "SAVE THIS PASSWORD") "setup --encrypted shows the password once"
Assert-True ($r.text -match "sessium-crypt") "setup --encrypted names the crypt remote"
$cryptLog = Join-Path $drive "rclone-config.log"
Assert-True (Test-Path -LiteralPath $cryptLog) "rclone config create was logged"
$cryptText = Get-Content -LiteralPath $cryptLog -Raw
Assert-True ($cryptText -match "sessium-crypt crypt remote=fake:backup password=\S+") "crypt was created over fake:backup with a password"
$cfgAfter = Get-Content -LiteralPath $env:SESSIUM_CONFIG -Raw | ConvertFrom-Json
Assert-True ($cfgAfter.rclone_remote -eq "sessium-crypt") "config now points at the crypt remote"
Assert-True ($cfgAfter.drive_folder -eq "") "drive_folder cleared (crypt root == old plain root)"
Assert-True ($cfgAfter.seeker_url -eq "http://seeker.example") "unknown config keys survived"

Write-Host "== batch 6 =="

# export: a session id or --all is required; single export writes one file
Use-Machine "A"
$r = Run-Sessium @("export")
Assert-True ($r.code -eq 1) "export without id or --all exits 1"
Assert-True ($r.text -match "--all") "export explains what to give"

$expDir = Join-Path $tmp "export"
$r = Run-Sessium @("export", "aaa", "--out", $expDir)
Assert-True ($r.code -eq 0) "export single exits 0"
$md = Get-Content -LiteralPath (Join-Path $expDir "aaa.md") -Raw
Assert-True ($md -match "^# seek me please") "markdown carries the title"
Assert-True ($md -match "## user") "markdown has user sections"
Assert-True ($md -match "## assistant") "markdown has assistant sections"
Assert-True ($md.Contains("- project: ``$proj``")) "markdown names the project in backticks"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $expDir "bbb.md"))) "single export writes only that session"

# --all: every local session, with the count
$r = Run-Sessium @("export", "--all", "--out", $expDir)
Assert-True ($r.code -eq 0) "export --all exits 0"
Assert-True ($r.text -match "exported 1 session\(s\)") "export --all reports the count"
Assert-True (Test-Path -LiteralPath (Join-Path $expDir "aaa.md")) "export --all wrote the file"

# html viewer: page + index
$expHtml = Join-Path $tmp "export-html"
$r = Run-Sessium @("export", "--all", "--html", "--out", $expHtml)
Assert-True ($r.code -eq 0) "export --html exits 0"
Assert-True ($r.text -match [regex]::Escape("(+ index.html)")) "html --all adds the index"
$page = Get-Content -LiteralPath (Join-Path $expHtml "aaa.html") -Raw
Assert-True ($page -match "class='msg user'") "html page has message divs"
Assert-True ($page.Contains("seek me please")) "html page carries message text"
$index = Get-Content -LiteralPath (Join-Path $expHtml "index.html") -Raw
Assert-True ($index -match "href='aaa.html'") "index links the session"

# html escaping: < > & " in the transcript must come out escaped
$escDir = Join-Path $tmp "export-esc"
Write-Exact $sessionA ('{"type":"user","message":{"content":"tags <b> & \"quotes\""}}' + "`n" + '{"type":"assistant","message":{"content":"ok"}}' + "`n")
$r = Run-Sessium @("export", "aaa", "--html", "--out", $escDir)
Assert-True ($r.code -eq 0) "export --html of special chars exits 0"
$page = Get-Content -LiteralPath (Join-Path $escDir "aaa.html") -Raw
Assert-True ($page.Contains("tags &lt;b&gt; &amp; &quot;quotes&quot;")) "html escapes < > & quotes"

# onboard: install the hook first so the installed-branch is exercised
$null = Run-Sessium @("hook")
Remove-Item Env:\SESSIUM_SCHTASKS_BIN -ErrorAction SilentlyContinue
$r = Run-Sessium @("onboard")
Assert-True ($r.code -eq 0) "onboard exits 0"
Assert-True ($r.text -match "rclone present") "onboard: rclone check"
Assert-True ($r.text -match "encryption: on") "onboard: encryption on under the crypt config"
Assert-True ($r.text -match "Drive reachable") "onboard: Drive check"
Assert-True ($r.text -match "local repo: \d+ project\(s\), \d+ session\(s\)") "onboard: local repo line"
Assert-True ($r.text -match "ledger: 1 session\(s\) recorded") "onboard: ledger line"
Assert-True ($r.text -match "sync timer: not installed") "onboard: timer missing on a bare machine"
Assert-True ($r.text -match "Stop hook: installed") "onboard: hook detected"
Assert-True ($r.text -match "suggested next steps:") "onboard: gaps become next steps"
Assert-True ($r.text -match "sessium schedule\s+# background sync") "onboard: schedule suggestion"
Assert-True ($r.text -match "help: sessium --help") "onboard: help footer"

# with a schtasks stub answering /Query, the timer reads as installed and the
# report ends all-set
$env:SESSIUM_SCHTASKS_BIN = $stub
$r = Run-Sessium @("onboard")
Assert-True ($r.code -eq 0) "onboard with stub exits 0"
Assert-True ($r.text -match "sync timer: installed") "onboard: timer detected through the stub"
Assert-True ($r.text -match "all set\. everyday commands") "onboard: all set when nothing is missing"
Remove-Item Env:\SESSIUM_SCHTASKS_BIN -ErrorAction SilentlyContinue

# --- retry / timeout / --verbose: a real sync lost 3 sessions to the fixed
# 300s copyto timeout (big transcripts, slow uplink) and 1 to rc=6 (rclone's
# own retries exhausted), and "sessium sync --verbose" was "unrecognized".
# Machine A's aaa still holds the escaping-test content and was never
# re-pushed, so each push below does exactly one copyto.
Write-Host "== retry / verbose =="

# --verbose is an alias of --debug, accepted on either side of the subcommand
$r = Run-Sessium @("version", "--verbose")
Assert-True ($r.code -eq 0) "--verbose after the subcommand is accepted"
$r = Run-Sessium @("--verbose", "version")
Assert-True ($r.code -eq 0) "--verbose before the subcommand is accepted"

# a transient failure (rc=6) is retried and the push succeeds;
# SESSIUM_RETRY_DELAY_SCALE collapses the 2s/4s backoff for tests
Use-Machine "A"
$env:SESSIUM_FAKE_FAIL_FIRST = "6,1"
$env:SESSIUM_RETRY_DELAY_SCALE = "0"
$r = Run-Sessium @("push")
Assert-True ($r.code -eq 0) "push survives one transient copyto failure"
Assert-True ($r.text -match "retry 1/2") "the retry is announced"
Assert-True ($r.text -match "pushed: 1") "push completes after the retry"
Assert-True ([System.IO.File]::ReadAllText((Join-Path $drive "projects\$proj\aaa.jsonl")) -ceq [System.IO.File]::ReadAllText($sessionA)) "the retried push landed the right bytes"

# when every attempt fails, the push reports FAILED and nothing lands
$env:SESSIUM_FAKE_FAIL_FIRST = "6,99"
Remove-Item -LiteralPath (Join-Path $drive "projects\$proj\aaa.jsonl") -Force
$r = Run-Sessium @("push")
Assert-True ($r.code -eq 1) "push fails after retries are exhausted"
Assert-True ($r.text -match "retry 1/2") "first retry ran"
Assert-True ($r.text -match "retry 2/2") "second retry ran"
Assert-True ($r.text -match "FAILED: 1") "the exhausted transfer is reported as FAILED"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $drive "projects\$proj\aaa.jsonl"))) "no partial upload landed"

# a permanent failure (rc=2, not found) fails on the first attempt - no retry
$env:SESSIUM_FAKE_FAIL_FIRST = "2,99"
$r = Run-Sessium @("push")
Assert-True ($r.code -eq 1) "permanent copyto failure still fails the push"
Assert-True ($r.text -notmatch "retry 1/2") "permanent errors are not retried"

Remove-Item Env:\SESSIUM_FAKE_FAIL_FIRST -ErrorAction SilentlyContinue
Remove-Item Env:\SESSIUM_RETRY_DELAY_SCALE -ErrorAction SilentlyContinue

Write-Host ""

Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "SMOKE FAILED: $script:failed assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host "smoke round-trip passed"
