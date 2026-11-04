# sessium (Windows) - git-like version control for Claude Code sessions,
# with Google Drive (via rclone) as the remote.
#
# Native PowerShell 5.1+ port of linux/sessium. Reads and writes the same
# Drive data and the same ledger format; SPEC.md is the contract between
# the two versions and wins on any disagreement.
#
# Phase 4 surface (SPEC section 7): list, status, check, setup,
# push, pull, sync, diff, resolve, revert, adopt.
#
# Usage: powershell -ExecutionPolicy Bypass -File sessium.ps1 <command> [args]
#        (sessium.cmd on your PATH wraps this; install.ps1 installs both)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:Debug = $false
$script:Version = "0.1.0"

# ---------------------------------------------------------------- utilities

function Write-Dbg([string]$Msg) {
    if ($script:Debug) { Write-Host "  [debug] $Msg" -ForegroundColor DarkGray }
}

function Write-Info([string]$Msg) { Write-Host $Msg }

function Write-Warn2([string]$Msg) { Write-Host $Msg -ForegroundColor Yellow }

function Write-Fail([string]$Msg) {
    Write-Host "[X]  $Msg" -ForegroundColor Red
    exit 1
}

<# Munge a repo path the Claude Code way (SPEC section 2).
   Windows: every separator becomes '-', drive colon included:
   C:\Users\me\repo  ->  C:-Users-me-repo  #>
function ConvertTo-Munge([string]$Path) {
    return ($Path -replace '[\\/":*?<>|]', "-")
}

function Get-HumanSize([long]$Bytes) {
    if ($Bytes -ge 1MB) { return ("{0:N1}MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1}KB" -f ($Bytes / 1KB)) }
    return "${Bytes}B"
}

function Get-ShortId([string]$Id, [int]$Keep = 8) {
    if ($Id.Length -le $Keep) { return $Id }
    return $Id.Substring(0, $Keep)
}

<# Parse an rclone ModTime string ("2026-11-03T22:50:00.123456789Z",
   offsets like +01:00 allowed) into a UTC DateTime. Returns $null on
   empty/unparseable input. .NET Framework only parses up to 7 fractional
   digits, so trim the nanoseconds first. #>
function ConvertFrom-RcloneTime([string]$Value) {
    if (-not $Value) { return $null }
    $trimmed = [regex]::Replace($Value, '\.(\d{7})\d+', '$1')
    $trimmed = $trimmed -replace 'Z$', '+00:00'
    try {
        $dto = [DateTimeOffset]::Parse($trimmed,
            [System.Globalization.CultureInfo]::InvariantCulture)
        return $dto.UtcDateTime
    } catch {
        return $null
    }
}

function Format-Time($Value) {
    if ($null -eq $Value) { return "-" }
    if ($Value -is [DateTime]) {
        return $Value.ToString("MM-dd HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return "$Value"
}

<# Read an optional property off a parsed JSON object without tripping
   Set-StrictMode when it is absent (transcript lines vary). #>
function Get-JsonProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# ---------------------------------------------------------------- config

function Get-ClaudeDir {
    if ($env:SESSIUM_CLAUDE_DIR) { return $env:SESSIUM_CLAUDE_DIR }
    return (Join-Path $env:USERPROFILE ".claude")
}

function Get-ConfigPath {
    if ($env:SESSIUM_CONFIG) { return $env:SESSIUM_CONFIG }
    return (Join-Path $env:LOCALAPPDATA "sessium\config.json")
}

function Get-StatePath {
    if ($env:SESSIUM_STATE) { return $env:SESSIUM_STATE }
    return (Join-Path $env:LOCALAPPDATA "sessium\state.json")
}

function Get-RcloneBin {
    if ($env:SESSIUM_RCLONE_BIN) { return $env:SESSIUM_RCLONE_BIN }
    return "rclone"
}

<# Load config.json; fall back to a legacy ~/sessium/config.sh (DRIVE_REMOTE /
   DRIVE_DIR lines, same as the Linux version), then defaults. #>
function Get-SessiumConfig {
    $cfg = @{ Remote = "gdrive"; Folder = "claude-backup" }
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $remote = Get-JsonProp $raw "rclone_remote"
            $folder = Get-JsonProp $raw "drive_folder"
            if ($remote) { $cfg.Remote = [string]$remote }
            if ($folder) { $cfg.Folder = [string]$folder }
            return $cfg
        } catch {
            Write-Warn2 "  [!]  unreadable config $path — falling back to defaults"
        }
    }
    $legacy = Join-Path $env:USERPROFILE "sessium\config.sh"
    if (Test-Path -LiteralPath $legacy) {
        foreach ($line in (Get-Content -LiteralPath $legacy -Encoding UTF8)) {
            if ($line -match '^\s*(?:export\s+)?DRIVE_REMOTE\s*=\s*"?([^"\s]+)"?') {
                $cfg.Remote = $Matches[1]
            }
            if ($line -match '^\s*(?:export\s+)?DRIVE_DIR\s*=\s*"?([^"\s]+)"?') {
                $cfg.Folder = $Matches[1]
            }
        }
    }
    return $cfg
}

function ConvertTo-DriveUrl($Cfg, [string]$Sub) {
    if ($Sub) { return "$($Cfg.Remote):$($Cfg.Folder)/$Sub" }
    return "$($Cfg.Remote):$($Cfg.Folder)"
}

# ---------------------------------------------------------------- rclone

<# Quote one argument for a Windows command line (ProcessStartInfo.Arguments
   has no ArgumentList on .NET Framework / PowerShell 5.1). #>
function ConvertTo-ProcessArg([string]$A) {
    if ($A -eq "") { return '""' }
    if ($A -notmatch '[\s"]') { return $A }
    $a2 = $A -replace '(\\+)"', '$1$1\"'
    $a2 = $a2 -replace '(\\+)$', '$1$1'
    return "`"$a2`""
}

<# Run rclone and return stdout (raw text). With -ToFile, stdout goes to that
   file instead (streaming a remote transcript to disk). Throws with rclone's
   own stderr on failure. #>
function Invoke-Rclone {
    param(
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$RcloneArgs,
        [string]$ToFile,
        [int]$TimeoutSec = 120,
        [switch]$Quiet
    )
    $bin = Get-RcloneBin
    Write-Dbg "rclone $($RcloneArgs -join ' ')"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bin
    $psi.Arguments = (@($RcloneArgs | ForEach-Object { ConvertTo-ProcessArg $_ }) -join " ")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        throw "rclone $($RcloneArgs[0]) timed out after ${TimeoutSec}s"
    }
    $err = $errTask.Result.Trim()
    if ($proc.ExitCode -ne 0) {
        throw "rclone $($RcloneArgs -join ' ') failed (rc=$($proc.ExitCode))$(
            if ($err) { ": $err" })"
    }
    if ($ToFile) {
        [System.IO.File]::WriteAllText($ToFile, $outTask.Result, [System.Text.Encoding]::UTF8)
        return $null
    }
    if ($Quiet) { return $null }
    return $outTask.Result
}

function Invoke-RcloneLines {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RcloneArgs,
          [int]$TimeoutSec = 120)
    $text = Invoke-Rclone -RcloneArgs $RcloneArgs -TimeoutSec $TimeoutSec
    if (-not $text) { return @() }
    return @($text -split "`r?`n" | Where-Object { $_ -ne "" })
}

# ---------------------------------------------------------------- ledger

$script:LedgerVersion = 1

function New-Ledger {
    return @{ version = $script:LedgerVersion; sessions = @{} }
}

function Get-LedgerKey([string]$Project, [string]$Sid) { return "$Project/$Sid" }

<# Load the ledger. An unreadable one is a loud warning plus a fresh start —
   the bootstrap rule re-records matching sessions, so losing it must never
   cause data loss or mass conflicts (SPEC section 3). #>
function Get-Ledger {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { return New-Ledger }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $sessions = @{}
        $rawSessions = Get-JsonProp $raw "sessions"
        if ($rawSessions) {
            foreach ($prop in $rawSessions.PSObject.Properties) {
                $v = $prop.Value
                $sessions[$prop.Name] = @{
                    project = [string](Get-JsonProp $v "project")
                    id = [string](Get-JsonProp $v "id")
                    local_md5 = [string](Get-JsonProp $v "local_md5")
                    remote_md5 = [string](Get-JsonProp $v "remote_md5")
                    last_synced = [string](Get-JsonProp $v "last_synced")
                }
            }
        }
        $ver = Get-JsonProp $raw "version"
        return @{ version = [int]$ver; sessions = $sessions }
    } catch {
        Write-Warn2 "  [!]  unreadable ledger $path — starting fresh ($($_.Exception.Message))"
        return New-Ledger
    }
}

function Save-Ledger($Ledger) {
    $path = Get-StatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $obj = [ordered]@{
        version = $Ledger.version
        sessions = [ordered]@{}
    }
    $keys = @($Ledger.sessions.Keys | Sort-Object)
    foreach ($k in $keys) {
        $e = $Ledger.sessions[$k]
        $obj.sessions[$k] = [ordered]@{
            project = $e.project; id = $e.id
            local_md5 = $e.local_md5; remote_md5 = $e.remote_md5
            last_synced = $e.last_synced
        }
    }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Set-LedgerEntry($Ledger, [string]$Project, [string]$Sid,
                         [string]$LocalMd5, [string]$RemoteMd5) {
    $Ledger.sessions[(Get-LedgerKey $Project $Sid)] = @{
        project = $Project; id = $Sid
        local_md5 = $LocalMd5; remote_md5 = $RemoteMd5
        last_synced = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
}

# ---------------------------------------------------------------- discovery

function Get-FileMd5([string]$Path) {
    try {
        return (Get-FileHash -Algorithm MD5 -LiteralPath $Path).Hash.ToLower()
    } catch {
        return $null        # unreadable = "changed", never silently overwrite
    }
}

<# Discover local sessions: @{ "<munged>" = @( @{ id, path, size, mtime } ) }
   mtime is a UTC DateTime (LastWriteTimeUtc). #>
function Get-LocalSessions {
    $root = Join-Path (Get-ClaudeDir) "projects"
    $map = @{}
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    foreach ($projDir in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($f in (Get-ChildItem -LiteralPath $projDir.FullName -File -Filter "*.jsonl" |
                         Sort-Object Name)) {
            $rows.Add(@{
                id = $f.BaseName
                path = $f.FullName
                size = $f.Length
                mtime = $f.LastWriteTimeUtc
            })
        }
        $map[$projDir.Name] = $rows
    }
    return $map
}

<# One message's content -> plain text (string content, or the text blocks
   of a block array). #>
function Get-MessageText($Content) {
    if ($null -eq $Content) { return "" }
    if ($Content -is [string]) { return $Content }
    $parts = @()
    foreach ($block in @($Content)) {
        if (-not $block) { continue }
        if ((Get-JsonProp $block "type") -eq "text" -and (Get-JsonProp $block "text")) {
            $parts += [string](Get-JsonProp $block "text")
        }
    }
    return ($parts -join " ")
}

<# First real user message (skips meta lines and command/ide noise), first
   70 chars — the session's display title. Empty string when none. #>
function Get-SessionTitle([string]$Path, [int]$MaxLines = 200) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($n -ge $MaxLines) { break }
        $n++
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ((Get-JsonProp $obj "type") -ne "user" -or (Get-JsonProp $obj "isMeta")) { continue }
        $msg = Get-JsonProp $obj "message"
        if (-not $msg) { continue }
        $text = (Get-MessageText $msg.content).Trim()
        if (-not $text) { continue }
        if ($text.StartsWith("<command-") -or $text.StartsWith("<local-command") -or
            $text.StartsWith("<ide_")) { continue }
        if ($text.Length -gt 70) { $text = $text.Substring(0, 67) + "..." }
        return $text
    }
    return ""
}

<# Count user/assistant messages and grab the last meaningful snippet —
   what diff shows instead of a byte-level diff. #>
function Read-Transcript([string]$Path) {
    $result = @{ messages = 0; last = "" }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ((Get-JsonProp $obj "type") -ne "user" -and (Get-JsonProp $obj "type") -ne "assistant") { continue }
        if (Get-JsonProp $obj "isMeta") { continue }
        $msg = Get-JsonProp $obj "message"
        if (-not $msg) { continue }
        $text = (Get-MessageText $msg.content).Trim()
        if (-not $text) { continue }
        $result.messages++
        if ($text.Length -gt 70) { $text = $text.Substring(0, 67) + "..." }
        $result.last = $text
    }
    return $result
}

<# Fetch a remote transcript to a temp file (rclone cat), caller unlinks.
   Returns the temp path, or $null when the fetch fails. #>
function Get-RemoteTranscript($Cfg, [string]$Project, [string]$Sid) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sessium-" + $Sid.Substring(0, 8) + ".jsonl")
    try {
        Invoke-Rclone -RcloneArgs @("cat", (ConvertTo-DriveUrl $Cfg "projects/$Project/$Sid.jsonl")) `
            -ToFile $tmp -TimeoutSec 120
        return $tmp
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $null
    }
}

<# Remote sessions via one recursive lsjson: @{ "<munged>" = @( @{ id, size,
   mtime (UTC DateTime), md5 } ) }. Only top-level .jsonl per project. #>
function Get-RemoteSessions($Cfg) {
    $map = @{}
    $url = ConvertTo-DriveUrl $Cfg "projects"
    $text = Invoke-Rclone -RcloneArgs @("lsjson", "--recursive", "--hash", $url)
    if (-not $text) { return $map }
    $entries = @($text | ConvertFrom-Json)
    foreach ($e in $entries) {
        if ($e.IsDir) { continue }
        if ($e.Path -notmatch '^([^/]+)/([^/]+)\.jsonl$') { continue }
        $proj = $Matches[1]
        $sid = $Matches[2]
        if (-not $map.ContainsKey($proj)) { $map[$proj] = New-Object System.Collections.Generic.List[object] }
        $map[$proj].Add(@{
            id = $sid
            size = [long]$e.Size
            mtime = ConvertFrom-RcloneTime $e.ModTime
            md5 = (Get-JsonProp (Get-JsonProp $e "Hashes") "MD5")
        })
    }
    return $map
}

# ------------------------------------------------------- classification

<# The SPEC section 4 state machine. Compare the CURRENT md5s against the
   ledger record. Never line-merges, never deletes: one side missing with a
   ledger entry means the other side gets re-uploaded / re-downloaded. #>
function Get-ClassificationRow([string]$Project, [string]$Sid, $Local, $Remote, $Entry) {
    $row = @{
        project = $Project; id = $Sid
        local = $Local; remote = $Remote; entry = $Entry
        local_md5 = $null; remote_md5 = $null
    }
    if ($Local) { $row.local_md5 = Get-FileMd5 $Local.path }
    if ($Remote) { $row.remote_md5 = $Remote.md5 }

    $haveLocal = ($null -ne $Local)
    $haveRemote = ($null -ne $Remote)

    if ($haveLocal -and $haveRemote -and $Entry) {
        $lOk = ($row.local_md5 -and $row.local_md5 -eq $Entry.local_md5)
        $rOk = ($row.remote_md5 -and $row.remote_md5 -eq $Entry.remote_md5)
        if ($lOk -and $rOk) { $row.state = "in-sync" }
        elseif ($lOk) { $row.state = "pull" }
        elseif ($rOk) { $row.state = "push" }
        else { $row.state = "conflict" }
        return $row
    }
    if ($haveLocal -and $haveRemote) {          # no ledger entry: bootstrap
        if ($row.local_md5 -and $row.local_md5 -eq $row.remote_md5) {
            $row.state = "in-sync"; $row.bootstrap = $true
        } else {
            $row.state = "conflict"
        }
        return $row
    }
    if ($haveLocal) { $row.state = "new-here"; return $row }
    $row.state = "new-there"
    return $row
}

function Get-Classification($LocalMap, $RemoteMap, $Ledger) {
    $rows = New-Object System.Collections.Generic.List[object]
    $projects = @($LocalMap.Keys + $RemoteMap.Keys | Sort-Object -Unique)
    foreach ($proj in $projects) {
        $locals = @(); if ($LocalMap.ContainsKey($proj)) { $locals = @($LocalMap[$proj]) }
        $remotes = @(); if ($RemoteMap.ContainsKey($proj)) { $remotes = @($RemoteMap[$proj]) }
        $ids = @(($locals | ForEach-Object { $_.id }) +
                 ($remotes | ForEach-Object { $_.id }) | Sort-Object -Unique)
        foreach ($sid in $ids) {
            $local = $null; foreach ($l in $locals) { if ($l.id -eq $sid) { $local = $l; break } }
            $remote = $null; foreach ($r in $remotes) { if ($r.id -eq $sid) { $remote = $r; break } }
            $entry = $null
            $key = Get-LedgerKey $proj $sid
            if ($Ledger.sessions.ContainsKey($key)) { $entry = $Ledger.sessions[$key] }
            $rows.Add((Get-ClassificationRow $proj $sid $local $remote $entry))
        }
    }
    return $rows
}

<# Resolve a session id prefix against the classified rows. Zero matches ->
   fail (exit 1). Several -> fail with the candidates. One -> the row. #>
function Find-OneSession([string]$Prefix, $Rows) {
    $hits = @($Rows | Where-Object { $_.id.StartsWith($Prefix) })
    if ($hits.Count -eq 0) {
        Write-Fail "no session id starts with '$Prefix' (try 'sessium list')"
    }
    if ($hits.Count -gt 1) {
        Write-Info "ambiguous id prefix '$Prefix' — could be:"
        foreach ($m in $hits) {
            Write-Info ("    {0}  {1}/{2}" -f (Get-ShortId $m.id), $m.project, $m.id)
        }
        exit 1
    }
    return $hits[0]
}

function Format-State([string]$State) {
    if ($State -eq "conflict") { return "CONFLICT" }
    return $State
}

# ---------------------------------------------------------------- transfers

function Get-LocalSessionPath([string]$Project, [string]$Sid) {
    return (Join-Path (Join-Path (Join-Path (Get-ClaudeDir) "projects") $Project) "$Sid.jsonl")
}

function Copy-Up([string]$LocalPath, [string]$RemoteUrl) {
    Invoke-Rclone -RcloneArgs @("copyto", $LocalPath, $RemoteUrl) -TimeoutSec 300
}

function Copy-Down([string]$RemoteUrl, [string]$LocalPath) {
    $dir = Split-Path -Parent $LocalPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Invoke-Rclone -RcloneArgs @("copyto", $RemoteUrl, $LocalPath) -TimeoutSec 300
}

<# Unique revert-copy path: <dir>/revert/<sid>.revert-<yyyyMMdd-HHmmss>.jsonl,
   sub-second collisions get a -N before .jsonl (SPEC section 6). #>
function Get-RevertPath([string]$Project, [string]$Sid) {
    $dir = Join-Path (Join-Path (Join-Path (Get-ClaudeDir) "projects") $Project) "revert"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $path = Join-Path $dir "$Sid.revert-$stamp.jsonl"
    $n = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $dir "$Sid.revert-$stamp-$n.jsonl"
        $n++
    }
    return $path
}

# A losing LOCAL copy is moved (not copied) into revert/.
function Save-LocalRevert([string]$Project, [string]$Sid, [string]$Src) {
    $dst = Get-RevertPath $Project $Sid
    Move-Item -LiteralPath $Src -Destination $dst -Force
    Write-Info "         local copy kept as $(Split-Path -Leaf $dst)"
    return $dst
}

# A losing REMOTE copy is downloaded into revert/ before anything overwrites it.
function Save-RemoteRevert($Cfg, [string]$Project, [string]$Sid) {
    $dst = Get-RevertPath $Project $Sid
    Copy-Down (ConvertTo-DriveUrl $Cfg "projects/$Project/$Sid.jsonl") $dst
    Write-Info "         remote copy kept as $(Split-Path -Leaf $dst)"
    return $dst
}

# ---------------------------------------------------------- conflicts

function Get-WantInteractive {
    return -not [Console]::IsInputRedirected
}

<# Ask [L]ocal / [R]emote / [B]oth (newest wins) / [S]kip. Empty answer =
   newest-wins; EOF (piped input that ran dry) = skip. #>
function Get-ConflictChoice($Row) {
    Write-Info ""
    Write-Info ("CONFLICT  {0}/{1} — both copies changed since the last sync" -f $Row.project, $Row.id)
    Write-Info ("          local  : {0}  {1}  {2}" -f `
        (Get-HumanSize $Row.local.size), (Format-Time $Row.local.mtime), $Row.local.path)
    Write-Info ("          remote : {0}  {1}  (Drive)" -f `
        (Get-HumanSize $Row.remote.size), (Format-Time $Row.remote.mtime))
    while ($true) {
        $answer = Read-Host "[L]ocal / [R]emote / [B]oth (newest wins) / [S]kip?"
        $a = "$answer".Trim().ToLower()
        if ($a -eq "" -or $a -eq "b") { return "auto" }
        if ($a -eq "l") { return "local" }
        if ($a -eq "r") { return "remote" }
        if ($a -eq "s") { return "skip" }
        Write-Info "  answer l, r, b, or s (empty = newest wins)"
    }
}

<# Decide a conflict: interactive prompt when asked, otherwise newest-wins
   (Drive ModTime vs local mtime, both UTC; tie goes to local — SPEC 6). #>
function Resolve-ConflictRow($Row, [bool]$Interactive) {
    if ($Interactive) { return (Get-ConflictChoice $Row) }
    $localNewer = ($null -eq $Row.remote.mtime) -or
                  ($Row.local.mtime -ge $Row.remote.mtime)
    if ($localNewer) { return "local" }
    return "remote"
}

<# Apply a conflict decision. The loser is never deleted — it becomes a
   revert copy first. Afterwards both ledger md5s describe the surviving
   copy, so the next classification is in-sync. #>
function Invoke-ApplyConflict($Cfg, $Row, [string]$Choice, $Ledger) {
    $localPath = $Row.local.path
    $remoteUrl = ConvertTo-DriveUrl $Cfg "projects/$($Row.project)/$($Row.id).jsonl"

    if ($Choice -eq "skip") {
        Write-Warn2 "  skipped (still conflicted)"
        return "skipped"
    }

    if ($Choice -eq "local") {
        if ($Row.remote) {
            Save-RemoteRevert $Cfg $Row.project $Row.id | Out-Null
            Copy-Up $localPath $remoteUrl
        } else {
            Copy-Up $localPath $remoteUrl
        }
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.local_md5 $Row.local_md5
        Write-Info "  ->  local wins, uploaded"
        return "resolved"
    }

    if ($Choice -eq "remote") {
        if ($Row.local) {
            Save-LocalRevert $Row.project $Row.id $localPath | Out-Null
        }
        $tmpLocal = Get-LocalSessionPath $Row.project $Row.id
        Copy-Down $remoteUrl $tmpLocal
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.remote_md5 $Row.remote_md5
        Write-Info "  ->  remote wins, downloaded"
        return "resolved"
    }

    # "auto": newest wins, tie goes to local
    $useLocal = ($null -eq $Row.remote.mtime) -or
                ($Row.local.mtime -ge $Row.remote.mtime)
    if ($useLocal) {
        if ($Row.remote) { Save-RemoteRevert $Cfg $Row.project $Row.id | Out-Null }
        Copy-Up $localPath $remoteUrl
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.local_md5 $Row.local_md5
        Write-Info ("  ->  local wins (newer: {0}), uploaded" -f (Format-Time $Row.local.mtime))
    } else {
        if ($Row.local) { Save-LocalRevert $Row.project $Row.id $localPath | Out-Null }
        Copy-Down $remoteUrl (Get-LocalSessionPath $Row.project $Row.id)
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.remote_md5 $Row.remote_md5
        Write-Info ("  ->  remote wins (newer: {0}), downloaded" -f (Format-Time $Row.remote.mtime))
    }
    return "resolved"
}

# ---------------------------------------------------------------- commands

function Invoke-ListSessions([string]$Project, [switch]$Titles) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = $null
    try { $remoteMap = Get-RemoteSessions $cfg } catch { $remoteMap = $null }
    $localOnly = ($null -eq $remoteMap)
    if ($localOnly) { $remoteMap = @{} }

    $items = New-Object System.Collections.Generic.List[object]
    $projects = @($localMap.Keys + $remoteMap.Keys | Sort-Object -Unique)
    foreach ($proj in $projects) {
        if ($Project -and $proj -ne $Project) { continue }
        $seen = @{}
        if ($localMap.ContainsKey($proj)) {
            foreach ($l in $localMap[$proj]) {
                $seen[$l.id] = $true
                $items.Add(@{ proj = $proj; id = $l.id; size = $l.size; mtime = $l.mtime; where = "local" })
            }
        }
        if ($remoteMap.ContainsKey($proj)) {
            foreach ($r in $remoteMap[$proj]) {
                if ($seen.ContainsKey($r.id)) { continue }
                $items.Add(@{ proj = $proj; id = $r.id; size = $r.size; mtime = $r.mtime; where = "remote" })
            }
        }
    }
    $sorted = @($items | Sort-Object -Property mtime -Descending)
    if ($localOnly) {
        Write-Warn2 "  (remote unreachable — local-only view)"
    }
    if ($sorted.Count -eq 0) {
        Write-Info "no sessions found"
        return
    }
    foreach ($it in $sorted) {
        $key = Get-LedgerKey $it.proj $it.id
        $state = "new-" + $(if ($it.where -eq "local") { "here" } else { "there" })
        if ($ledger.sessions.ContainsKey($key)) { $state = "in-sync?" }
        $line = "{0}  {1}  {2}  {3}  {4}" -f `
            ($it.mtime.ToString("yyyy-MM-dd HH:mm")), (Get-ShortId $it.id),
            (Get-HumanSize $it.size), $it.proj, $it.id
        Write-Info $line
        if ($Titles) {
            $title = Get-SessionTitle (Get-LocalSessionPath $it.proj $it.id)
            if (-not $title -and $it.where -eq "remote") {
                $tmp = Get-RemoteTranscript $cfg $it.proj $it.id
                if ($tmp) {
                    $title = Get-SessionTitle $tmp
                    Remove-Item -LiteralPath $tmp -Force
                }
            }
            if ($title) { Write-Info "        $title" }
        }
    }
    Write-Info ""
    Write-Info ("{0} session(s)" -f $sorted.Count)
}

function Invoke-Status([string]$Project) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = $null
    try { $remoteMap = Get-RemoteSessions $cfg } catch {
        Write-Warn2 "  [!]  remote unreachable ($($_.Exception.Message)) — local-only view"
        $remoteMap = @{}
    }

    $rows = Get-Classification $localMap $remoteMap $ledger
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $counts = @{}
    foreach ($r in $rows) {
        if (-not $counts.ContainsKey($r.state)) { $counts[$r.state] = 0 }
        $counts[$r.state]++
    }
    $projCount = @($rows | ForEach-Object { $_.project } | Sort-Object -Unique).Count
    Write-Info ("projects: {0}   sessions: {1}" -f $projCount, $rows.Count)
    $order = @("in-sync", "push", "pull", "conflict", "new-here", "new-there")
    foreach ($st in $order) {
        if ($counts.ContainsKey($st) -and $counts[$st] -gt 0) {
            Write-Info ("  {0}: {1}" -f (Format-State $st), $counts[$st])
        }
    }
    if ($rows.Count -eq 0) { return }

    Write-Info ""
    Write-Info ("{0,-10}  {1,-8}  {2,-11}  {3,7}  {4}" -f "STATE", "ID", "MODIFIED", "SIZE", "PROJECT")
    foreach ($r in ($rows | Sort-Object -Property @{ Expression = {
            if ($_.local) { $_.local.mtime } else { $_.remote.mtime } }; Descending = $true })) {
        $when = "-"; $size = "-"
        if ($r.local) { $when = Format-Time $r.local.mtime; $size = Get-HumanSize $r.local.size }
        elseif ($r.remote) { $when = Format-Time $r.remote.mtime; $size = Get-HumanSize $r.remote.size }
        Write-Info ("{0,-10}  {1,-8}  {2,-11}  {3,7}  {4}" -f `
            (Format-State $r.state), (Get-ShortId $r.id), $when, $size, $r.project)
    }
    if ($counts.ContainsKey("conflict")) {
        Write-Info ""
        Write-Info "conflicts need a decision:  sessium sync   (prompts on a terminal;"
        Write-Info "                            or resolve one:  sessium resolve <id>)"
    }
}

function Invoke-Check {
    $ok = $true
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger

    Write-Info "1. rclone present"
    try {
        $v = Invoke-Rclone -RcloneArgs @("version")
        $first = (@($v -split "`r?`n") | Select-Object -First 1)
        Write-Info ("   ok  {0}" -f $first)
    } catch {
        Write-Warn2 "   FAIL: $($_.Exception.Message)"
        Write-Fail "install rclone first (see setup-windows.ps1)"
    }

    Write-Info "2. remote reachable"
    $projUrl = ConvertTo-DriveUrl $cfg "projects"
    try {
        Invoke-Rclone -RcloneArgs @("lsd", (ConvertTo-DriveUrl $cfg $null)) | Out-Null
        Write-Info ("   ok  remote '{0}' reachable" -f $cfg.Remote)
    } catch {
        Write-Warn2 "   FAIL: $($_.Exception.Message)"
        $ok = $false
    }

    Write-Info "3. folder exists"
    try {
        Invoke-Rclone -RcloneArgs @("lsd", $projUrl) | Out-Null
        Write-Info ("   ok  {0}" -f $projUrl)
    } catch {
        Write-Warn2 ("   FAIL: {0} missing" -f $projUrl)
        Write-Warn2 "   run 'sessium push' once to create it"
        $ok = $false
    }

    Write-Info "4. local claude dir"
    $claude = Get-ClaudeDir
    if (Test-Path -LiteralPath (Join-Path $claude "projects")) {
        Write-Info "   ok  $claude"
    } else {
        Write-Warn2 "   FAIL: $claude has no projects/"
        $ok = $false
    }

    Write-Info "5. ledger"
    $statePath = Get-StatePath
    if (Test-Path -LiteralPath $statePath) {
        Write-Info ("   ok  {0}  ({1} session(s) recorded)" -f $statePath, $ledger.sessions.Count)
    } else {
        Write-Info "   --  $statePath (absent — push/pull/sync will create it)"
    }

    Write-Info "6. session counts"
    $localCount = 0; $remoteCount = 0
    try {
        foreach ($l in (Get-LocalSessions).Values) { $localCount += @($l).Count }
        foreach ($r in (Get-RemoteSessions $cfg).Values) { $remoteCount += @($r).Count }
        Write-Info ("   local: {0} session(s), remote: {1} session(s)" -f $localCount, $remoteCount)
    } catch {
        Write-Warn2 "   FAIL: could not count sessions: $($_.Exception.Message)"
        $ok = $false
    }

    Write-Info ""
    if ($ok) { Write-Info "all checks passed" } else { Write-Fail "some checks failed (see above)" }
}

# ------------------------------------------------------------ push/pull/sync

function Write-TransferSummary([string]$Verb, [int]$Moved, [int]$Skipped, [int]$InSync, [int]$Failures) {
    $parts = @()
    if ($Moved -gt 0) { $parts += ("{0}: {1}" -f $Verb, $Moved) }
    if ($Skipped -gt 0) { $parts += "conflicts skipped: $Skipped" }
    $parts += "in-sync: $InSync"
    if ($Failures -gt 0) { $parts += "FAILURES: $Failures" }
    Write-Info ("  " + ($parts -join "   "))
}

function Invoke-Push([string]$Project) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = @{}
    try { $remoteMap = Get-RemoteSessions $cfg } catch {
        Write-Warn2 "  [!]  remote unreachable ($($_.Exception.Message)) — nothing can be pushed"
        exit 1
    }
    $rows = Get-Classification $localMap $remoteMap $ledger
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $pushed = 0; $skipped = 0; $failures = 0; $dirty = $false
    $bootstrapCount = 0
    foreach ($r in $rows) {
        if ($r.state -eq "in-sync" -and -not $r.entry) {
            Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.remote_md5
            $bootstrapCount++
            $dirty = $true
            continue
        }
        if ($r.state -eq "conflict") {
            $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
            Write-Warn2 "  CONFLICT $label — skipped (sync or resolve decides conflicts)"
            $skipped++
            continue
        }
        if ($r.state -ne "push" -and $r.state -ne "new-here") { continue }
        $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
        Write-Info "  pushing $label"
        try {
            Copy-Up $r.local.path (ConvertTo-DriveUrl $cfg "projects/$($r.project)/$($r.id).jsonl")
            Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.local_md5
            $pushed++; $dirty = $true
        } catch {
            Write-Warn2 "  [!]  push failed for ${label}: $($_.Exception.Message)"
            $failures++
        }
    }
    if ($dirty) { Save-Ledger $ledger }
    Write-TransferSummary "pushed" $pushed $skipped $bootstrapCount $failures
    if ($failures -gt 0) { exit 1 }
}

function Invoke-Pull([string]$Project) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = @{}
    try { $remoteMap = Get-RemoteSessions $cfg } catch {
        Write-Warn2 "  [!]  remote unreachable ($($_.Exception.Message)) — nothing can be pulled"
        exit 1
    }
    $rows = Get-Classification $localMap $remoteMap $ledger
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $pulled = 0; $skipped = 0; $failures = 0; $dirty = $false
    $bootstrapCount = 0
    foreach ($r in $rows) {
        if ($r.state -eq "in-sync" -and -not $r.entry) {
            Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.remote_md5
            $bootstrapCount++
            $dirty = $true
            continue
        }
        if ($r.state -eq "conflict") {
            $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
            Write-Warn2 "  CONFLICT $label — skipped (sync or resolve decides conflicts)"
            $skipped++
            continue
        }
        if ($r.state -ne "pull" -and $r.state -ne "new-there") { continue }
        $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
        Write-Info "  pulling $label"
        try {
            $dest = Get-LocalSessionPath $r.project $r.id
            Copy-Down (ConvertTo-DriveUrl $cfg "projects/$($r.project)/$($r.id).jsonl") $dest
            Set-LedgerEntry $ledger $r.project $r.id $r.remote_md5 $r.remote_md5
            $pulled++; $dirty = $true
        } catch {
            Write-Warn2 "  [!]  pull failed for ${label}: $($_.Exception.Message)"
            $failures++
        }
    }
    if ($dirty) { Save-Ledger $ledger }
    Write-TransferSummary "pulled" $pulled $skipped $bootstrapCount $failures
    if ($failures -gt 0) { exit 1 }
}

function Invoke-Sync([string]$Project, [switch]$Interactive) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = @{}
    try { $remoteMap = Get-RemoteSessions $cfg } catch {
        Write-Warn2 "  [!]  remote unreachable ($($_.Exception.Message)) — nothing can sync"
        exit 1
    }
    $rows = Get-Classification $localMap $remoteMap $ledger
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $wantInteractive = $Interactive -or (Get-WantInteractive)
    $pushed = 0; $pulled = 0; $resolved = 0; $skipped = 0; $failures = 0
    $inSync = 0; $dirty = $false
    foreach ($r in $rows) {
        $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
        switch ($r.state) {
            "in-sync" {
                if (-not $r.entry) {
                    Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.remote_md5
                    $dirty = $true
                }
                $inSync++
            }
            "push" {
                Write-Info "  pushing $label"
                try {
                    Copy-Up $r.local.path (ConvertTo-DriveUrl $cfg "projects/$($r.project)/$($r.id).jsonl")
                    Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.local_md5
                    $pushed++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  push failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "pull" {
                Write-Info "  pulling $label"
                try {
                    $dest = Get-LocalSessionPath $r.project $r.id
                    Copy-Down (ConvertTo-DriveUrl $cfg "projects/$($r.project)/$($r.id).jsonl") $dest
                    Set-LedgerEntry $ledger $r.project $r.id $r.remote_md5 $r.remote_md5
                    $pulled++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  pull failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "new-here" {
                Write-Info "  pushing (new) $label"
                try {
                    Copy-Up $r.local.path (ConvertTo-DriveUrl $cfg "projects/$($r.project)/$($r.id).jsonl")
                    Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.local_md5
                    $pushed++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  push failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "new-there" {
                Write-Info "  pulling (new) $label"
                try {
                    $dest = Get-LocalSessionPath $r.project $r.id
                    Copy-Down (ConvertTo-DriveUrl $cfg "projects/$($r.project)/$($r.id).jsonl") $dest
                    Set-LedgerEntry $ledger $r.project $r.id $r.remote_md5 $r.remote_md5
                    $pulled++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  pull failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "conflict" {
                $choice = Resolve-ConflictRow $r $wantInteractive
                $outcome = Invoke-ApplyConflict $cfg $r $choice $ledger
                if ($outcome -eq "resolved") { $resolved++; $dirty = $true }
                else { $skipped++ }
            }
        }
    }
    if ($dirty) { Save-Ledger $ledger }
    $parts = @()
    if ($pushed -gt 0) { $parts += "pushed: $pushed" }
    if ($pulled -gt 0) { $parts += "pulled: $pulled" }
    if ($resolved -gt 0) { $parts += "resolved: $resolved" }
    if ($skipped -gt 0) { $parts += "skipped: $skipped" }
    $parts += "in-sync: $inSync"
    if ($failures -gt 0) { $parts += "FAILURES: $failures" }
    Write-Info ("  " + ($parts -join "   "))
    if ($failures -gt 0) { exit 1 }
}

# ------------------------------------------------- diff/resolve/revert/adopt

function Show-DiffRow($Row) {
    Write-Info ("session  {0}" -f $Row.id)
    Write-Info ("project  {0}" -f $Row.project)
    Write-Info ("state    {0}" -f (Format-State $Row.state))

    if ($Row.local) {
        $t = Read-Transcript $Row.local.path
        Write-Info ("  local  : {0}  {1}  {2} msgs  {3}" -f `
            (Get-HumanSize $Row.local.size), (Format-Time $Row.local.mtime), $t.messages, $t.last)
    } else {
        Write-Info "  local  : (absent)"
    }
    if ($Row.remote) {
        $tmp = Get-RemoteTranscript (Get-SessiumConfig) $Row.project $Row.id
        if ($tmp) {
            $t = Read-Transcript $tmp
            Remove-Item -LiteralPath $tmp -Force
            Write-Info ("  remote : {0}  {1}  {2} msgs  {3}" -f `
                (Get-HumanSize $Row.remote.size), (Format-Time $Row.remote.mtime), $t.messages, $t.last)
        } else {
            Write-Info ("  remote : {0}  {1}  (transcript unreadable)" -f `
                (Get-HumanSize $Row.remote.size), (Format-Time $Row.remote.mtime))
        }
    } else {
        Write-Info "  remote : (absent)"
    }

    if ($Row.entry) {
        Write-Info ("  ledger : last synced {0}; local md5 {1}; remote md5 {2}" -f `
            $Row.entry.last_synced, $Row.entry.local_md5.Substring(0, 12), $Row.entry.remote_md5.Substring(0, 12))
    } else {
        Write-Info "  ledger : no record yet"
    }
}

function Invoke-Diff([string]$Prefix, [string]$Project) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = @{}
    try { $remoteMap = Get-RemoteSessions $cfg } catch {
        Write-Warn2 "  [!]  remote unreachable — diffing against nothing on the remote side"
    }
    $rows = Get-Classification $localMap $remoteMap $ledger
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }
    $row = Find-OneSession $Prefix $rows
    Show-DiffRow $row
}

function Invoke-Resolve([string]$Prefix, [switch]$Interactive, [string]$Project) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $localMap = Get-LocalSessions
    $remoteMap = @{}
    try { $remoteMap = Get-RemoteSessions $cfg } catch {
        Write-Fail "remote unreachable ($($_.Exception.Message)) — nothing to resolve against"
    }
    $rows = Get-Classification $localMap $remoteMap $ledger
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }
    $row = Find-OneSession $Prefix $rows

    if ($row.state -ne "conflict") {
        Write-Info ("{0}/{1} is {2} — nothing to resolve" -f `
            $row.project, (Get-ShortId $row.id), $row.state)
        return
    }
    $wantInteractive = $Interactive -or (Get-WantInteractive)
    $choice = Resolve-ConflictRow $row $wantInteractive
    $outcome = Invoke-ApplyConflict $cfg $row $choice $ledger
    if ($outcome -ne "skipped") { Save-Ledger $ledger }
}

function Invoke-Revert([string]$Prefix) {
    $root = Join-Path (Get-ClaudeDir) "projects"
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Fail "no revert copies found (nothing at $root)"
    }
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($projDir in (Get-ChildItem -LiteralPath $root -Directory)) {
        $revDir = Join-Path $projDir.FullName "revert"
        if (-not (Test-Path -LiteralPath $revDir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $revDir -File -Filter "*.jsonl")) {
            if (-not $f.Name.StartsWith("$Prefix.revert-")) { continue }
            $sid = $f.Name.Substring(0, $f.Name.IndexOf(".revert-"))
            $found.Add(@{ project = $projDir.Name; sid = $sid; path = $f.FullName })
        }
    }
    if ($found.Count -eq 0) {
        Write-Fail "no revert copies found for sessions starting with '$Prefix'"
    }
    $byKey = @{}
    foreach ($f in $found) {
        $k = "{0}/{1}" -f $f.project, $f.sid
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = New-Object System.Collections.Generic.List[object] }
        $byKey[$k].Add($f)
    }
    if ($byKey.Keys.Count -gt 1) {
        Write-Info "ambiguous prefix — matches several sessions' revert copies:"
        foreach ($k in ($byKey.Keys | Sort-Object)) { Write-Info "    $k" }
        exit 1
    }
    $key = @($byKey.Keys)[0]
    $copies = @($byKey[$key] | Sort-Object -Property path)
    Write-Info "revert copies of $key :"
    for ($i = 0; $i -lt $copies.Count; $i++) {
        $fi = Get-Item -LiteralPath $copies[$i].path
        Write-Info ("  {0}.  {1}  {2}  {3}" -f ($i + 1), (Get-HumanSize $fi.Length),
            (Format-Time $fi.LastWriteTime), $fi.Name)
    }
    $answer = Read-Host "number to restore (or q to cancel)"
    $a = "$answer".Trim().ToLower()
    if ($a -eq "q" -or $a -eq "") { Write-Info "cancelled — nothing changed"; return }
    $n = 0
    if (-not [int]::TryParse($a, [ref]$n) -or $n -lt 1 -or $n -gt $copies.Count) {
        Write-Fail "'$answer' is not one of 1..$($copies.Count)"
    }
    $chosen = $copies[$n - 1]
    $parts = $key -split "/", 2
    $target = Get-LocalSessionPath $parts[0] $parts[1]
    if (Test-Path -LiteralPath $target) {
        Save-LocalRevert $parts[0] $parts[1] $target | Out-Null    # keep the current copy
    }
    Move-Item -LiteralPath $chosen.path -Destination $target
    $ledger = Get-Ledger
    if ($ledger.sessions.ContainsKey($key)) {
        $entry = $ledger.sessions[$key]
        Set-LedgerEntry $ledger $parts[0] $parts[1] (Get-FileMd5 $target) $entry.remote_md5
        Save-Ledger $ledger
    }
    Write-Info "  restored $(Split-Path -Leaf $chosen.path) -> $target"
    Write-Info "  next: 'sessium sync' pushes the restored copy to Drive"
}

function Invoke-Adopt([string]$Source, [string]$RepoPath) {
    $src = $Source
    $root = Join-Path (Get-ClaudeDir) "projects"
    $srcDir = Join-Path $root $src
    if (-not (Test-Path -LiteralPath $srcDir)) {
        Write-Info "no sessions folder '$src' under $root"
        Write-Info "available folders:"
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
            Write-Info "    $($d.Name)"
        }
        exit 1
    }
    $dest = ConvertTo-Munge $RepoPath
    if ($src -eq $dest) {
        Write-Info "nothing to do — '$src' already matches this machine's path for $RepoPath"
        return
    }
    $destDir = Join-Path $root $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $copied = 0; $already = 0; $kept = 0
    foreach ($item in (Get-ChildItem -LiteralPath $srcDir)) {
        $tgt = Join-Path $destDir $item.Name
        if ($item.PSIsContainer) {
            if ($item.Name -eq "revert") { continue }      # machine-local, never rehomed
            if (Test-Path -LiteralPath $tgt) {
                Write-Warn2 "  folder $($item.Name) already exists at destination — left as is"
                $kept++
                continue
            }
            Copy-Item -LiteralPath $item.FullName -Destination $tgt -Recurse
            $copied++
        } else {
            if (Test-Path -LiteralPath $tgt) {
                $a = Get-FileMd5 $item.FullName
                $b = Get-FileMd5 $tgt
                if ($a -eq $b) { $already++; continue }
                Write-Warn2 "  file $($item.Name) differs at destination — kept both (yours untouched)"
                $kept++
                continue
            }
            Copy-Item -LiteralPath $item.FullName -Destination $tgt
            $copied++
        }
    }
    Write-Info ""
    Write-Info ("adopted {0} -> {1}:  {2} copied, {3} already present, {4} kept as is" -f `
        $src, $dest, $copied, $already, $kept)
    Write-Info "next:  cd $RepoPath; claude --resume"
}

# ---------------------------------------------------------------- setup

function Invoke-Setup([string[]]$Passthrough) {
    $script = Join-Path $PSScriptRoot "setup-windows.ps1"
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Fail "setup-windows.ps1 not found next to sessium.ps1"
    }
    & $script @Passthrough
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- dispatch

function Show-Usage {
    Write-Info @"
sessium $script:Version - git for Claude Code sessions (Drive remote)

usage: sessium <command> [args]

  list [--titles] [--project <munged>]     browse sessions, newest first
  status [--project <munged>]              what changed here / there / conflicted
  check                                    connectivity + config + ledger self-test
  setup [--check-only]                     run setup-windows.ps1 (first-time Drive setup)
  push [--project <munged>]                upload new/changed sessions (skips conflicts)
  pull [--project <munged>]                download new/changed sessions (skips conflicts)
  sync [--interactive] [--project <m>]     push AND pull; decides conflicts
  diff <id>                                local vs remote vs last-synced, side by side
  resolve <id>                             decide a conflicted session by hand
  revert <id>                              swap a kept revert copy back in
  adopt <munged-folder> <repo-path>        rehome sessions to this machine's path

session ids: a prefix is enough ('sessium diff 9f8e'). Munged project names
always start with '-' (e.g. -C--Users-me-repo) - fine after --project.

--debug prints every rclone call. Exit codes: 0 ok (skips are not failures),
1 real failures. (Ctrl+C exits via the PowerShell console itself.)
"@
}

function Invoke-Main([string[]]$CliArgs) {
    # munged names start with '-'; manual parsing takes them as values as-is
    $positional = New-Object System.Collections.Generic.List[string]
    $opt = @{ project = ""; titles = $false; interactive = $false }
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $a = $CliArgs[$i]
        if ($a -eq "--debug") { $script:Debug = $true; $i++; continue }
        if ($a -eq "--titles") { $opt.titles = $true; $i++; continue }
        if ($a -eq "--interactive") { $opt.interactive = $true; $i++; continue }
        if ($a -like "--project=*") { $opt.project = $a.Substring(10); $i++; continue }
        if ($a -eq "--project" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.project = $CliArgs[$i + 1]; $i += 2; continue
        }
        $positional.Add($a); $i++
    }
    $cmd = ""
    if ($positional.Count -gt 0) { $cmd = $positional[0]; $positional.RemoveAt(0) }

    switch ($cmd) {
        "list"     { Invoke-ListSessions $opt.project -Titles:$opt.titles; return 0 }
        "status"   { Invoke-Status $opt.project; return 0 }
        "check"    { Invoke-Check; return 0 }
        "setup"    { Invoke-Setup @($positional); return 0 }
        "push"     { Invoke-Push $opt.project; return 0 }
        "pull"     { Invoke-Pull $opt.project; return 0 }
        "sync"     { Invoke-Sync $opt.project -Interactive:$opt.interactive; return 0 }
        "diff" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium diff <id>  (prefix ok)" }
            Invoke-Diff $positional[0] $opt.project; return 0
        }
        "resolve" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium resolve <id>  (prefix ok)" }
            Invoke-Resolve $positional[0] -Interactive:$opt.interactive -Project $opt.project
            return 0
        }
        "revert" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium revert <id>  (prefix ok)" }
            Invoke-Revert $positional[0]; return 0
        }
        "adopt" {
            if ($positional.Count -lt 2) {
                Write-Fail "usage: sessium adopt <munged-folder> <repo-path>"
            }
            Invoke-Adopt $positional[0] $positional[1]; return 0
        }
        "-h" { Show-Usage; return 0 }
        "--help" { Show-Usage; return 0 }
        "help" { Show-Usage; return 0 }
        default {
            if ($cmd) { Write-Warn2 "unknown command: '$cmd'" }
            Show-Usage
            return 1
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    exit (Invoke-Main $args)
}
