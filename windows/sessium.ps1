# sessium (Windows) - git-like version control for Claude Code sessions,
# with Google Drive (via rclone) as the remote.
#
# Native PowerShell 5.1+ port of linux/sessium. Reads and writes the same
# Drive data and the same ledger format; SPEC.md is the contract between
# the two versions and wins on any disagreement.
#
# Surface so far (SPEC section 7): list, status, check (+ --full), setup, push,
# pull, sync (+ --only), diff (+ --messages), resolve, revert, adopt + Batch 3
# foundations: version, log, open, --json, --dry-run, --quiet, transfer
# lockfile + Batch 4: search, seek, checkout, gc, history snapshots.
#
# Usage: powershell -ExecutionPolicy Bypass -File sessium.ps1 <command> [args]
#        (sessium.cmd on your PATH wraps this; install.ps1 installs both)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:Debug = $false
$script:Quiet = $false
$script:Version = "0.1.0"
$script:NoisePrefixes = @("<command-", "<local-command", "<ide_")

# ---------------------------------------------------------------- utilities

function Write-Dbg([string]$Msg) {
    if ($script:Debug) { Write-Host "  [debug] $Msg" -ForegroundColor DarkGray }
}

function Write-Info([string]$Msg) {
    if (-not $script:Quiet) { Write-Host $Msg }
}

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
function ConvertFrom-RcloneTime($Value) {
    if ($null -eq $Value) { return $null }
    # pwsh's ConvertFrom-Json coerces ISO-8601 strings to DateTime BEFORE we
    # see them (lsjson ModTime arrives as [DateTime]) — accept both, and
    # never round-trip through [string], which lands in en-US culture format
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    # keep the DOT: the match includes it, and a bare '$1' replacement glues
    # the fraction onto the seconds ("161234567") which fails to parse —
    # remote mtimes all came back null and newest-wins had nothing to compare
    $trimmed = [regex]::Replace($Value, '\.(\d{7})\d+', '.$1')
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

# ---------------------------------------------------------------- json (SPEC 9)

<# JSON string escaping identical to Python's json.dumps default
   (ensure_ascii): control chars, quote, backslash; every char > 0x7E
   becomes \uXXXX. .NET strings are UTF-16, so astral chars arrive as
   surrogate pairs and each half is escaped on its own - same bytes out. #>
function ConvertTo-JsonString([string]$S) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $S.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 0x20 -or $code -gt 0x7E) {
            [void]$sb.Append(('\u{0:x4}' -f $code))
        } else {
            switch ($code) {
                0x22 { [void]$sb.Append('\"') }
                0x5C { [void]$sb.Append('\\') }
                0x08 { [void]$sb.Append('\b') }
                0x0C { [void]$sb.Append('\f') }
                0x0A { [void]$sb.Append('\n') }
                0x0D { [void]$sb.Append('\r') }
                0x09 { [void]$sb.Append('\t') }
                default { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

<# Serialize one already-shaped value at a given indent level. Hashtables
   (keys sorted ordinal), arrays, strings, bools, ints, $null. Output is
   byte-identical to Python json.dumps(data, indent=2, sort_keys=True). #>
function ConvertTo-JsonText($Value, [int]$Indent) {
    $pad = " " * $Indent
    $padIn = " " * ($Indent + 2)
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { if ($Value) { return "true" } else { return "false" } }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [Int64]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([double]$Value).ToString("R", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        # List.Add, NOT "$items += $item": array += with an ARRAY on the right
        # concatenates element-wise and flattens nested arrays (a pair
        # ["user","text"] would dissolve into the outer list). Add keeps each
        # element intact, so nested arrays serialize nested. Also dodges pwsh
        # 7.4's @(<List[object]>) DLR crash under StrictMode.
        $lines = New-Object System.Collections.Generic.List[string]
        $count = 0
        foreach ($item in $Value) {
            $count++
            $lines.Add($padIn + (ConvertTo-JsonText $item ($Indent + 2)))
        }
        if ($count -eq 0) { return "[]" }
        return "[`n" + ($lines.ToArray() -join ",`n") + "`n$pad]"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return "{}" }
        $keys = @($Value.Keys | Sort-Object)
        $lines = @()
        foreach ($k in $keys) {
            $lines += ($padIn + (ConvertTo-JsonString "$k") + ": " +
                (ConvertTo-JsonText $Value[$k] ($Indent + 2)))
        }
        return "{`n" + ($lines -join ",`n") + "`n$pad}"
    }
    return (ConvertTo-JsonString "$Value")
}

<# Print ONE JSON document on stdout - indent 2, keys sorted, nothing else
   (chatter stays on stderr). SPEC section 9. #>
function Emit-Json($Data) {
    Write-Host (ConvertTo-JsonText $Data 0)
}

<# mtime for --json rows: UTC "yyyy-MM-ddTHH:mm:ssZ" or $null. Accepts a
   DateTime (local or UTC) or an epoch-seconds number. #>
function Get-IsoTime($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            $Value = [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime().ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    try {
        $epoch = [long]$Value
        $dt = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds($epoch)
        return $dt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------- config

function Get-ClaudeDir {
    if ($env:SESSIUM_CLAUDE_DIR) { return $env:SESSIUM_CLAUDE_DIR }
    return (Join-Path $env:USERPROFILE ".claude")
}

<# The CLI's data root per app: ~/.claude for Claude Code, ~/.codex for Codex
   (SESSIUM_CODEX_HOME overrides, for hermetic tests). #>
function Get-AppHome([string]$App) {
    if ($App -eq "codex") {
        if ($env:SESSIUM_CODEX_HOME) { return $env:SESSIUM_CODEX_HOME }
        return (Join-Path $env:USERPROFILE ".codex")
    }
    return (Get-ClaudeDir)
}

<# Apps a command operates on: --app claude|codex, default both. An unknown
   value is a hard error (the Linux side rejects it in argparse). #>
function Get-SelectedApps([string]$App) {
    if (-not $App -or $App -eq "all") { return @("claude", "codex") }
    if ($App -eq "claude" -or $App -eq "codex") { return @($App) }
    Write-Fail "unknown --app '$App' — use claude, codex, or all"
    return @("claude", "codex")     # unreachable; Write-Fail exits 1
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
    $cfg = @{ Remote = "gdrive"; Folder = "claude-backup"; SeekerUrl = ""; SeekerToken = "" }
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $remote = Get-JsonProp $raw "rclone_remote"
            $folder = Get-JsonProp $raw "drive_folder"
            $seekerUrl = Get-JsonProp $raw "seeker_url"
            $seekerToken = Get-JsonProp $raw "seeker_token"
            # null-guard, not truthiness: setup --encrypted writes
            # drive_folder as "" (crypt root == the old folder), and a truthy
            # check silently reverted that to the default - every push then
            # forked into <crypt>:claude-backup/ instead of the crypt root
            if ($null -ne $remote) { $cfg.Remote = [string]$remote }
            if ($null -ne $folder) { $cfg.Folder = [string]$folder }
            if ($null -ne $seekerUrl) { $cfg.SeekerUrl = [string]$seekerUrl }
            if ($null -ne $seekerToken) { $cfg.SeekerToken = [string]$seekerToken }
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

<# rclone exit codes worth another attempt: 5 = transient retry error,
   6 = retries exhausted, 8 = transfers exhausted. Not-found (2/3/4) and
   fatal (7) are permanent - retrying those just burns time. Timeouts are
   treated as transient too (a slow link is not a broken one). #>
$script:TransientRcs = @(5, 6, 8)
$script:CopyRetries = 2

# File-transfer timeout: the old fixed 300s killed healthy uploads of big
# transcripts on slow uplinks. Scale the ceiling with the file size - 10 s/MB
# assumes a ~100 KB/s sustained rate, and never go below the 300s base.
# SESSIUM_COPY_TIMEOUT overrides with a fixed value.
$script:CopyTimeoutBase = 300
$script:CopyTimeoutPerMb = 10.0

function Get-CopyTimeout([long]$SizeBytes) {
    $override = $env:SESSIUM_COPY_TIMEOUT
    if ($override -and $override -match '^\d+$') { return [int]$override }
    $size = 0
    if ($SizeBytes -gt 0) { $size = $SizeBytes }
    return [Math]::Max($script:CopyTimeoutBase,
        [int][Math]::Floor($script:CopyTimeoutPerMb * ($size / 1MB)))
}

# Plain thrown exceptions carry no Transient flag, and StrictMode 2 forbids
# reading a property that may not exist - go through PSObject.Properties.
function Test-TransientError($Exception) {
    $p = $Exception.PSObject.Properties["Transient"]
    return ($null -ne $p -and [bool]$p.Value)
}

<# rclone copyto/copy with a size-aware timeout and bounded retries.
   Transfers are idempotent (copyto/copy overwrite whole files), so a blind
   re-attempt is safe; permanent errors still fail on the first attempt.
   SESSIUM_RETRY_DELAY_SCALE collapses the 2s/4s backoff (test suite). #>
function Invoke-CopyWithRetry {
    param([string[]]$RcloneArgs, [long]$SizeBytes = 0, [string]$ToFile)
    $timeout = Get-CopyTimeout $SizeBytes
    $scale = 1.0
    if ($env:SESSIUM_RETRY_DELAY_SCALE -and $env:SESSIUM_RETRY_DELAY_SCALE -match '^\d+(\.\d+)?$') {
        $scale = [double]$env:SESSIUM_RETRY_DELAY_SCALE
    }
    for ($n = 1; $n -le $script:CopyRetries + 1; $n++) {
        try {
            if ($ToFile) {
                $null = Invoke-Rclone -RcloneArgs $RcloneArgs -TimeoutSec $timeout -ToFile $ToFile
            } else {
                $null = Invoke-Rclone -RcloneArgs $RcloneArgs -TimeoutSec $timeout
            }
            return
        } catch {
            if (-not (Test-TransientError $_.Exception) -or $n -gt $script:CopyRetries) { throw }
            $delay = [int](2 * $n * $scale)
            Write-Warn2 "  [!]  retry $n/$($script:CopyRetries) in ${delay}s: $($_.Exception.Message)"
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
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
        $ex = New-Object System.Exception "rclone $($RcloneArgs[0]) timed out after ${TimeoutSec}s"
        Add-Member -InputObject $ex -NotePropertyName Transient -NotePropertyValue $true
        throw $ex
    }
    $err = $errTask.Result.Trim()
    if ($proc.ExitCode -ne 0) {
        $ex = New-Object System.Exception "rclone $($RcloneArgs -join ' ') failed (rc=$($proc.ExitCode))$(
            if ($err) { ": $err" })"
        Add-Member -InputObject $ex -NotePropertyName Transient `
            -NotePropertyValue ($script:TransientRcs -contains $proc.ExitCode)
        throw $ex
    }
    if ($ToFile) {
        [System.IO.File]::WriteAllText($ToFile, $outTask.Result, [System.Text.Encoding]::UTF8)
        return   # plain return, NOT "return $null": an emitted $null joins
                 # the CALLER's output stream (Get-RemoteTranscript's $tmp
                 # became @($null, path) and Remove-Item -LiteralPath died
                 # binding the null element)
    }
    if ($Quiet) { return }
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

<# Ledger key. Claude keeps the original '<munged>/<sid>' shape (existing
   ledgers stay valid, no migration); codex sessions are namespaced under
   'codex/' so the two apps can never collide on one key (SPEC section 3). #>
function Get-LedgerKey([string]$Project, [string]$Sid, [string]$App) {
    if ($App -eq "codex") { return "codex/$Project/$Sid" }
    return "$Project/$Sid"
}

<# pwsh's ConvertFrom-Json coerces ISO-8601 strings to DateTime, and the
   ledger's last_synced must round-trip as the exact string sessium wrote
   ("yyyy-MM-ddTHH:mm:ssZ") — a [string] cast of the coerced DateTime lands
   in en-US culture ("11/07/2026 22:34:39") and would corrupt the file on
   the next save. Re-format DateTimes back to the canonical form. #>
function ConvertTo-IsoZ($Value) {
    if ($null -eq $Value) { return "" }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

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
                    last_synced = (ConvertTo-IsoZ (Get-JsonProp $v "last_synced"))
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
                         [string]$LocalMd5, [string]$RemoteMd5, [string]$App) {
    $Ledger.sessions[(Get-LedgerKey $Project $Sid $App)] = @{
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

<# (session_id, cwd) from a rollout's first line (type session_meta).
   Returns $null when the file is unreadable or not a recognized rollout.
   Read only the first line - rollouts can be tens of MB. #>
function Get-CodexMeta([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 65536
            $n = $fs.Read($buf, 0, $buf.Length)
            if ($n -le 0) { return $null }
            $first = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            $nl = $first.IndexOf("`n")
            if ($nl -ge 0) { $first = $first.Substring(0, $nl) }
        } finally {
            $fs.Close()
        }
    } catch {
        return $null
    }
    try { $entry = $first | ConvertFrom-Json } catch { return $null }
    if ((Get-JsonProp $entry "type") -ne "session_meta") { return $null }
    $payload = Get-JsonProp $entry "payload"
    return @{
        sid = [string](Get-JsonProp $payload "session_id")
        cwd = [string](Get-JsonProp $payload "cwd")
    }
}

<# Best-effort title for a codex rollout: the first user message that isn't
   one of codex's <wrapper> blocks (environment context etc.). Same scan
   limits as Get-SessionTitle. #>
function Get-CodexTitle([string]$Path, [int]$MaxLines = 400) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($n -ge $MaxLines) { break }
        $n++
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ((Get-JsonProp $obj "type") -ne "response_item") { continue }
        $payload = Get-JsonProp $obj "payload"
        if (-not $payload -or (Get-JsonProp $payload "role") -ne "user") { continue }
        $parts = @()
        $content = Get-JsonProp $payload "content"
        foreach ($block in @($content)) {
            if (-not $block) { continue }
            $type = [string](Get-JsonProp $block "type")
            if ($type.EndsWith("_text") -and (Get-JsonProp $block "text")) {
                $parts += [string](Get-JsonProp $block "text")
            }
        }
        $text = (($parts -join " ").Trim())
        if ($text -and -not $text.StartsWith("<")) { return $text }
    }
    return ""
}

<# Where a codex session lives locally: an existing rollout whose name ends
   in the uuid (any date folder), or a synthesized
   sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl for downloads. -Mtime (UTC
   DateTime or $null) feeds the synthesized name; it is rendered LOCAL (the
   same date folder codex itself would have created on this box). #>
function Get-CodexLocalPath([string]$Sid, $Mtime) {
    $root = Join-Path (Get-AppHome "codex") "sessions"
    if (Test-Path -LiteralPath $root) {
        foreach ($f in (Get-ChildItem -LiteralPath $root -File -Filter "*.jsonl" -Recurse | Sort-Object FullName)) {
            if ($f.BaseName.EndsWith("-$Sid") -or $f.BaseName -eq $Sid) { return $f.FullName }
        }
    }
    $stamp = $null
    if ($Mtime) { $stamp = $Mtime }
    if (-not $stamp) { $stamp = (Get-Date) }
    $local = $stamp
    if ($stamp -is [DateTime]) {
        if ($stamp.Kind -eq [System.DateTimeKind]::Utc) { $local = $stamp.ToLocalTime() }
    } else {
        try { $local = [DateTime]$stamp } catch { $local = (Get-Date) }
    }
    $name = "rollout-{0}-{1}.jsonl" -f $local.ToString("yyyy-MM-ddTHH-mm-ss"), $Sid
    return (Join-Path (Join-Path (Join-Path (Join-Path $root `
        ("{0:D4}" -f $local.Year)) ("{0:D2}" -f $local.Month)) ("{0:D2}" -f $local.Day)) $name)
}

<# Discover local sessions: @{ "<munged>" = @( @{ id, path, size, mtime, md5 } ) }
   mtime is a UTC DateTime (LastWriteTimeUtc). md5 matches Linux's
   local_sessions(), which hashes every transcript on every scan. Codex
   rows come from <codex-home>/sessions/** rollouts; the project name is
   munged from each rollout's session_meta cwd (SPEC §2). #>
function Get-LocalSessions([string]$App) {
    $root = Join-Path (Get-AppHome $App) "projects"
    if ($App -eq "codex") { $root = Join-Path (Get-AppHome "codex") "sessions" }
    $map = @{}
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    if ($App -eq "codex") {
        $rowsByProj = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $root -File -Filter "*.jsonl" -Recurse |
                         Sort-Object FullName)) {
            $meta = Get-CodexMeta $f.FullName
            if (-not $meta -or -not $meta.sid) { continue }
            $proj = ConvertTo-Munge $meta.cwd
            if (-not $proj) { $proj = "-unknown-cwd" }
            $row = @{
                id = $meta.sid
                path = $f.FullName
                size = $f.Length
                mtime = $f.LastWriteTimeUtc
                md5 = (Get-FileMd5 $f.FullName)
            }
            if (-not $rowsByProj.ContainsKey($proj)) {
                $rowsByProj[$proj] = New-Object System.Collections.Generic.List[object]
            }
            $rowsByProj[$proj].Add($row)
        }
        foreach ($k in @($rowsByProj.Keys | Sort-Object)) {
            # object[], not List[object]: pwsh 7.4 throws "Argument types do
            # not match" for @(<List[object]>) under StrictMode (see below);
            # Sort-Object already materializes to object[]
            $map[$k] = @(($rowsByProj[$k].ToArray() | Sort-Object { $_.id }))
        }
        return $map
    }
    foreach ($projDir in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($f in (Get-ChildItem -LiteralPath $projDir.FullName -File -Filter "*.jsonl" |
                         Sort-Object Name)) {
            $rows.Add(@{
                id = $f.BaseName
                path = $f.FullName
                size = $f.Length
                mtime = $f.LastWriteTimeUtc
                md5 = (Get-FileMd5 $f.FullName)
            })
        }
        # object[], not List[object]: pwsh 7.4 throws "Argument types do not
        # match" for @(<List[object]>) under StrictMode, and callers wrap
        # these map values in @() (Get-Classification, sync, json status)
        $map[$projDir.Name] = $rows.ToArray()
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
function Get-RemoteTranscript($Cfg, [string]$Project, [string]$Sid, [string]$App) {
    # real ids are 32+ hex chars; the smoke's fake ones can be shorter
    $keep = if ($Sid.Length -gt 8) { $Sid.Substring(0, 8) } else { $Sid }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sessium-" + $keep + ".jsonl")
    try {
        # $null = : discard output so nothing extra joins this function's
        # return stream beside the temp path
        $null = Invoke-CopyWithRetry -RcloneArgs @("cat", (ConvertTo-DriveUrl $Cfg "$(Get-RemoteBase $App)/$Project/$Sid.jsonl")) `
            -ToFile $tmp
        return $tmp
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $null
    }
}

function Test-NoiseText([string]$Text) {
    foreach ($p in $script:NoisePrefixes) {
        if ($Text.StartsWith($p)) { return $true }
    }
    return $false
}

<# The conversation as (role, text) pairs — non-meta user/assistant lines,
   command/ide wrappers excluded. This is what --messages diffs and what
   search scans. #>
function Get-TranscriptMessages([string]$Path) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $t = Get-JsonProp $obj "type"
        if ($t -ne "user" -and $t -ne "assistant") { continue }
        if (Get-JsonProp $obj "isMeta") { continue }
        $msg = Get-JsonProp $obj "message"
        if (-not $msg) { continue }
        $text = (Get-MessageText $msg.content).Trim()
        if (-not $text -or (Test-NoiseText $text)) { continue }
        $norm = (($text -split "\s+") | Where-Object { $_ }) -join " "
        $out.Add(@{ role = $t; text = $norm })
    }
    # object[], not the List: @() around a List[object] hits pwsh 7.4's
    # "Argument types do not match" DLR crash under strict mode (the same
    # bug the status rows hit), and diff --messages wraps these in @()
    return ,$out.ToArray()
}

<# Transcripts are append-mostly: the common prefix IS the last-synced
   content. Report what each side added past it. #>
function Get-MessageDivergence($LocalMsgs, $RemoteMsgs) {
    $common = 0
    $n = [Math]::Min(@($LocalMsgs).Count, @($RemoteMsgs).Count)
    while ($common -lt $n) {
        if (@($LocalMsgs)[$common].role -ne @($RemoteMsgs)[$common].role -or
            @($LocalMsgs)[$common].text -ne @($RemoteMsgs)[$common].text) { break }
        $common++
    }
    $localAdded = @(); if ($common -lt @($LocalMsgs).Count) { $localAdded = @($LocalMsgs)[$common..(@($LocalMsgs).Count - 1)] }
    $remoteAdded = @(); if ($common -lt @($RemoteMsgs).Count) { $remoteAdded = @($RemoteMsgs)[$common..(@($RemoteMsgs).Count - 1)] }
    return @{ common = $common; local_added = @($localAdded); remote_added = @($remoteAdded) }
}

<# Remote sessions via one recursive lsjson: @{ "<munged>" = @( @{ id, size,
   mtime (UTC DateTime), md5 } ) }. Only top-level .jsonl per project. Codex
   sessions live under the separate codex/projects tree (SPEC §1). #>
function Get-RemoteSessions($Cfg, [string]$App) {
    $map = @{}
    $base = "projects"
    if ($App -eq "codex") { $base = "codex/projects" }
    $url = ConvertTo-DriveUrl $Cfg $base
    $text = $null
    try {
        $text = Invoke-Rclone -RcloneArgs @("lsjson", "--recursive", "--hash", $url)
    } catch {
        # a fresh remote has no projects/ folder yet — that is "empty", not
        # "unreachable" (push creates the folder chain on its first upload)
        if ("$($_.Exception.Message)" -match "directory not found") { return $map }
        throw
    }
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
    # object[], not List[object]: pwsh 7.4 throws "Argument types do not
    # match" for @(<List[object]>) under StrictMode, and callers wrap these
    # map values in @() (Get-Classification, sync, json status). New map, not
    # in-place: replacing values while enumerating Keys trips Hashtable's
    # version check ("Collection was modified").
    $out = @{}
    foreach ($k in $map.Keys) { $out[$k] = $map[$k].ToArray() }
    return $out
}

# ------------------------------------------------------- classification

<# The SPEC section 4 state machine. Compare the CURRENT md5s against the
   ledger record. Never line-merges, never deletes: one side missing with a
   ledger entry means the other side gets re-uploaded / re-downloaded. #>
function Get-ClassificationRow([string]$App, [string]$Project, [string]$Sid, $Local, $Remote, $Entry) {
    $row = @{
        app = $App
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

function Get-Classification([string]$App, $LocalMap, $RemoteMap, $Ledger) {
    $rows = New-Object System.Collections.Generic.List[object]
    $projects = @($LocalMap.Keys + $RemoteMap.Keys | Sort-Object -Unique)
    foreach ($proj in $projects) {
        $locals = @(); if ($LocalMap.ContainsKey($proj)) { $locals = @($LocalMap[$proj]) }
        $remotes = @(); if ($RemoteMap.ContainsKey($proj)) { $remotes = @($RemoteMap[$proj]) }
        # concat the ARRAYS first: piping each side separately unwraps a
        # single-item pipeline to a scalar, and "aaa" + "aaa" string-concats
        # into a bogus id
        $ids = @(($locals + $remotes) | ForEach-Object { $_.id } | Sort-Object -Unique)
        foreach ($sid in $ids) {
            $local = $null; foreach ($l in $locals) { if ($l.id -eq $sid) { $local = $l; break } }
            $remote = $null; foreach ($r in $remotes) { if ($r.id -eq $sid) { $remote = $r; break } }
            $entry = $null
            $key = Get-LedgerKey $proj $sid $App
            if ($Ledger.sessions.ContainsKey($key)) { $entry = $Ledger.sessions[$key] }
            $rows.Add((Get-ClassificationRow $App $proj $sid $local $remote $entry))
        }
    }
    # leading comma: a single-row List unrolls to a SCALAR on return, and a
    # caller's $rows.Count then reads the row's key count (8) instead of 1
    return ,$rows
}

<# Classify every session across the selected apps (SPEC §7 --app). One row
   per session, stamped with its owning app — the two apps' project
   namespaces never merge, since a munged Claude path and a munged codex cwd
   can collide while their ledger keys cannot. Returns @{ rows; reachable }:
   reachable=$false means an app classified against a local-only view.
   $Hard rethrows a Drive listing failure instead (push/pull/diff/resolve
   keep their fail-loud contract). #>
function Get-CollectRows($Cfg, [string]$App, $Ledger, [bool]$Hard) {
    $rows = New-Object System.Collections.Generic.List[object]
    $reachable = $true
    foreach ($app in (Get-SelectedApps $App)) {
        $localMap = Get-LocalSessions $app
        $remoteMap = $null
        try {
            $remoteMap = Get-RemoteSessions $Cfg $app
        } catch {
            if ($Hard) { throw }
            $remoteMap = @{}
            $reachable = $false
        }
        foreach ($r in (Get-Classification $app $localMap $remoteMap $Ledger)) {
            $rows.Add($r)
        }
    }
    return @{ rows = $rows; reachable = $reachable }
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
            Write-Info ("    {0}  {1,-6}  {2}/{3}" -f (Get-ShortId $m.id), $m.app, $m.project, $m.id)
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

<# Where an app's session tree lives locally (also the quarantine root for
   revert/history copies — for codex that is OUTSIDE sessions/, because
   codex globs sessions/**/*.jsonl and would see quarantined copies as
   duplicate sessions; SPEC §6). #>
function Get-LocalRoot([string]$App) {
    if ($App -eq "codex") { return (Join-Path (Get-AppHome "codex") ".sessium\projects") }
    return (Join-Path (Get-ClaudeDir) "projects")
}

<# Remote tree for an app's transcripts (SPEC §1: codex lives separately). #>
function Get-RemoteBase([string]$App) {
    if ($App -eq "codex") { return "codex/projects" }
    return "projects"
}

function Get-LocalSessionPath([string]$Project, [string]$Sid, [string]$App, $Mtime) {
    if ($App -eq "codex") { return (Get-CodexLocalPath $Sid $Mtime) }
    return (Join-Path (Join-Path (Get-LocalRoot $App) $Project) "$Sid.jsonl")
}

function Copy-Up([string]$LocalPath, [string]$RemoteUrl) {
    $size = 0
    if (Test-Path -LiteralPath $LocalPath) { $size = (Get-Item -LiteralPath $LocalPath).Length }
    Invoke-CopyWithRetry -RcloneArgs @("copyto", $LocalPath, $RemoteUrl) -SizeBytes $size
}

function Copy-Down([string]$RemoteUrl, [string]$LocalPath) {
    $dir = Split-Path -Parent $LocalPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # size unknown without an extra lsjson round-trip - base timeout + retries
    Invoke-CopyWithRetry -RcloneArgs @("copyto", $RemoteUrl, $LocalPath)
}

<# Unique revert-copy path: <local-root>/revert/<sid>.revert-<yyyyMMdd-HHmmss>.jsonl,
   sub-second collisions get a -N before .jsonl (SPEC section 6). #>
function Get-RevertPath([string]$Project, [string]$Sid, [string]$App) {
    $dir = Join-Path (Join-Path (Get-LocalRoot $App) $Project) "revert"
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
function Save-LocalRevert([string]$Project, [string]$Sid, [string]$Src, [string]$App) {
    $dst = Get-RevertPath $Project $Sid $App
    Move-Item -LiteralPath $Src -Destination $dst -Force
    Write-Info "         local copy kept as $(Split-Path -Leaf $dst)"
    return $dst
}

# A losing REMOTE copy is downloaded into revert/ before anything overwrites it.
function Save-RemoteRevert($Cfg, [string]$Project, [string]$Sid, [string]$App) {
    $dst = Get-RevertPath $Project $Sid $App
    Copy-Down (ConvertTo-DriveUrl $Cfg "$(Get-RemoteBase $App)/$Project/$Sid.jsonl") $dst
    Write-Info "         remote copy kept as $(Split-Path -Leaf $dst)"
    return $dst
}

# ------------------------------------------------- history (SPEC section 10)

<# Content-addressed snapshot of a copy that is about to be (or was just)
   replaced: history/<seq>-<md5[:8]>.jsonl. Identical content lands under an
   identical name - the second save is a free dedup no-op. Never touches the
   ledger. Returns the new snapshot path, or $null when it already existed. #>
function Save-HistorySnapshot([string]$Project, [string]$Sid, [string]$Src, [string]$App) {
    if (-not (Test-Path -LiteralPath $Src)) { return $null }
    $digest = Get-FileMd5 $Src
    if (-not $digest) { return $null }
    $hDir = Join-Path (Join-Path (Join-Path (Get-LocalRoot $App) $Project) $Sid) "history"
    if (-not (Test-Path -LiteralPath $hDir)) {
        New-Item -ItemType Directory -Path $hDir -Force | Out-Null
    }
    $suffix = "-$($digest.Substring(0, 8)).jsonl"
    $existing = @(Get-ChildItem -LiteralPath $hDir -File -Filter "*.jsonl")
    foreach ($f in $existing) {
        if ($f.Name.EndsWith($suffix)) { return $null }   # these bytes are kept
    }
    $seq = $existing.Count + 1
    $dst = Join-Path $hDir ("{0:D4}-{1}.jsonl" -f $seq, $digest.Substring(0, 8))
    Copy-Item -LiteralPath $Src -Destination $dst -Force   # the source lives in revert/
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
<# What apply-conflict's newest-wins default would do — for --dry-run,
   which shows the decision it would make without making it. #>
function Describe-Conflict($Row) {
    $rt = $null; if ($Row.remote) { $rt = $Row.remote.mtime }
    $lt = $null; if ($Row.local) { $lt = $Row.local.mtime }
    if ($null -ne $rt -and ($null -eq $lt -or $rt -gt $lt)) {
        return "remote wins (newer; local kept as revert)"
    }
    return "local wins (newer; remote kept as revert)"
}

function Invoke-ApplyConflict($Cfg, $Row, [string]$Choice, $Ledger) {
    $app = "$($Row.app)"
    $localPath = $Row.local.path
    $remoteUrl = ConvertTo-DriveUrl $Cfg "$(Get-RemoteBase $app)/$($Row.project)/$($Row.id).jsonl"

    if ($Choice -eq "skip") {
        Write-Warn2 "  skipped (still conflicted)"
        return "skipped"
    }

    if ($Choice -eq "local") {
        if ($Row.remote) {
            $kept = Save-RemoteRevert $Cfg $Row.project $Row.id $app
            Save-HistorySnapshot $Row.project $Row.id $kept $app | Out-Null
            Copy-Up $localPath $remoteUrl
        } else {
            Copy-Up $localPath $remoteUrl
        }
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.local_md5 $Row.local_md5 $app
        Write-Info "  ->  local wins, uploaded"
        return "resolved"
    }

    if ($Choice -eq "remote") {
        if ($Row.local) {
            $saved = Save-LocalRevert $Row.project $Row.id $localPath $app
            Save-HistorySnapshot $Row.project $Row.id $saved $app | Out-Null
        }
        $tmpLocal = Get-LocalSessionPath $Row.project $Row.id $app $Row.remote.mtime
        Copy-Down $remoteUrl $tmpLocal
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.remote_md5 $Row.remote_md5 $app
        Write-Info "  ->  remote wins, downloaded"
        return "resolved"
    }

    # "auto": newest wins, tie goes to local
    $useLocal = ($null -eq $Row.remote.mtime) -or
                ($Row.local.mtime -ge $Row.remote.mtime)
    if ($useLocal) {
        if ($Row.remote) {
            $kept = Save-RemoteRevert $Cfg $Row.project $Row.id $app
            Save-HistorySnapshot $Row.project $Row.id $kept $app | Out-Null
        }
        Copy-Up $localPath $remoteUrl
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.local_md5 $Row.local_md5 $app
        Write-Info ("  ->  local wins (newer: {0}), uploaded" -f (Format-Time $Row.local.mtime))
    } else {
        if ($Row.local) {
            $saved = Save-LocalRevert $Row.project $Row.id $localPath $app
            Save-HistorySnapshot $Row.project $Row.id $saved $app | Out-Null
        }
        Copy-Down $remoteUrl (Get-LocalSessionPath $Row.project $Row.id $app $Row.remote.mtime)
        Set-LedgerEntry $Ledger $Row.project $Row.id $Row.remote_md5 $Row.remote_md5 $app
        Write-Info ("  ->  remote wins (newer: {0}), downloaded" -f (Format-Time $Row.remote.mtime))
    }
    return "resolved"
}

# ---------------------------------------------------------------- commands

function Invoke-ListSessions([string]$Project, [switch]$Titles, [switch]$Json, [string]$App) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $items = New-Object System.Collections.Generic.List[object]
    $localRows = New-Object System.Collections.Generic.List[object]
    $localOnly = $false
    foreach ($app in (Get-SelectedApps $App)) {
        $localMap = Get-LocalSessions $app
        $remoteMap = $null
        try { $remoteMap = Get-RemoteSessions $cfg $app } catch { $remoteMap = $null }
        if ($null -eq $remoteMap) { $remoteMap = @{}; $localOnly = $true }

        $projects = @($localMap.Keys + $remoteMap.Keys | Sort-Object -Unique)
        foreach ($proj in $projects) {
            if ($Project -and $proj -ne $Project) { continue }
            $seen = @{}
            if ($localMap.ContainsKey($proj)) {
                foreach ($l in $localMap[$proj]) {
                    $seen[$l.id] = $true
                    $items.Add(@{ app = $app; proj = $proj; id = $l.id; size = $l.size; mtime = $l.mtime; path = $l.path; where = "local" })
                    $localRows.Add(@{ app = $app; proj = $proj; id = $l.id; path = $l.path; size = $l.size; mtime = $l.mtime })
                }
            }
            if ($remoteMap.ContainsKey($proj)) {
                foreach ($r in $remoteMap[$proj]) {
                    if ($seen.ContainsKey($r.id)) { continue }
                    $items.Add(@{ app = $app; proj = $proj; id = $r.id; size = $r.size; mtime = $r.mtime; path = $null; where = "remote" })
                }
            }
        }
    }
    $sorted = @($items | Sort-Object -Property mtime -Descending)
    if ($localOnly) {
        Write-Warn2 "  (remote unreachable — local-only view)"
    }
    if ($Json) {
        # SPEC section 9: list --json is the LOCAL inventory (same as Linux;
        # remote-only sessions have no local path to report)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($l in $localRows) {
            $row = @{
                app = $l.app
                project = $l.proj
                id = $l.id
                path = $l.path
                size = [long]$l.size
                mtime = (Get-IsoTime $l.mtime)
            }
            if ($Titles) {
                if ($l.app -eq "codex") { $row.title = (Get-CodexTitle $l.path) }
                else { $row.title = (Get-SessionTitle $l.path) }
            }
            $rows.Add($row)
        }
        $jsonRows = @($rows | Sort-Object -Property @{Expression = "mtime"; Descending = $true })
        Emit-Json $jsonRows
        return
    }
    if ($sorted.Count -eq 0) {
        Write-Info "no sessions found"
        return
    }
    foreach ($it in $sorted) {
        $key = Get-LedgerKey $it.proj $it.id $it.app
        $state = "new-" + $(if ($it.where -eq "local") { "here" } else { "there" })
        if ($ledger.sessions.ContainsKey($key)) { $state = "in-sync?" }
        $line = "{0}  {1}  {2}  {3}  {4}" -f `
            ($it.mtime.ToString("yyyy-MM-dd HH:mm")), (Get-ShortId $it.id),
            (Get-HumanSize $it.size), $it.proj, $it.id
        Write-Info $line
        if ($Titles) {
            $title = ""
            if ($it.path) {
                if ($it.app -eq "codex") { $title = (Get-CodexTitle $it.path) }
                else { $title = (Get-SessionTitle $it.path) }
            }
            if (-not $title -and $it.where -eq "remote") {
                $tmp = Get-RemoteTranscript $cfg $it.proj $it.id $it.app
                if ($tmp) {
                    if ($it.app -eq "codex") { $title = (Get-CodexTitle $tmp) }
                    else { $title = (Get-SessionTitle $tmp) }
                    Remove-Item -LiteralPath $tmp -Force
                }
            }
            if ($title) { Write-Info "        $title" }
        }
    }
    Write-Info ""
    Write-Info ("{0} session(s)" -f $sorted.Count)
}

function Invoke-Status([string]$Project, [switch]$Json, [string]$App) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $col = Get-CollectRows $cfg $App $ledger $false
    $rows = $col.rows
    if (-not $col.reachable) {
        Write-Warn2 "  [!]  remote unreachable — local-only view"
    }
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $counts = @{}
    foreach ($r in $rows) {
        if (-not $counts.ContainsKey($r.state)) { $counts[$r.state] = 0 }
        $counts[$r.state]++
    }
    # a project name can exist under BOTH apps — count unique (app, project) pairs
    $projCount = @($rows | ForEach-Object { "$($_.app)|$($_.project)" } | Sort-Object -Unique).Count

    if ($Json) {
        $jsonRows = New-Object System.Collections.Generic.List[object]
        foreach ($r in ($rows | Sort-Object -Property app, project, id)) {
            $localObj = $null
            if ($r.local) {
                $localObj = @{
                    size = [long]$r.local.size
                    md5 = "$($r.local_md5)"
                    mtime = (Get-IsoTime $r.local.mtime)
                }
            }
            $remoteObj = $null
            if ($r.remote) {
                $remoteObj = @{
                    size = [long]$r.remote.size
                    md5 = "$($r.remote_md5)"
                    mtime = (Get-IsoTime $r.remote.mtime)
                }
            }
            $lastSynced = $null
            if ($r.entry) { $lastSynced = $r.entry.last_synced }
            $jsonRows.Add(@{
                app = $r.app
                project = $r.project
                id = $r.id
                state = $r.state
                local = $localObj
                remote = $remoteObj
                last_synced = $lastSynced
            })
        }
        Emit-Json @{
            remote = (ConvertTo-DriveUrl $cfg $null)
            reachable = $col.reachable
            projects = $projCount
            sessions = $rows.Count
            counts = $counts
            rows = $jsonRows
        }
        return
    }

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
            if ($_.local) { $_.local.mtime } elseif ($_.remote) { $_.remote.mtime } else { $null } }; Descending = $true })) {
        $when = "-"; $size = "-"
        if ($r.local) { $when = Format-Time $r.local.mtime; $size = Get-HumanSize $r.local.size }
        elseif ($r.remote) { $when = Format-Time $r.remote.mtime; $size = Get-HumanSize $r.remote.size }
        $appCol = ""
        if ($r.app -eq "codex") { $appCol = "[codex] " }
        Write-Info ("{0,-10}  {1,-8}  {2,-11}  {3,7}  {4}{5}" -f `
            (Format-State $r.state), (Get-ShortId $r.id), $when, $size, $appCol, $r.project)
    }
    if ($counts.ContainsKey("conflict")) {
        Write-Info ""
        Write-Info "conflicts need a decision:  sessium sync   (prompts on a terminal;"
        Write-Info "                            or resolve one:  sessium resolve <id>)"
    }
}

function Invoke-Check([switch]$Full, [string]$App) {
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
    # $which, not $app: PowerShell variables are CASE-INSENSITIVE — a foreach
    # ($app …) loop would clobber the $App parameter (it did: the deep check
    # then ran with the last loop value, "codex", and audited nothing)
    foreach ($which in (Get-SelectedApps $App)) {
        $localCount = 0; $remoteCount = 0
        try {
            $localMap = Get-LocalSessions $which
            foreach ($l in $localMap.Values) { $localCount += @($l).Count }
            foreach ($r in (Get-RemoteSessions $cfg $which).Values) { $remoteCount += @($r).Count }
            Write-Info ("   {0}: local: {1} session(s), remote: {2} session(s)" -f $which, $localCount, $remoteCount)
        } catch {
            Write-Warn2 "   FAIL: could not count $which sessions: $($_.Exception.Message)"
            $ok = $false
        }
    }

    Write-Info ""
    if ($ok) { Write-Info "all checks passed" } else { Write-Fail "some checks failed (see above)" }
    if (-not $Full) { return 0 }
    return (Invoke-DeepCheck $cfg $App)
}

<# Deterministic, evenly spread sample of a sorted list (up to count). #>
function Pick-Sample($Items, [int]$Count) {
    $items = @($Items)
    if ($items.Count -le $Count) { return ,$items }
    $step = $items.Count / $Count
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Count; $i++) {
        $idx = [int][Math]::Floor($i * $step)
        if ($idx -gt $items.Count - 1) { $idx = $items.Count - 1 }
        $out.Add($items[$idx])
    }
    return ,$out
}

<# The --full half of check: audit the ledger against both sides and
   spot-verify a sample of in-sync sessions (local bytes vs Drive hash).
   Read-only. Orphans and dead ledger entries are informational (sessium
   never deletes); an md5 spot-check mismatch is a real failure. #>
function Invoke-DeepCheck($Cfg, [string]$App) {
    Write-Info ""
    Write-Info "deep check (--full):"
    $apps = Get-SelectedApps $App
    $remoteKeys = @{}; $remoteMd5s = @{}
    foreach ($app in $apps) {
        $remoteMap = @{}
        try { $remoteMap = Get-RemoteSessions $Cfg $app } catch {
            Write-Fail "deep check: cannot list Drive: $($_.Exception.Message)"
        }
        foreach ($proj in $remoteMap.Keys) {
            foreach ($s in @($remoteMap[$proj])) {
                $k = Get-LedgerKey $proj $s.id $app
                $remoteKeys[$k] = $true
                $remoteMd5s[$k] = $s.md5
            }
        }
    }

    $localKeys = @{}; $localMd5s = @{}
    foreach ($app in $apps) {
        $localMap = Get-LocalSessions $app
        foreach ($proj in $localMap.Keys) {
            foreach ($s in @($localMap[$proj])) {
                $k = Get-LedgerKey $proj $s.id $app
                $localKeys[$k] = $true
                $localMd5s[$k] = $s.md5
            }
        }
    }

    $ledger = (Get-Ledger).sessions

    # dead ledger entries — recorded, but the file is gone from both sides
    $dead = @($ledger.Keys | Where-Object { -not $localKeys.ContainsKey($_) -and -not $remoteKeys.ContainsKey($_) } | Sort-Object)
    if ($dead.Count -gt 0) {
        Write-Warn2 "[!]  dead ledger entries: $($dead.Count) (harmless; they classify as new-here/new-there until pruned by hand)"
        foreach ($k in (@($dead) | Select-Object -First 10)) { Write-Info "       - $k" }
        if ($dead.Count -gt 10) { Write-Info ("       … and {0} more" -f ($dead.Count - 10)) }
    } else {
        Write-Info "[OK] ledger: no dead entries"
    }

    # orphans — on Drive but never recorded here (normal: other machines)
    $orphans = @($remoteKeys.Keys | Where-Object { -not $localKeys.ContainsKey($_) -and -not $ledger.ContainsKey($_) } | Sort-Object)
    if ($orphans.Count -gt 0) {
        Write-Info ("     orphans on Drive (never synced from this machine): {0} — expected for other machines' sessions" -f $orphans.Count)
        foreach ($k in (@($orphans) | Select-Object -First 10)) {
            if ($k -match "^(.*)/(.*)$") {
                Write-Info "       - $($Matches[1])/$(Get-ShortId $Matches[2])"
            } else {
                Write-Info "       - $k"
            }
        }
        if ($orphans.Count -gt 10) { Write-Info ("       … and {0} more" -f ($orphans.Count - 10)) }
    } else {
        Write-Info "[OK] no orphans on Drive"
    }

    # spot-check: live local md5 vs live Drive md5 on in-sync sessions
    $candidates = @()
    foreach ($k in ($localKeys.Keys | Sort-Object)) {
        if (-not $remoteKeys.ContainsKey($k)) { continue }
        if (-not $ledger.ContainsKey($k)) { continue }
        $e = $ledger[$k]
        if (-not $e.local_md5 -or -not $e.remote_md5) { continue }
        if ($e.local_md5 -ne $e.remote_md5) { continue }
        if (-not "$($remoteMd5s[$k])") { continue }
        $candidates += $k
    }
    # direct assignment, NOT @(): Pick-Sample uses `return ,$items` (the
    # unroll guard emits the array as ONE pipeline object), and @() around
    # the call re-wraps that into a 1-element array whose element is the
    # (empty) array — sample.Count would be 1 with a non-key inside.
    $sample = Pick-Sample $candidates 10
    $mismatches = 0
    foreach ($k in $sample) {
        if ($k -match "^(.*)/(.*)$") {
            $proj = $Matches[1]; $sid = $Matches[2]
            if ("$($localMd5s[$k])" -eq "$($remoteMd5s[$k])") {
                Write-Info "[OK] spot-check $proj/$(Get-ShortId $sid): md5 matches on both sides"
            } else {
                Write-Warn2 "[X]  spot-check ${k}: local md5 $($localMd5s[$k]) != Drive md5 $($remoteMd5s[$k]) — re-push or re-pull this session"
                $mismatches++
            }
        }
    }
    if ($sample.Count -eq 0) {
        Write-Info "     nothing to spot-check yet (no sessions on both sides)"
    } elseif ($mismatches -eq 0) {
        Write-Info "[OK] spot-check: $($sample.Count) session(s) verified"
    }
    if ($mismatches -gt 0) { return 1 }
    return 0
}

# ------------------------------------------------------------ push/pull/sync

$script:LockStaleSeconds = 600

<# Serialize push/pull/sync per machine with a lock file next to the ledger
   (SPEC section 7). -DryRun mutates nothing and never locks. A lock older
   than $script:LockStaleSeconds is treated as a crashed run and broken with
   a warning; a fresh one is a hard error. #>
function Invoke-WithTransferLock([bool]$DryRun, [scriptblock]$Body) {
    if ($DryRun) { & $Body; return }
    $lock = Join-Path (Split-Path -Parent (Get-StatePath)) "sync.lock"
    $lockDir = Split-Path -Parent $lock
    if (-not (Test-Path -LiteralPath $lockDir)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }
    $fs = $null
    while ($null -eq $fs) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $lock)) { continue }  # vanished between the calls
            $age = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds
            if ($age -gt $script:LockStaleSeconds) {
                Write-Warn2 ("  [!]  breaking stale lock {0} ({1} min old — likely a crashed run)" -f $lock, [int]($age / 60))
                Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
                continue
            }
            # print + exit 1, matching Linux's "except LockBusy: fail(); return 1".
            # A raw throw here escapes the & script invocation and kills the
            # caller (the smoke / any wrapper) instead of exiting rc=1.
            Write-Fail "another sessium transfer holds $lock — wait for it, or delete the file if that run is dead"
            exit 1
        }
    }
    try {
        $fs.Close()
        [System.IO.File]::WriteAllText($lock,
            "pid $PID started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        & $Body
    } finally {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
}

<# Same shape as Linux's transfer_summary: both counts always shown (even 0),
   and "FAILED:" — the wording a user sees in a real failure paste. #>
function Write-TransferSummary([int]$Pushed, [int]$Pulled, [int]$Skipped, [int]$InSync, [int]$Failures) {
    $parts = @("pushed: $Pushed", "pulled: $Pulled")
    if ($Skipped -gt 0) { $parts += "conflicts skipped: $Skipped" }
    $parts += "in-sync: $InSync"
    if ($Failures -gt 0) { $parts += "FAILED: $Failures" }
    Write-Info ("  " + ($parts -join "   "))
}

<# Fast lane (--only memory / --only skills): two-way rclone copy --update
   of the small precious folders - per-file newest-wins, never deletes, no
   ledger (folder-level sync; sessions keep the md5 machine). #>
function Invoke-SyncOnly([string]$What, [bool]$DryRun) {
    $cfg = Get-SessiumConfig
    $claude = Get-ClaudeDir
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($What -eq "memory") {
        $root = Join-Path $claude "projects"
        if (Test-Path -LiteralPath $root) {
            foreach ($projDir in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
                $mem = Join-Path $projDir.FullName "memory"
                if (Test-Path -LiteralPath $mem) {
                    $pairs.Add(@{ local = $mem; remote = (ConvertTo-DriveUrl $cfg "projects/$($projDir.Name)/memory") })
                }
            }
        }
        $entries = @()
        try {
            $text = Invoke-Rclone -RcloneArgs @("lsjson", "--recursive", (ConvertTo-DriveUrl $cfg "projects"))
            if ($text) { $entries = @($text | ConvertFrom-Json) }
        } catch {
            # fresh remote: no projects/ folder yet == empty, not unreachable
            if ("$($_.Exception.Message)" -notmatch "directory not found") {
                Write-Fail "cannot reach Drive: $($_.Exception.Message)"
            }
        }
        foreach ($e in $entries) {
            if ("$(Get-JsonProp $e 'Path')" -notmatch '^projects/([^/]+)/memory/') { continue }
            $localMem = Join-Path (Join-Path $root $Matches[1]) "memory"
            if (-not (Test-Path -LiteralPath $localMem)) {
                $pairs.Add(@{ local = $localMem; remote = (ConvertTo-DriveUrl $cfg "projects/$($Matches[1])/memory") })
            }
        }
    } else {
        $pairs.Add(@{ local = (Join-Path $claude "skills"); remote = (ConvertTo-DriveUrl $cfg "config/skills") })
    }

    if ($pairs.Count -eq 0) {
        Write-Info "nothing to sync for --only $What"
        return 0
    }
    $failures = 0
    foreach ($p in $pairs) {
        if ($DryRun) {
            Write-Info ("would two-way sync {0}  <->  {1}" -f $p.local, $p.remote)
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $p.local)) {
                New-Item -ItemType Directory -Path $p.local -Force | Out-Null
            }
            Invoke-CopyWithRetry -RcloneArgs @("copy", ($p.local + "/"), ($p.remote + "/"), "--update")
            Invoke-CopyWithRetry -RcloneArgs @("copy", ($p.remote + "/"), ($p.local + "/"), "--update")
            $tail = ($p.remote -split ":")[-1]
            Write-Info "[OK] synced ${What}: $(Split-Path -Leaf $p.local)  <->  $tail"
        } catch {
            Write-Warn2 "[!]  --only $What failed for $($p.local): $($_.Exception.Message)"
            $failures++
        }
    }
    if ($DryRun) {
        Write-Info "dry-run: $($pairs.Count) folder(s) would be synced — nothing changed"
    } elseif ($failures -gt 0) {
        Write-Info ("  pushed: 0   pulled: 0   in-sync: 0   FAILURES: {0}" -f $failures)
    }
    if ($failures -gt 0) { exit 1 }
    return 0
}

function Invoke-Push([string]$Project, [string]$App, [switch]$DryRun, [switch]$Quiet) {
    if ($Quiet) { $script:Quiet = $true }
    Invoke-WithTransferLock $DryRun {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    try {
        $col = Get-CollectRows $cfg $App $ledger $true
    } catch {
        Write-Fail "cannot reach Drive: $($_.Exception.Message)"
        return
    }
    $rows = $col.rows
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $pushed = 0; $skipped = 0; $failures = 0; $dirty = $false
    $inSync = 0; $bootstrapCount = 0
    foreach ($r in $rows) {
        if ($r.state -eq "in-sync") {
            $inSync++
            if ($r.entry) { continue }
            # bootstrap rule: matching copies with no record are recorded, not pushed
            if ($DryRun) { continue }
            Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.remote_md5 $r.app
            $bootstrapCount++
            $dirty = $true
            continue
        }
        if ($r.state -eq "conflict") {
            $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
            Write-Warn2 "  [!]  skipped CONFLICT $label — 'sessium sync' or 'sessium resolve' decides it"
            $skipped++
            continue
        }
        if ($r.state -ne "push" -and $r.state -ne "new-here") { continue }
        $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
        if ($DryRun) {
            Write-Info ("would push {0} ({1})" -f $label, (Get-HumanSize $r.local.size))
            $pushed++
            continue
        }
        Write-Info "  pushing $label"
        try {
            Copy-Up $r.local.path (ConvertTo-DriveUrl $cfg "$(Get-RemoteBase $r.app)/$($r.project)/$($r.id).jsonl")
            Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.local_md5 $r.app
            $pushed++; $dirty = $true
        } catch {
            Write-Warn2 "  [!]  push failed for ${label}: $($_.Exception.Message)"
            $failures++
        }
    }
    if ($dirty) { Save-Ledger $ledger }
    Write-TransferSummary $pushed 0 $skipped $inSync $failures
    if ($failures -gt 0) { exit 1 }
    }
}

function Invoke-Pull([string]$Project, [string]$App, [switch]$DryRun, [switch]$Quiet) {
    if ($Quiet) { $script:Quiet = $true }
    Invoke-WithTransferLock $DryRun {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    try {
        $col = Get-CollectRows $cfg $App $ledger $true
    } catch {
        Write-Fail "cannot reach Drive: $($_.Exception.Message)"
        return
    }
    $rows = $col.rows
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $pulled = 0; $skipped = 0; $failures = 0; $dirty = $false
    $inSync = 0
    foreach ($r in $rows) {
        if ($r.state -eq "in-sync") {
            $inSync++
            if ($r.entry) { continue }
            if ($DryRun) { continue }
            Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.remote_md5 $r.app
            $dirty = $true
            continue
        }
        if ($r.state -eq "conflict") {
            $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
            Write-Warn2 "  [!]  skipped CONFLICT $label — 'sessium sync' or 'sessium resolve' decides it"
            $skipped++
            continue
        }
        if ($r.state -ne "pull" -and $r.state -ne "new-there") { continue }
        $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
        if ($DryRun) {
            Write-Info ("would pull {0} ({1})" -f $label, (Get-HumanSize $r.remote.size))
            $pulled++
            continue
        }
        Write-Info "  pulling $label"
        try {
            # codex: the mtime drives the synthesized rollout-<mtime>-<uuid> path
            $dest = Get-LocalSessionPath $r.project $r.id $r.app $r.remote.mtime
            Copy-Down (ConvertTo-DriveUrl $cfg "$(Get-RemoteBase $r.app)/$($r.project)/$($r.id).jsonl") $dest
            Set-LedgerEntry $ledger $r.project $r.id $r.remote_md5 $r.remote_md5 $r.app
            $pulled++; $dirty = $true
        } catch {
            Write-Warn2 "  [!]  pull failed for ${label}: $($_.Exception.Message)"
            $failures++
        }
    }
    if ($dirty) { Save-Ledger $ledger }
    Write-TransferSummary 0 $pulled $skipped $inSync $failures
    if ($failures -gt 0) { exit 1 }
    }
}

function Invoke-Sync([string]$Project, [string]$Only, [string]$App, [switch]$Interactive,
                     [switch]$DryRun, [switch]$Quiet) {
    if ($Quiet) { $script:Quiet = $true }
    Invoke-WithTransferLock $DryRun {
    $cfg = Get-SessiumConfig
    if ($Only) {
        # sync --only memory/skills walks the CLAUDE tree's memory/ and skills/
        # folders — codex has no such folders, so --app codex here is a mistake
        if ($App -eq "codex") {
            Write-Fail "--only memory/skills syncs Claude Code folders — drop --app or use --app claude"
            return
        }
        return (Invoke-SyncOnly $Only $DryRun)
    }
    $ledger = Get-Ledger
    try {
        $col = Get-CollectRows $cfg $App $ledger $true
    } catch {
        Write-Fail "cannot reach Drive: $($_.Exception.Message)"
        return
    }
    $rows = $col.rows
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }

    $wantInteractive = $Interactive -or (Get-WantInteractive)
    $pushed = 0; $pulled = 0; $resolved = 0; $skipped = 0; $failures = 0
    $inSync = 0; $dirty = $false
    foreach ($r in $rows) {
        $label = "{0}/{1}" -f $r.project, (Get-ShortId $r.id)
        $rUrl = ConvertTo-DriveUrl $cfg "$(Get-RemoteBase $r.app)/$($r.project)/$($r.id).jsonl"
        switch ($r.state) {
            "in-sync" {
                $inSync++
                if (-not $r.entry -and -not $DryRun) {
                    Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.remote_md5 $r.app
                    $dirty = $true
                }
            }
            "push" {
                if ($DryRun) {
                    Write-Info ("would push {0} ({1})" -f $label, (Get-HumanSize $r.local.size))
                    $pushed++
                    continue
                }
                Write-Info "  pushing $label"
                try {
                    Copy-Up $r.local.path $rUrl
                    Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.local_md5 $r.app
                    $pushed++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  push failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "pull" {
                if ($DryRun) {
                    Write-Info ("would pull {0} ({1})" -f $label, (Get-HumanSize $r.remote.size))
                    $pulled++
                    continue
                }
                Write-Info "  pulling $label"
                try {
                    $dest = Get-LocalSessionPath $r.project $r.id $r.app $r.remote.mtime
                    Copy-Down $rUrl $dest
                    Set-LedgerEntry $ledger $r.project $r.id $r.remote_md5 $r.remote_md5 $r.app
                    $pulled++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  pull failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "new-here" {
                if ($DryRun) {
                    Write-Info ("would push {0} ({1})" -f $label, (Get-HumanSize $r.local.size))
                    $pushed++
                    continue
                }
                Write-Info "  pushing (new) $label"
                try {
                    Copy-Up $r.local.path $rUrl
                    Set-LedgerEntry $ledger $r.project $r.id $r.local_md5 $r.local_md5 $r.app
                    $pushed++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  push failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "new-there" {
                if ($DryRun) {
                    Write-Info ("would pull {0} ({1})" -f $label, (Get-HumanSize $r.remote.size))
                    $pulled++
                    continue
                }
                Write-Info "  pulling (new) $label"
                try {
                    $dest = Get-LocalSessionPath $r.project $r.id $r.app $r.remote.mtime
                    Copy-Down $rUrl $dest
                    Set-LedgerEntry $ledger $r.project $r.id $r.remote_md5 $r.remote_md5 $r.app
                    $pulled++; $dirty = $true
                } catch {
                    Write-Warn2 "  [!]  pull failed for ${label}: $($_.Exception.Message)"
                    $failures++
                }
            }
            "conflict" {
                if ($DryRun) {
                    Write-Info ("would resolve {0}: {1}" -f $label, (Describe-Conflict $r))
                    $resolved++
                    continue
                }
                $choice = Resolve-ConflictRow $r $wantInteractive
                $outcome = Invoke-ApplyConflict $cfg $r $choice $ledger
                if ($outcome -eq "resolved") { $resolved++; $dirty = $true }
                else { $skipped++ }
            }
        }
    }
    if ($dirty) { Save-Ledger $ledger }
    # same shape as Linux's transfer_summary + resolved/skipped suffixes
    $parts = @("pushed: $pushed", "pulled: $pulled")
    $parts += "in-sync: $inSync"
    if ($failures -gt 0) { $parts += "FAILED: $failures" }
    if ($resolved -gt 0) { $parts += "resolved: $resolved" }
    if ($skipped -gt 0) { $parts += "skipped: $skipped" }
    $prefix = ""; if ($DryRun) { $prefix = "dry-run: " }
    Write-Info ("  " + $prefix + ($parts -join "   "))
    if ($failures -gt 0) { exit 1 }
    }
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
        $tmp = Get-RemoteTranscript (Get-SessiumConfig) $Row.project $Row.id $Row.app
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

function Invoke-Diff([string]$Prefix, [string]$Project, [string]$App, [switch]$Json, [switch]$Messages) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    try {
        $col = Get-CollectRows $cfg $App $ledger $true
    } catch {
        Write-Fail "cannot reach Drive: $($_.Exception.Message)"
        return
    }
    $rows = $col.rows
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }
    $row = Find-OneSession $Prefix $rows

    $preview = $null
    $tmp = $null
    try {
        if ($Messages) {
            if (-not $row.local -or -not $row.remote) {
                Write-Warn2 "  [!]  --messages needs both copies present (pull first if the remote side is missing)"
            } else {
                $localMsgs = Get-TranscriptMessages $row.local.path
                $tmp = Get-RemoteTranscript $cfg $row.project $row.id $row.app
                $remoteMsgs = @()
                if ($tmp) { $remoteMsgs = Get-TranscriptMessages $tmp }
                $preview = Get-MessageDivergence $localMsgs $remoteMsgs
            }
        }
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force }
    }

    if ($Json) {
        $localObj = $null; $remoteObj = $null
        if ($row.local) {
            $t = Read-Transcript $row.local.path
            $localObj = @{
                path = $row.local.path
                size = [long]$row.local.size
                md5 = "$($row.local_md5)"
                mtime = (Get-IsoTime $row.local.mtime)
                messages = $t.messages
                last = $t.last
            }
        }
        if ($row.remote) {
            $remoteObj = @{
                size = [long]$row.remote.size
                md5 = "$($row.remote_md5)"
                mtime = (Get-IsoTime $row.remote.mtime)
                messages = 0
                last = ""
            }
            $tmp2 = Get-RemoteTranscript $cfg $row.project $row.id $row.app
            if ($tmp2) {
                $t = Read-Transcript $tmp2
                Remove-Item -LiteralPath $tmp2 -Force
                $remoteObj.messages = $t.messages
                $remoteObj.last = $t.last
            }
        }
        $ledgerObj = $null
        if ($row.entry) {
            $ledgerObj = @{
                last_synced = $row.entry.last_synced
                local_md5 = $row.entry.local_md5
                remote_md5 = $row.entry.remote_md5
            }
        }
        $doc = @{
            app = $row.app
            project = $row.project
            id = $row.id
            state = $row.state
            local = $localObj
            remote = $remoteObj
            ledger = $ledgerObj
        }
        if ($null -ne $preview) {
            $la = New-Object System.Collections.Generic.List[object]
            foreach ($m in @($preview.local_added)) { $la.Add(@($m.role, $m.text)) }
            $ra = New-Object System.Collections.Generic.List[object]
            foreach ($m in @($preview.remote_added)) { $ra.Add(@($m.role, $m.text)) }
            # .ToArray(), not @(): @() around a List[object] is pwsh 7.4's
            # "Argument types do not match" DLR crash under strict mode
            $doc.preview = @{
                common = $preview.common
                local_added = $la.ToArray()
                remote_added = $ra.ToArray()
            }
        }
        Emit-Json $doc
        return
    }
    Show-DiffRow $row
    if ($null -ne $preview) {
        Write-Info ("  conversation  common prefix: {0} message(s) — everything past it is unsynced" -f $preview.common)
        foreach ($side in @("local", "remote")) {
            $msgs = @(); if ($side -eq "local") { $msgs = @($preview.local_added) } else { $msgs = @($preview.remote_added) }
            Write-Info ("    {0} adds {1}" -f $side, $msgs.Count)
            $shown = 0
            foreach ($m in $msgs) {
                if ($shown -ge 12) { break }
                $text = $m.text
                if ($text.Length -gt 100) { $text = $text.Substring(0, 100) }
                Write-Info ("      + {0}  {1}" -f $m.role.PadRight(9), $text)
                $shown++
            }
            if ($msgs.Count -gt 12) {
                Write-Info ("      … {0} more" -f ($msgs.Count - 12))
            }
        }
    }
}

function Invoke-Resolve([string]$Prefix, [switch]$Interactive, [string]$Project, [string]$App) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    try {
        $col = Get-CollectRows $cfg $App $ledger $true
    } catch {
        Write-Fail "cannot reach Drive: $($_.Exception.Message)"
        return
    }
    $rows = $col.rows
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

function Invoke-Revert([string]$Prefix, [string]$App, [switch]$DryRun) {
    $found = New-Object System.Collections.Generic.List[object]
    $anyRoot = $false
    foreach ($app in (Get-SelectedApps $App)) {
        $root = Get-LocalRoot $app
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $anyRoot = $true
        foreach ($projDir in (Get-ChildItem -LiteralPath $root -Directory)) {
            $revDir = Join-Path $projDir.FullName "revert"
            if (-not (Test-Path -LiteralPath $revDir)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $revDir -File -Filter "*.jsonl")) {
                if (-not $f.Name.StartsWith("$Prefix.revert-")) { continue }
                $sid = $f.Name.Substring(0, $f.Name.IndexOf(".revert-"))
                $found.Add(@{ app = $app; project = $projDir.Name; sid = $sid; path = $f.FullName })
            }
        }
    }
    if (-not $anyRoot) {
        Write-Fail "no revert copies found (nothing at $(Get-LocalRoot 'claude'))"
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
    if ($DryRun) {
        Write-Info "dry-run: would prompt for which copy to restore — nothing changed"
        return 0
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
    $revApp = "$($copies[0].app)"
    $target = Get-LocalSessionPath $parts[0] $parts[1] $revApp
    if (Test-Path -LiteralPath $target) {
        Save-LocalRevert $parts[0] $parts[1] $target $revApp | Out-Null    # keep the current copy
    }
    Move-Item -LiteralPath $chosen.path -Destination $target
    $ledger = Get-Ledger
    if ($ledger.sessions.ContainsKey($key)) {
        $entry = $ledger.sessions[$key]
        Set-LedgerEntry $ledger $parts[0] $parts[1] (Get-FileMd5 $target) $entry.remote_md5 $revApp
        Save-Ledger $ledger
    }
    Write-Info "  restored $(Split-Path -Leaf $chosen.path) -> $target"
    Write-Info "  next: 'sessium sync' pushes the restored copy to Drive"
}

<# Restore a content-addressed history snapshot (see 'sessium log <id>').
   The copy it displaces is snapshotted first, so checkout never loses
   bytes either. #>
function Invoke-Checkout([string]$Prefix, [int]$Seq, [string]$App, [switch]$DryRun) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $col = Get-CollectRows $cfg $App $ledger $false
    $rows = $col.rows
    if (-not $col.reachable) {
        Write-Warn2 "  [!]  cannot reach Drive right now — searching locally only"
    }
    $row = Find-OneSession $Prefix $rows
    $hDir = Join-Path (Join-Path (Join-Path (Get-LocalRoot $row.app) $row.project) $row.id) "history"
    $snaps = @()
    if (Test-Path -LiteralPath $hDir) {
        $snaps = @(Get-ChildItem -LiteralPath $hDir -File -Filter "*.jsonl" | Sort-Object Name)
    }
    if ($snaps.Count -eq 0) {
        Write-Fail "no history for $(Get-ShortId $row.id) — snapshots appear when a sync overwrites a copy that had unsynced changes"
    }
    $chosen = $null
    foreach ($f in $snaps) {
        if ($f.BaseName.Split("-")[0].TrimStart("0") -eq "$Seq".TrimStart("0")) {
            $chosen = $f; break
        }
    }
    if (-not $chosen) {
        Write-Warn2 "[X]  no snapshot #$Seq for $(Get-ShortId $row.id) — available:"
        foreach ($f in $snaps) {
            Write-Info ("  {0}  {1}" -f $f.BaseName, (Get-HumanSize $f.Length))
        }
        exit 1
    }
    $target = Get-LocalSessionPath $row.project $row.id $row.app
    if ($DryRun) {
        Write-Info "dry-run: would restore $($chosen.Name) -> $target"
        return 0
    }
    if (Test-Path -LiteralPath $target) {          # preserve what it replaces
        $displaced = Save-LocalRevert $row.project $row.id $target $row.app
        Save-HistorySnapshot $row.project $row.id $displaced $row.app | Out-Null
    }
    Move-Item -LiteralPath $chosen.FullName -Destination $target -Force
    Write-Info "restored $($chosen.Name) -> $target"
    $lKey = Get-LedgerKey $row.project $row.id $row.app
    if ($ledger.sessions.ContainsKey($lKey)) {
        Set-LedgerEntry $ledger $row.project $row.id (Get-FileMd5 $target) `
            $ledger.sessions[$lKey].remote_md5 $row.app
        Save-Ledger $ledger
        Write-Info "next: 'sessium sync' pushes the restored copy to Drive"
    }
    return 0
}

<# Prune revert/ + history/ copies beyond -Keep N most recent per session
   (default 10). Canonical transcripts and the ledger are never touched.
   -DryRun lists what would go. #>
function Invoke-Gc([int]$Keep = 10, [string]$App, [switch]$DryRun) {
    $doomed = New-Object System.Collections.Generic.List[object]
    foreach ($app in (Get-SelectedApps $App)) {
        $root = Get-LocalRoot $app
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($projDir in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
            $groups = @{}
            $revDir = Join-Path $projDir.FullName "revert"
            if (Test-Path -LiteralPath $revDir) {
                foreach ($f in (Get-ChildItem -LiteralPath $revDir -File -Filter "*.jsonl")) {
                    $sid = $f.Name.Substring(0, $f.Name.IndexOf(".revert-"))
                    if (-not $groups.ContainsKey($sid)) { $groups[$sid] = New-Object System.Collections.Generic.List[object] }
                    $groups[$sid].Add($f)
                }
            }
            foreach ($sidDir in (Get-ChildItem -LiteralPath $projDir.FullName -Directory | Sort-Object Name)) {
                $hDir = Join-Path $sidDir.FullName "history"
                if (Test-Path -LiteralPath $hDir) {
                    foreach ($f in (Get-ChildItem -LiteralPath $hDir -File -Filter "*.jsonl")) {
                        if (-not $groups.ContainsKey($sidDir.Name)) { $groups[$sidDir.Name] = New-Object System.Collections.Generic.List[object] }
                        $groups[$sidDir.Name].Add($f)
                    }
                }
            }
            foreach ($sid in ($groups.Keys | Sort-Object)) {
                $ordered = @($groups[$sid] | Sort-Object -Property LastWriteTime -Descending)
                for ($i = $Keep; $i -lt $ordered.Count; $i++) {
                    $doomed.Add(@{ project = $projDir.Name; sid = $sid; path = $ordered[$i] })
                }
            }
        }
    }
    if ($doomed.Count -eq 0) {
        Write-Info "nothing to prune"
        return 0
    }
    foreach ($d in $doomed) {
        if ($DryRun) {
            Write-Info ("would prune {0}/{1}: {2}" -f $d.project, $d.sid, $d.path.FullName)
        } else {
            try {
                Remove-Item -LiteralPath $d.path.FullName -Force
                Write-Info ("pruned {0}/{1}: {2}" -f $d.project, $d.sid, $d.path.Name)
            } catch {
                Write-Warn2 "could not prune $($d.path.FullName): $($_.Exception.Message)"
            }
        }
    }
    if ($DryRun) {
        Write-Info "dry-run: $($doomed.Count) file(s) would be pruned — nothing changed"
    } else {
        Write-Info "pruned $($doomed.Count) file(s); kept $Keep most recent per session"
    }
    return 0
}

function Invoke-Adopt([string]$Source, [string]$RepoPath, [switch]$DryRun) {
    $src = $Source
    $root = Join-Path (Get-ClaudeDir) "projects"
    $srcDir = Join-Path $root $src
    if (-not (Test-Path -LiteralPath $srcDir)) {
        Write-Info "no sessions folder '$src' under $root"
        if (Test-Path -LiteralPath $root) {
            Write-Info "available folders:"
            foreach ($d in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
                Write-Info "    $($d.Name)"
            }
        }
        exit 1
    }
    $dest = ConvertTo-Munge $RepoPath
    if ($src -eq $dest) {
        Write-Info "already matches this machine's path ($dest) — nothing to do"
        return 0
    }
    $destDir = Join-Path $root $dest
    $copied = 0; $already = 0; $kept = 0
    foreach ($item in (Get-ChildItem -LiteralPath $srcDir | Sort-Object Name)) {
        if ($item.Name -eq "revert") { continue }          # machine-local, never rehomed
        $tgt = Join-Path $destDir $item.Name
        if ($item.PSIsContainer) {
            if (Test-Path -LiteralPath $tgt) {
                Write-Warn2 "  [!]  folder $($item.Name)/ already exists at the destination — left as is"
                $kept++
                continue
            }
            if ($DryRun) {
                Write-Info "would copy folder $($item.Name)/"
                $copied++
                continue
            }
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $tgt -Recurse
            $copied++
        } else {
            if ($item.Extension -ne ".jsonl") { continue }  # adopt transcripts (mirrors Linux)
            if (Test-Path -LiteralPath $tgt) {
                $a = Get-FileMd5 $item.FullName
                $b = Get-FileMd5 $tgt
                if ($a -eq $b) { $already++; continue }
                Write-Warn2 "  [!]  kept both: $($item.Name) differs from the copy already at the destination"
                $kept++
                continue
            }
            if ($DryRun) {
                Write-Info "would copy $($item.Name)"
                $copied++
                continue
            }
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $tgt
            $copied++
        }
    }
    $prefix = ""; if ($DryRun) { $prefix = "dry-run: " }
    Write-Info ("{0}adopted {1} -> {2}: {3} copied, {4} already present, {5} kept as is" -f `
        $prefix, $src, $dest, $copied, $already, $kept)
    if (-not $DryRun) {
        Write-Info "next:  cd $RepoPath; claude --resume"
    }
    return 0
}

# ---------------------------------------------------------------- batch 3

function Invoke-Version {
    Write-Info "sessium $script:Version"
    return 0
}

<# The repo path recorded in the transcript's entries (Claude Code stamps a
   `cwd` on most lines). This is how `open` maps a session back to its repo
   without having to reverse the lossy munging. "" when none. #>
function Get-SessionCwd([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($i -ge 50) { break }
        $i++
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $cwd = Get-JsonProp $obj "cwd"
        if ($cwd -is [string] -and $cwd) { return $cwd }
    }
    return ""
}

<# Print (or with -Go, spawn) the resume command for a session. The repo
   path comes from the transcript's own cwd stamps, so this works across
   machines despite the lossy munging. -Adopt rehomes the sessions first
   when the repo is not at this machine's matching path. #>
function Invoke-Open([string]$Prefix, [string]$Project, [string]$App, [switch]$Go,
                     [switch]$Adopt, [switch]$DryRun) {
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $col = Get-CollectRows $cfg $App $ledger $false
    $rows = $col.rows
    if (-not $col.reachable) {
        Write-Warn2 "  [!]  cannot reach Drive right now — searching locally only"
    }
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }
    $row = Find-OneSession $Prefix $rows

    if (-not $row.local) {
        Write-Fail "$($row.project)/$($row.id) is not on this machine — run 'sessium pull' first"
    }
    $cwd = ""
    if ($row.app -eq "codex") {
        $meta = Get-CodexMeta $row.local.path
        if ($meta) { $cwd = $meta.cwd }
    } else {
        $cwd = Get-SessionCwd $row.local.path
    }
    if (-not $cwd) {
        # lossy inverse of munge(), as a last resort — flagged as a guess
        $cwd = $row.project.Replace("-", "\")
        Write-Warn2 "  [!]  transcript has no cwd stamp — guessing $cwd"
    }
    if ($Adopt -and -not (Test-Path -LiteralPath $cwd)) {
        Write-Info "repo path $cwd does not exist here — adopting sessions first"
        if ($DryRun) {
            Write-Info "dry-run: would run adopt for $($row.project) -> $cwd"
            return
        }
        Invoke-Adopt $row.project $cwd
        return
    }
    $binary = "claude"; $goArgs = "claude --resume $($row.id)"
    if ($row.app -eq "codex") { $binary = "codex"; $goArgs = "codex resume $($row.id)" }
    $resume = "cd $cwd; $goArgs"
    if ($Go) {
        if ($DryRun) {
            Write-Info "dry-run: would launch: $resume"
            return
        }
        Start-Process -FilePath "powershell" -WorkingDirectory $cwd `
            -ArgumentList "-NoExit", "-Command", $goArgs
        return 0
    }
    Write-Info $resume
    return 0
}

<# No id: git-style alias for `list`. With an id: list the session's
   content-addressed history snapshots (SPEC section 10). #>
function Invoke-Log([string]$Prefix, [string]$Project, [string]$App, [switch]$Titles, [switch]$Json) {
    if (-not $Prefix) {
        Invoke-ListSessions $Project -App $App -Titles:$Titles -Json:$Json
        return 0
    }
    $cfg = Get-SessiumConfig
    $ledger = Get-Ledger
    $col = Get-CollectRows $cfg $App $ledger $false
    $rows = $col.rows
    if (-not $col.reachable) {
        Write-Warn2 "  [!]  cannot reach Drive right now — searching locally only"
    }
    if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }
    $row = Find-OneSession $Prefix $rows
    $hDir = Join-Path (Join-Path (Join-Path (Get-LocalRoot $row.app) $row.project) $row.id) "history"
    $snaps = @()
    if (Test-Path -LiteralPath $hDir) {
        $snaps = @(Get-ChildItem -LiteralPath $hDir -File -Filter "*.jsonl" | Sort-Object Name)
    }
    if ($snaps.Count -eq 0) {
        Write-Info "no history yet for $(Get-ShortId $row.id) — snapshots appear here when a sync overwrites a copy that had unsynced changes"
        return 0
    }
    Write-Info "history of $($row.id) ($($row.project)):"
    foreach ($f in $snaps) {
        Write-Info ("  {0}  {1}  {2}" -f $f.BaseName, (Get-HumanSize $f.Length),
            (Format-Time $f.LastWriteTime))
    }
    Write-Info "restore one with: sessium checkout $(Get-ShortId $row.id) <seq>"
    return 0
}

# ---------------------------------------------------------------- search
# Literal search over local transcripts; semantic via seeker when configured.

$script:DefaultSearchLimit = 20

function ConvertTo-Squashed([string]$Text, [int]$Max) {
    $norm = (($Text -split "\s+") | Where-Object { $_ }) -join " "
    if ($norm.Length -gt $Max) { return $norm.Substring(0, $Max) }
    return $norm
}

<# First jsonl-aware hit of the query in a transcript's message text, as a
   snippet. Skips meta entries and command wrappers. One hit per file - a
   session matches once, its rank decides ordering. #>
function Search-Body([string]$Path, [string]$Query) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $t = Get-JsonProp $obj "type"
        if ($t -ne "user" -and $t -ne "assistant") { continue }
        if (Get-JsonProp $obj "isMeta") { continue }
        $msg = Get-JsonProp $obj "message"
        if (-not $msg) { continue }
        $text = (Get-MessageText $msg.content).Trim()
        if (-not $text -or (Test-NoiseText $text)) { continue }
        if ($text.ToLower().Contains($Query)) {
            return (Snippet-Around $text $Query)
        }
    }
    return ""
}

function Snippet-Around([string]$Text, [string]$Query, [int]$Width = 60) {
    $lowered = $Text.ToLower()
    $idx = $lowered.IndexOf($Query)
    if ($idx -lt 0) { return (ConvertTo-Squashed $Text $Width) }
    $start = $idx - [Math]::Floor($Width / 2)
    if ($start -lt 0) { $start = 0 }
    $end = $start + $Width * 2
    if ($end -gt $Text.Length) { $end = $Text.Length }
    $body = ConvertTo-Squashed $Text.Substring($start, $end - $start) ($Width * 2)
    $pre = ""; if ($start -gt 0) { $pre = "…" }
    $post = ""; if ($end -lt $Text.Length) { $post = "…" }
    return "$pre$body$post"
}

<# Literal search over local transcripts. Title matches outrank body
   matches; Drive-only sessions need a pull first (documented). #>
function Invoke-SearchLocal([string]$Query, [string]$Project, [int]$Limit) {
    $localMap = Get-LocalSessions "claude"
    $q = $Query.ToLower()
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($proj in ($localMap.Keys | Sort-Object)) {
        if ($Project -and $proj -ne $Project) { continue }
        foreach ($s in (@($localMap[$proj]) | Sort-Object -Property mtime -Descending)) {
            $path = $s.path
            $title = Get-SessionTitle $path
            $bodyHit = ""
            $where = $null
            if ($title.ToLower().Contains($q)) {
                $where = "title"
            } else {
                $bodyHit = Search-Body $path $q
                if ($bodyHit) { $where = "body" }
            }
            if (-not $where) { continue }
            $hits.Add(@{
                project = $proj
                id = $s.id
                title = $title
                snippet = $bodyHit
                where = $where
                mtime = (Get-IsoTime $s.mtime)
            })
        }
    }
    # rank first (title beats body), newest first within a rank - one
    # compound sort, no reliance on sort stability
    return @($hits | Sort-Object -Property `
        @{ Expression = { if ($_.where -eq "title") { 0 } else { 1 } } },
        @{ Expression = { if ($_.mtime) { $_.mtime } else { "" } }; Descending = $true })
}

<# POST JSON to the self-hosted seeker engine (Tailscale-only, bearer-auth;
   contract in SPEC section 5). #>
function Invoke-SeekerRequest($Cfg, [string]$ApiPath, $Payload) {
    $headers = @{ "Content-Type" = "application/json" }
    if ($Cfg.SeekerToken) {
        $headers["Authorization"] = "Bearer $($Cfg.SeekerToken)"
    }
    $url = $Cfg.SeekerUrl.TrimEnd("/") + $ApiPath
    $body = ConvertTo-Json -Compress -InputObject $Payload
    return (Invoke-RestMethod -Uri $url -Method Post -Body $body `
        -ContentType "application/json" -Headers $headers -TimeoutSec 30)
}

function Invoke-SemanticSearch([string]$Query, [string]$Project, [int]$Limit, $Cfg) {
    $out = Invoke-SeekerRequest $Cfg "/v1/search" @{
        query = $Query; limit = $Limit; source = "sessium" }
    $hits = New-Object System.Collections.Generic.List[object]
    $raw = @()
    $r = Get-JsonProp $out "results"
    if ($r) { $raw = @($r) }
    else { $h = Get-JsonProp $out "hits"; if ($h) { $raw = @($h) } }
    foreach ($hit in $raw) {
        if (-not $hit -or $hit -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $src = ""
        $p = Get-JsonProp $hit "path"
        if ($p) { $src = "$p" } else { $s2 = Get-JsonProp $hit "source"; if ($s2) { $src = "$s2" } }
        if ($src -notmatch 'projects/([^/]+)/([^/]+)\.jsonl') { continue }
        $title = ""; $tp = Get-JsonProp $hit "title"
        if ($tp) { $title = ConvertTo-Squashed "$tp" 70 }
        $snippet = ""; $xp = Get-JsonProp $hit "text"
        if ($xp) { $snippet = ConvertTo-Squashed "$xp" 140 }
        $hits.Add(@{
            project = $Matches[1]
            id = $Matches[2]
            title = $title
            snippet = $snippet
            where = "semantic"
            mtime = $null
        })
    }
    return @($hits)
}

function Show-SearchHits($Hits, [int]$Limit) {
    if (@($Hits).Count -eq 0) {
        Write-Info "no matches"
        return
    }
    foreach ($h in (@($Hits) | Select-Object -First $Limit)) {
        $stamp = "-"; if ($h.mtime) { $stamp = $h.mtime }
        Write-Info ("  {0}  {1}  {2}  {3}" -f `
            (Get-ShortId $h.id), $stamp, $h.where.PadRight(8), $h.project)
        if ($h.title) { Write-Info "      $($h.title)" }
        if ($h.snippet) { Write-Info "      $($h.snippet)" }
    }
}

<# Search sessions: literal (title > body) always; -Semantic queries seeker
   when configured. Local transcripts only - pull first to include
   Drive-only sessions. #>
function Invoke-Search([string]$Query, [string]$Project, [int]$Limit,
                       [string]$App, [switch]$Semantic, [switch]$Json) {
    # v1 limit (SPEC §7): the literal/semantic search pipeline parses Claude
    # transcripts only — codex rollouts use a different format
    if ($App -eq "codex") { Write-Fail "search reads Claude Code transcripts only for now" }
    $cfg = Get-SessiumConfig
    $hits = @()
    if ($Semantic) {
        if (-not $cfg.SeekerUrl) {
            Write-Fail 'seeker not configured — put "seeker_url" (and "seeker_token") in config.json; literal search works without it'
        }
        try {
            $hits = @(Invoke-SemanticSearch $Query $Project $Limit $cfg)
        } catch {
            Write-Fail "seeker unreachable at $($cfg.SeekerUrl): $($_.Exception.Message)"
        }
    } else {
        $hits = @(Invoke-SearchLocal $Query $Project $Limit)
    }
    if ($Json) {
        Emit-Json @(@($hits) | Select-Object -First $Limit)
        return 0
    }
    $suffix = "  (local transcripts; pull first for Drive-only sessions)"
    if ($Semantic) { $suffix = "  (via seeker)" }
    Write-Info "search '$Query' — $(@($hits).Count) match(es)$suffix"
    Show-SearchHits $hits $Limit
    return 0
}

<# Register/sync the local projects tree as a seeker source. #>
function Invoke-Seek([string]$Name) {
    $cfg = Get-SessiumConfig
    if (-not $cfg.SeekerUrl) {
        Write-Fail 'seeker not configured — put "seeker_url" (and "seeker_token") in config.json; literal search works without it'
    }
    $source = Join-Path (Get-ClaudeDir) "projects"
    $srcName = $Name
    if (-not $srcName) { $srcName = "sessium" }
    try {
        $out = Invoke-SeekerRequest $cfg "/v1/sources" @{
            name = $srcName; path = $source }
    } catch {
        Write-Fail "seeker unreachable at $($cfg.SeekerUrl): $($_.Exception.Message)"
    }
    Write-Info "seeker source synced: $source"
    $status = Get-JsonProp $out "status"
    if ($status) { Write-Info "  seeker said: $status" }
    return 0
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

# ------------------------------------------------- batch 5: schedule/hook/crypt

$script:CryptName = "sessium-crypt"

<# PSCustomObject (from ConvertFrom-Json) -> hashtable tree the serializer
   understands. Recurses into nested objects/arrays; primitives pass through. #>
function ConvertFrom-PSObject($Obj) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) {
            $h[$p.Name] = ConvertFrom-PSObject $p.Value
        }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable] -and
        $Obj -isnot [string] -and $Obj -isnot [System.Collections.IDictionary]) {
        $out = @()
        foreach ($item in @($Obj)) { $out += ,(ConvertFrom-PSObject $item) }
        return ,$out
    }
    return $Obj
}

<# Scheduled sync: a Windows Task Scheduler task ("sessium-sync") running
   `sessium.ps1 sync` every --interval minutes (default 30) — the schtasks
   equivalent of the Linux systemd user timer. SESSIUM_SCHTASKS_BIN overrides
   the schtasks binary (tests). #>
function Get-SchtasksBin {
    if ($env:SESSIUM_SCHTASKS_BIN) { return $env:SESSIUM_SCHTASKS_BIN }
    return "schtasks"
}

function Invoke-Schedule([int]$Interval = 30, [switch]$Off, [switch]$Print) {
    $bin = Get-SchtasksBin
    $taskName = "sessium-sync"
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" sync"
    $create = "schtasks /Create /TN `"$taskName`" /SC MINUTE /MO $Interval /TR `"$tr`" /F"
    if ($Print) {
        Write-Info $create
        Write-Info "--- 8< ---"
        Write-Info "task: $taskName, runs every $Interval minutes: powershell -File `"$PSCommandPath`" sync"
        Write-Info "next: schtasks /Query /TN `"$taskName`" /V   (delete by hand: schtasks /Delete /TN `"$taskName`" /F)"
        return 0
    }
    if ($Off) {
        $null = & $bin /Delete /TN $taskName /F 2>&1     # fine if it never existed
        Write-Info "[OK] schedule removed (task '$taskName' deleted)"
        return 0
    }
    $null = & $bin /Create /TN $taskName /SC MINUTE /MO $Interval /TR $tr /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "schtasks /Create failed (rc=$LASTEXITCODE) — task '$taskName' not installed"
    }
    Write-Info "[OK] schedule installed: task '$taskName' every $Interval minutes"
    Write-Info "check: schtasks /Query /TN `"$taskName`" /V"
    return 0
}

<# Wire a Claude Code Stop hook into <claude-dir>/settings.json so every
   session auto-pushes when it ends (`sessium push --quiet`). Only sessium's
   own entries are touched; --off unwinds them. #>
function Invoke-Hook([switch]$Off, [switch]$Print) {
    $settingsPath = Join-Path (Get-ClaudeDir) "settings.json"
    $data = @{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $data = ConvertFrom-PSObject $raw
        } catch {
            Write-Fail "cannot read ${settingsPath}: $($_.Exception.Message)"
        }
    }
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" push --quiet"
    $hooks = @{}
    if ($data.ContainsKey("hooks")) { $hooks = $data["hooks"] }
    $stop = @()
    if ($hooks.ContainsKey("Stop")) { $stop = @($hooks["Stop"]) }
    $keep = @()
    foreach ($entry in $stop) {
        $dump = ConvertTo-JsonText $entry 0
        if ("$dump" -match "sessium.*push --quiet") { continue }     # ours
        $keep += $entry
    }
    $stop = @($keep)
    if (-not $Off) {
        $stop += ,@{ matcher = ""; hooks = @(@{ type = "command"; command = $command }) }
    }
    if ($stop.Count -gt 0) {
        $hooks["Stop"] = $stop
        $data["hooks"] = $hooks
    } else {
        if ($hooks.ContainsKey("Stop")) { $null = $hooks.Remove("Stop") }
        if ($hooks.Count -eq 0 -and $data.ContainsKey("hooks")) { $null = $data.Remove("hooks") }
    }
    $text = (ConvertTo-JsonText $data 0) + "`n"
    if ($Print) {
        Write-Info "would write ${settingsPath}:"
        Write-Host $text
        return 0
    }
    try {
        [System.IO.File]::WriteAllText($settingsPath, $text,
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Fail "cannot write ${settingsPath}: $($_.Exception.Message)"
    }
    if ($Off) {
        Write-Info "[OK] hook removed from $settingsPath"
    } else {
        Write-Info "[OK] hook installed in $settingsPath"
        Write-Info "every session turn now ends with: $command"
    }
    return 0
}

<# Wrap the plain remote in an rclone crypt layer and point sessium at it.
   Drive-side data beyond this point is unreadable ciphertext — the password
   is generated here and shown exactly once. Same flow as the Linux
   setup_encrypted(): `rclone config create sessium-crypt crypt ...`, then a
   rewritten config.json (rclone_remote=sessium-crypt, drive_folder=""). #>
function Invoke-SetupEncrypted {
    $text = $null
    try {
        $text = Invoke-Rclone -RcloneArgs @("config", "file") -TimeoutSec 30
    } catch {
        Write-Fail "cannot run rclone: $($_.Exception.Message)"
    }
    $lines = @("$text" -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    if ($lines.Count -eq 0) {
        Write-Fail "cannot locate rclone.conf ('rclone config file' came back empty)"
    }
    $confPath = $lines[$lines.Count - 1].Trim()
    $cfg = Get-SessiumConfig
    $plain = "$($cfg.Remote):$($cfg.Folder)"
    # secrets.token_urlsafe(24): 24 random bytes, base64url, no padding
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 24
    $rng.GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    try {
        $null = Invoke-Rclone -RcloneArgs @("config", "create", $script:CryptName,
            "crypt", "remote=$plain", "password=$password") -TimeoutSec 60
    } catch {
        Write-Fail "rclone config create failed: $($_.Exception.Message)"
    }
    # re-point config.json at the crypt remote, preserving every other key
    $cfgPath = Get-ConfigPath
    $newCfg = $null
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $newCfg = ConvertFrom-PSObject $raw
        } catch {
            Write-Warn2 "  [!]  unreadable config $cfgPath — starting a fresh one"
        }
    }
    if ($null -eq $newCfg) {
        $newCfg = @{ rclone_remote = $cfg.Remote; drive_folder = $cfg.Folder
                     seeker_url = $cfg.SeekerUrl; seeker_token = $cfg.SeekerToken }
    }
    $newCfg["rclone_remote"] = $script:CryptName
    $newCfg["drive_folder"] = ""          # crypt root == old plain root
    try {
        $dir = Split-Path -Parent $cfgPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($cfgPath,
            (ConvertTo-JsonText $newCfg 0) + "`n",
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Fail "cannot write config: $($_.Exception.Message)"
    }
    Write-Info "[OK] crypt remote '$($script:CryptName)' created over $plain (rclone.conf: $confPath)"
    Write-Info "[OK] sessium config switched to the crypt remote"
    Write-Host ""
    Write-Host ("=" * 62)
    Write-Host "SAVE THIS PASSWORD — encrypted data is unrecoverable without it:"
    Write-Host "    $password"
    Write-Host ("=" * 62)
    Write-Host ""
    Write-Info "next: sessium push   (re-uploads everything as ciphertext; existing"
    Write-Info "plaintext copies stay on Drive until you delete them by hand)"
    return 0
}

# ---------------------------------------------------------------- export/onboard

<# fail() without the exit: onboard's checks are non-fatal — every gap prints
   a line and the report continues (mirrors Linux cmd_onboard, where fail()
   only prints and the command always returns 0). #>
function Write-FailLine([string]$Msg) {
    Write-Host "[X]  $Msg" -ForegroundColor Red
}

<# Python html.escape(s, quote=True): & first, then < > " '. Used by the
   export renderer, byte-identical to the Linux output. #>
function ConvertTo-HtmlEscaped([string]$S) {
    $s = $S.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
    return $s.Replace('"', "&quot;").Replace("'", "&#x27;")
}

$script:ExportCss = @'
body{font-family:system-ui,sans-serif;max-width:52rem;margin:2rem auto;
padding:0 1rem;line-height:1.55;color:#1a1a1a;background:#fafafa}
h1{border-bottom:2px solid #ddd;padding-bottom:.3rem;font-size:1.4rem}
.meta{color:#666;font-size:.85rem}
.msg{margin:.8rem 0;padding:.6rem 1rem;border-radius:.5rem}
.user{background:#e8f0fe}.assistant{background:#efefef}
.role{font-weight:600;text-transform:uppercase;font-size:.7rem;color:#555}
ul{padding-left:1.2rem}li{margin:.3rem 0}
'@

<# One session as Markdown: a metadata header, then "## role" + text per
   message. Matches Linux render_markdown() line for line. #>
function ConvertTo-ExportMarkdown([string]$Project, [string]$Sid, [string]$Path) {
    $title = Get-SessionTitle $Path
    if (-not $title) { $title = $Sid }
    $msgs = Get-TranscriptMessages $Path
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $title")
    $lines.Add("")
    $lines.Add("- project: ``$project``")
    $lines.Add("- session: ``$sid``")
    $lines.Add("- messages: $($msgs.Count)")
    $lines.Add("")
    $lines.Add("---")
    $lines.Add("")
    foreach ($m in $msgs) {
        $lines.Add("## $($m.role)")
        $lines.Add("")
        $lines.Add("$($m.text)")
        $lines.Add("")
    }
    return ($lines.ToArray() -join "`n")
}

<# One session as a small static HTML page (no JS), matching Linux
   render_session_html(). #>
function ConvertTo-ExportSessionHtml([string]$Project, [string]$Sid, [string]$Path) {
    $title = Get-SessionTitle $Path
    if (-not $title) { $title = $Sid }
    $msgs = Get-TranscriptMessages $Path
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("<!doctype html><meta charset='utf-8'><title>$(ConvertTo-HtmlEscaped $title)</title>")
    $parts.Add("<style>$script:ExportCss</style>")
    $parts.Add("<h1>$(ConvertTo-HtmlEscaped $title)</h1>")
    $parts.Add("<p class='meta'>$(ConvertTo-HtmlEscaped $project) · $sid · $($msgs.Count) message(s)</p>")
    foreach ($m in $msgs) {
        $parts.Add("<div class='msg $($m.role)'><div class='role'>$($m.role)</div>$(ConvertTo-HtmlEscaped "$($m.text)")</div>")
    }
    return ($parts.ToArray() -join "`n")
}

<# The --html --all index page linking every exported file, matching Linux
   render_index_html(). #>
function ConvertTo-ExportIndexHtml($Items) {
    $lis = New-Object System.Collections.Generic.List[string]
    foreach ($it in $Items) {
        $label = $it.title
        if (-not $label) { $label = $it.id }
        $lis.Add("<li><a href='$(ConvertTo-HtmlEscaped "$($it.file)")'>$(ConvertTo-HtmlEscaped $label)</a> " +
                 "<span class='meta'>$(ConvertTo-HtmlEscaped "$($it.project)")</span></li>")
    }
    return ("<!doctype html><meta charset='utf-8'><title>sessium sessions</title>" +
            "<style>$script:ExportCss</style>" +
            "<h1>sessium sessions</h1><ul>$($lis.ToArray() -join "`n")</ul>")
}

<# Write sessions out as Markdown (default) or HTML. -All exports every local
   session and, with -Html, adds an index.html viewer page. Same contract as
   Linux cmd_export(). Claude transcripts only for now — codex rollouts use
   a different format. #>
function Invoke-Export([string]$Prefix, [string]$OutDir, [string]$Project,
                       [string]$App, [switch]$All, [switch]$Html) {
    # v1 limit (SPEC §7): the export renderer parses Claude transcripts only
    if ($App -eq "codex") { Write-Fail "export reads Claude Code transcripts only for now" }
    # Path.expanduser(): a leading ~ means home
    $out = "$OutDir"
    if ($out -like "~*") { $out = $out -replace '^~', $HOME }
    if (-not $out) { $out = "sessium-export" }

    $localMap = Get-LocalSessions "claude"
    if ($Project) {
        $filtered = @{}
        if ($localMap.ContainsKey($Project)) { $filtered[$Project] = $localMap[$Project] }
        $localMap = $filtered
    }
    if (-not $All) {
        if (-not $Prefix) {
            Write-Fail "give a session id, or --all for every local session"
        }
        $cfg = Get-SessiumConfig
        $remoteMap = @{}
        try { $remoteMap = Get-RemoteSessions $cfg "claude" } catch { }
        $ledger = Get-Ledger
        $rows = Get-Classification "claude" $localMap $remoteMap $ledger
        if ($Project) { $rows = @($rows | Where-Object { $_.project -eq $Project }) }
        $row = Find-OneSession $Prefix $rows
        if (-not $row.local) {
            Write-Fail "that session is on Drive only — pull first (export works on local copies)"
        }
        $localMap = @{ $row.project = @($row.local) }
    }

    $ext = "md"
    if ($Html) { $ext = "html" }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($proj in ($localMap.Keys | Sort-Object)) {
        foreach ($s in $localMap[$proj]) {
            $items.Add(@{ project = $proj; id = $s.id
                          title = (Get-SessionTitle $s.path)
                          file = "$($s.id).$ext" })
        }
    }
    if ($items.Count -eq 0) {
        Write-Info "no sessions to export"
        return 0
    }
    if (-not (Test-Path -LiteralPath $out)) {
        New-Item -ItemType Directory -Path $out -Force | Out-Null
    }
    $count = 0
    foreach ($it in $items) {
        $src = Get-LocalSessionPath $it.project $it.id "claude"
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warn2 "  [!]  skipped $($it.id) (local copy vanished)"
            continue
        }
        $text = ConvertTo-ExportMarkdown $it.project $it.id $src
        if ($Html) { $text = ConvertTo-ExportSessionHtml $it.project $it.id $src }
        [System.IO.File]::WriteAllText((Join-Path $out $it.file), $text,
            (New-Object System.Text.UTF8Encoding($false)))
        $count++
    }
    if ($Html -and $All) {
        [System.IO.File]::WriteAllText((Join-Path $out "index.html"),
            (ConvertTo-ExportIndexHtml $items.ToArray()),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    $suffix = ""
    if ($Html -and $All) { $suffix = "  (+ index.html)" }
    Write-Info "exported $count session(s) to $((Resolve-Path -LiteralPath $out).Path)$suffix"
    return 0
}

<# First-run report: what is set up, what is missing, what to run next.
   Non-fatal — every check prints a line and the worst gap decides the
   suggested next step. Same report as Linux cmd_onboard(), with the
   systemd-timer check swapped for the schtasks task. #>
function Invoke-Onboard {
    Write-Info "sessium onboard — setup checklist"
    Write-Info ""
    $nextSteps = New-Object System.Collections.Generic.List[object]

    $version = ""
    try {
        $out = Invoke-Rclone -RcloneArgs @("version") -TimeoutSec 15
        if ("$out") { $version = ("$out" -split "`r?`n")[0] } else { $version = "unknown" }
        Write-Info "[OK] rclone present ($version)"
    } catch {
        Write-FailLine "rclone: $($_.Exception.Message)"
        $nextSteps.Add(@{ what = "install rclone"; cmd = "sessium setup" })
    }

    $cfg = Get-SessiumConfig
    if ($cfg.Remote -eq $script:CryptName) {
        Write-Info "[OK] encryption: on ($($script:CryptName))"
    } else {
        Write-Warn2 "  [!]  encryption: off — Drive copies are plaintext (optional: sessium setup --encrypted)"
    }

    try {
        $null = Invoke-Rclone -RcloneArgs @("lsd", "$($cfg.Remote):") -TimeoutSec 30
        Write-Info "[OK] Drive reachable (remote '$($cfg.Remote)')"
    } catch {
        Write-FailLine "Drive not reachable: $($_.Exception.Message)"
        $nextSteps.Add(@{ what = "authorize rclone"; cmd = "sessium setup" })
    }

    $localMap = Get-LocalSessions "claude"
    $sessionCount = 0
    foreach ($k in $localMap.Keys) { $sessionCount += @($localMap[$k]).Count }
    if ($sessionCount -gt 0) {
        Write-Info "[OK] local repo: $($localMap.Count) project(s), $sessionCount session(s)"
    } else {
        Write-Warn2 "  [!]  no sessions found under $(Join-Path (Get-ClaudeDir) 'projects')"
    }
    $codexMap = Get-LocalSessions "codex"
    $codexCount = 0
    foreach ($k in $codexMap.Keys) { $codexCount += @($codexMap[$k]).Count }
    if ($codexCount -gt 0) {
        Write-Info "[OK] codex repo: $($codexMap.Count) project(s), $codexCount session(s)"
    }

    $ledgerPath = Get-StatePath
    if (Test-Path -LiteralPath $ledgerPath) {
        try {
            $raw = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $n = 0
            $sessions = Get-JsonProp $raw "sessions"
            if ($sessions) { $n = @($sessions.PSObject.Properties).Count }
            Write-Info "[OK] ledger: $n session(s) recorded (has synced at least once)"
        } catch {
            Write-Warn2 "  [!]  ledger unreadable — it will rebuild on next sync"
        }
    } else {
        Write-Warn2 "  [!]  ledger: empty — nothing synced yet (first: sessium push, then sessium sync)"
    }

    # Linux checks for the systemd timer file; the Windows equivalent is the
    # schtasks task. /Query through the same bin (SESSIUM_SCHTASKS_BIN) so the
    # check stays hermetic — any failure to run or rc != 0 means "not installed".
    $timerOk = $false
    try {
        $null = & (Get-SchtasksBin) /Query /TN "sessium-sync" 2>&1
        if ($LASTEXITCODE -eq 0) { $timerOk = $true }
    } catch { }
    if ($timerOk) {
        Write-Info "[OK] sync timer: installed (task 'sessium-sync')"
    } else {
        Write-Warn2 "  [!]  sync timer: not installed — sessium schedule (sync every 30 min)"
        $nextSteps.Add(@{ what = "background sync"; cmd = "sessium schedule" })
    }

    $settingsPath = Join-Path (Get-ClaudeDir) "settings.json"
    $hooked = $false
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            if ((Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8) -match "sessium.*push --quiet") {
                $hooked = $true
            }
        } catch { }
    }
    if ($hooked) {
        Write-Info "[OK] Stop hook: installed (pushes after every session turn)"
    } else {
        Write-Warn2 "  [!]  Stop hook: not installed — sessium hook (auto-push per turn)"
        $nextSteps.Add(@{ what = "auto-push hook"; cmd = "sessium hook" })
    }

    Write-Info ""
    if ($nextSteps.Count -gt 0) {
        Write-Info "suggested next steps:"
        foreach ($s in $nextSteps) {
            Write-Info ("  {0,-24}  # {1}" -f $s.cmd, $s.what)
        }
    } else {
        Write-Info "all set. everyday commands: status / sync / search / open"
    }
    # no man page on Windows; --help is the doc
    Write-Info "help: sessium --help"
    return 0
}

# ---------------------------------------------------------------- dispatch

function Show-Usage {
    Write-Info @"
sessium $script:Version - git for Claude Code and Codex CLI sessions (Drive remote)

usage: sessium <command> [args]

  list [--titles] [--json] [--project <m>]  browse sessions, newest first
  log [<id>]                               list (no id), or a session's history
  status [--json] [--project <m>]          what changed here / there / conflicted
  check [--full]                           self-test; --full also audits the ledger
  setup [--check-only] [--encrypted]       run setup-windows.ps1; --encrypted wraps
                                           the Drive remote in an rclone crypt layer
  schedule [--interval MIN] [--print] [--off]   Task Scheduler task running
                                           `sessium sync` every MIN minutes (default 30)
  hook [--print] [--off]                   wire a Claude Code Stop hook: auto-push
                                           on every session end
  version                                  print the version
  push [--dry-run] [--quiet] [--project <m>]   upload new/changed sessions
  pull [--dry-run] [--quiet] [--project <m>]   download new/changed sessions
  sync [--interactive] [--dry-run] [--quiet] [--project <m>] [--only memory|skills]
                                           push AND pull; decides conflicts
  diff <id> [--messages] [--json]          local vs remote vs last-synced
                                           (--messages: show the conversation divergence)
  search <query> [--project <m>] [--limit N] [--semantic] [--json]
                                           search local transcripts (title > body);
                                           --semantic needs seeker in config.json
  seek [--name NAME]                       register ~/.claude/projects as a seeker source
  resolve <id>                             decide a conflicted session by hand
  revert <id> [--dry-run]                  swap a kept revert copy back in
  checkout <id> <seq> [--dry-run]          restore a history snapshot (see 'log <id>')
  gc [--keep N] [--dry-run]                prune revert/ + history/ beyond N per session
  open <id> [--go] [--adopt] [--dry-run]   print (or run) the claude/codex resume command
  adopt <munged-folder> <repo-path> [--dry-run]
                                           rehome sessions to this machine's path
  export [<id>] [--all] [--html] [--out DIR] [--project <m>]
                                           write sessions out as Markdown or a
                                           static HTML viewer (default ./sessium-export)
  onboard                                  first-run report: what is set up, what
                                           to do next

session ids: a prefix is enough ('sessium diff 9f8e'). Munged project names
always start with '-' (e.g. -C--Users-me-repo) - fine after --project.

--app claude|codex|all on the session commands (list, status, check, push,
pull, sync, diff, resolve, revert, checkout, gc, open, log): which CLI's
sessions this run touches - Claude Code, Codex CLI, or both (default).
export and search read Claude Code transcripts only for now.

--debug/--verbose prints every rclone call. Exit codes: 0 ok (skips are not failures),
1 real failures. (Ctrl+C exits via the PowerShell console itself.)
"@
}

function Invoke-Main([string[]]$CliArgs) {
    # munged names start with '-'; manual parsing takes them as values as-is
    $positional = New-Object System.Collections.Generic.List[string]
    $opt = @{
        project = ""; titles = $false; interactive = $false
        json = $false; dryrun = $false; go = $false; adopt = $false; quiet = $false
        full = $false; messages = $false; semantic = $false
        only = ""; limit = 0; keep = -1; name = ""
        print = $false; off = $false; interval = 0
        all = $false; out = ""; html = $false
        app = "all"
    }
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $a = $CliArgs[$i]
        if ($a -eq "--debug" -or $a -eq "--verbose") { $script:Debug = $true; $i++; continue }
        if ($a -eq "--titles") { $opt.titles = $true; $i++; continue }
        if ($a -eq "--interactive") { $opt.interactive = $true; $i++; continue }
        if ($a -eq "--json") { $opt.json = $true; $i++; continue }
        if ($a -eq "--dry-run") { $opt.dryrun = $true; $i++; continue }
        if ($a -eq "--go") { $opt.go = $true; $i++; continue }
        if ($a -eq "--adopt") { $opt.adopt = $true; $i++; continue }
        if ($a -eq "--quiet") { $opt.quiet = $true; $i++; continue }
        if ($a -eq "--full") { $opt.full = $true; $i++; continue }
        if ($a -eq "--messages") { $opt.messages = $true; $i++; continue }
        if ($a -eq "--semantic") { $opt.semantic = $true; $i++; continue }
        if ($a -eq "--print") { $opt.print = $true; $i++; continue }
        if ($a -eq "--off") { $opt.off = $true; $i++; continue }
        if ($a -eq "--all") { $opt.all = $true; $i++; continue }
        if ($a -eq "--html") { $opt.html = $true; $i++; continue }
        if ($a -like "--out=*") { $opt.out = $a.Substring(6); $i++; continue }
        if ($a -eq "--out" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.out = [string]$CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--interval=*") { $opt.interval = [int]$a.Substring(11); $i++; continue }
        if ($a -eq "--interval" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.interval = [int]$CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--project=*") { $opt.project = $a.Substring(10); $i++; continue }
        if ($a -eq "--project" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.project = $CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--app=*") { $opt.app = $a.Substring(6); $i++; continue }
        if ($a -eq "--app" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.app = $CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--only=*") { $opt.only = $a.Substring(7); $i++; continue }
        if ($a -eq "--only" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.only = $CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--limit=*") { $opt.limit = [int]$a.Substring(8); $i++; continue }
        if ($a -eq "--limit" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.limit = [int]$CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--keep=*") { $opt.keep = [int]$a.Substring(7); $i++; continue }
        if ($a -eq "--keep" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.keep = [int]$CliArgs[$i + 1]; $i += 2; continue
        }
        if ($a -like "--name=*") { $opt.name = $a.Substring(7); $i++; continue }
        if ($a -eq "--name" -and ($i + 1) -lt $CliArgs.Count) {
            $opt.name = $CliArgs[$i + 1]; $i += 2; continue
        }
        $positional.Add($a); $i++
    }
    $cmd = ""
    if ($positional.Count -gt 0) { $cmd = $positional[0]; $positional.RemoveAt(0) }

    switch ($cmd) {
        "list"     { Invoke-ListSessions $opt.project -App $opt.app -Titles:$opt.titles -Json:$opt.json; return 0 }
        "status"   { Invoke-Status $opt.project -App $opt.app -Json:$opt.json; return 0 }
        "check"    { return (Invoke-Check -App $opt.app -Full:$opt.full) }
        "setup"    {
            if ($positional -contains "--encrypted") { return (Invoke-SetupEncrypted) }
            Invoke-Setup @($positional); return 0
        }
        "schedule" {
            $interval = $opt.interval; if ($interval -le 0) { $interval = 30 }
            return (Invoke-Schedule $interval -Off:$opt.off -Print:$opt.print)
        }
        "hook"     { return (Invoke-Hook -Off:$opt.off -Print:$opt.print) }
        "push"     { Invoke-Push $opt.project -App $opt.app -DryRun:$opt.dryrun -Quiet:$opt.quiet; return 0 }
        "pull"     { Invoke-Pull $opt.project -App $opt.app -DryRun:$opt.dryrun -Quiet:$opt.quiet; return 0 }
        "sync"     { Invoke-Sync $opt.project $opt.only -App $opt.app -Interactive:$opt.interactive -DryRun:$opt.dryrun -Quiet:$opt.quiet; return 0 }
        "version"  { return (Invoke-Version) }
        "log" {
            $prefix = ""
            if ($positional.Count -gt 0) { $prefix = $positional[0] }
            return (Invoke-Log $prefix $opt.project -App $opt.app -Titles:$opt.titles -Json:$opt.json)
        }
        "open" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium open <id> [--go] [--adopt]  (prefix ok)" }
            return (Invoke-Open $positional[0] $opt.project -App $opt.app -Go:$opt.go -Adopt:$opt.adopt -DryRun:$opt.dryrun)
        }
        "diff" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium diff <id> [--messages] [--json]  (prefix ok)" }
            Invoke-Diff $positional[0] $opt.project -App $opt.app -Json:$opt.json -Messages:$opt.messages; return 0
        }
        "resolve" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium resolve <id>  (prefix ok)" }
            Invoke-Resolve $positional[0] -Interactive:$opt.interactive -Project $opt.project -App $opt.app
            return 0
        }
        "revert" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium revert <id>  (prefix ok)" }
            return (Invoke-Revert $positional[0] -App $opt.app -DryRun:$opt.dryrun)
        }
        "checkout" {
            if ($positional.Count -lt 2) { Write-Fail "usage: sessium checkout <id> <seq>  (prefix ok)" }
            return (Invoke-Checkout $positional[0] ([int]$positional[1]) -App $opt.app -DryRun:$opt.dryrun)
        }
        "gc" {
            $keep = $opt.keep; if ($keep -lt 0) { $keep = 10 }
            return (Invoke-Gc -Keep $keep -App $opt.app -DryRun:$opt.dryrun)
        }
        "search" {
            if ($positional.Count -lt 1) { Write-Fail "usage: sessium search <query> [--project <m>] [--limit N] [--semantic] [--json]" }
            $limit = $opt.limit; if ($limit -le 0) { $limit = $script:DefaultSearchLimit }
            return (Invoke-Search $positional[0] $opt.project $limit -App $opt.app -Semantic:$opt.semantic -Json:$opt.json)
        }
        "seek" {
            return (Invoke-Seek $opt.name)
        }
        "export" {
            return (Invoke-Export $positional[0] $opt.out $opt.project -App $opt.app -All:$opt.all -Html:$opt.html)
        }
        "onboard" {
            return (Invoke-Onboard)
        }
        "adopt" {
            if ($positional.Count -lt 2) {
                Write-Fail "usage: sessium adopt <munged-folder> <repo-path>"
            }
            return (Invoke-Adopt $positional[0] $positional[1] -DryRun:$opt.dryrun)
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
