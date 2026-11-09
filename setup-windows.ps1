<#
.SYNOPSIS
  Interactive rclone + Google Drive setup for Claude Code backups (Windows).

.DESCRIPTION
  Installs rclone if missing (winget, or direct download to LOCALAPPDATA),
  asks for + validates the remote name and Drive folder, runs the Google
  OAuth browser flow via 'rclone authorize', writes the remote into rclone's
  config file, then auto-tests: reach Drive, create folder, upload/read/
  delete round-trip.

.USAGE
  powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
  powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -CheckOnly

.NOTES
  Targets Windows PowerShell 5.1 (ships with Windows) and pwsh 7+.
#>
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Continue'

function Ok([string]$m)   { Write-Host "[OK]  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!]   $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "[X]   $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------- locate or install rclone
function Install-Rclone {
  Write-Host "rclone is not installed. Trying winget..."
  & winget install --id Rclone.Rclone -e --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -eq 0) {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Warn "winget reported success but rclone is not on PATH in this session - falling back to direct download."
  } else {
    Warn "winget unavailable or failed - downloading rclone directly."
  }

  $dir = Join-Path $env:LOCALAPPDATA 'rclone'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $zip = Join-Path $env:TEMP 'rclone-current-windows-amd64.zip'
  $tmp = Join-Path $env:TEMP ('rclone-extract-' + [guid]::NewGuid().ToString('N'))
  Invoke-WebRequest -Uri 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $exe = Get-ChildItem -Path $tmp -Filter 'rclone.exe' -Recurse | Select-Object -First 1
  if (-not $exe) { Die "downloaded zip did not contain rclone.exe" }
  Copy-Item $exe.FullName (Join-Path $dir 'rclone.exe') -Force
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (($userPath -split ';') -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $dir), 'User')
    Warn "added $dir to your user PATH - new terminals will see rclone (this session uses the full path)."
  }
  return (Join-Path $dir 'rclone.exe')
}

$rcloneExe = $null
$cmd = Get-Command rclone -ErrorAction SilentlyContinue
if ($cmd) { $rcloneExe = $cmd.Source }
elseif (Test-Path (Join-Path $env:LOCALAPPDATA 'rclone\rclone.exe')) {
  $rcloneExe = Join-Path $env:LOCALAPPDATA 'rclone\rclone.exe'
}
else { $rcloneExe = Install-Rclone }

$version = (& $rcloneExe version | Select-Object -First 1)
Ok "rclone found: $version"

$configFile = (& $rcloneExe config file | Select-Object -Last 1).Trim()

# ------------------------------------------------------------ prompt helper
function Ask([string]$q, [string]$def, [string]$regex, [string]$err) {
  while ($true) {
    $v = Read-Host "$q [$def]"
    if (-not $v) { $v = $def }
    if ($v -match $regex) { return $v }
    Warn "$err - try again"
  }
}

function Remote-Exists([string]$name) {
  $list = (& $rcloneExe listremotes 2>$null) -replace ':$', ''
  return ($list -contains $name)
}

# ----------------------------------------------------------- test function
function Run-Tests([string]$R, [string]$F) {
  $passed = 0
  $tmp = Join-Path $env:TEMP ('claude-drive-test-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $tf = Join-Path $tmp 'testfile.txt'
  Set-Content -Path $tf -Value 'claude-drive-setup connectivity test'

  Write-Host "-- Test 1: reach Google Drive root (lsd ${R}:)"
  & $rcloneExe lsd "${R}:" *> $null
  if ($LASTEXITCODE -eq 0) { Ok "Drive root reachable (token works)"; $passed++ }
  else { Warn "could not list Drive root" }

  Write-Host "-- Test 2: backup folder exists / can be created (${R}:$F)"
  & $rcloneExe mkdir "${R}:$F" *> $null
  if ($LASTEXITCODE -eq 0) { Ok "folder ready"; $passed++ }
  else { Warn "mkdir failed" }

  Write-Host "-- Test 3: upload - read back - delete round-trip"
  & $rcloneExe copy $tf "${R}:$F/_connectivity-test" *> $null
  $up = ($LASTEXITCODE -eq 0)
  $back = $false
  if ($up) {
    $content = (& $rcloneExe cat "${R}:$F/_connectivity-test/testfile.txt" 2>$null) -join ''
    $back = ($content -match 'connectivity test')
  }
  & $rcloneExe deletefile "${R}:$F/_connectivity-test/testfile.txt" *> $null
  & $rcloneExe rmdir "${R}:$F/_connectivity-test" *> $null
  if ($up -and $back) { Ok "upload, read back and delete all work"; $passed++ }
  else { Warn "round-trip failed (uploaded: $up, read back: $back)" }

  Write-Host "-- Test 4: account quota visible (about ${R}:) - non-fatal"
  $about = (& $rcloneExe about "${R}:" 2>$null) -join ' '
  if ($about -match 'Total:') { Ok "quota visible: $about"; $passed++ }
  else { Warn "about unavailable (harmless with some Drive configs)" }

  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($passed -lt 3) { Die "mandatory tests failed - see messages above" }
  Ok "All tests passed - remote '$R' is ready for use"
}

# ------------------------------------------------------ defaults from config
$defRemote = 'gdrive'
$defFolder = 'claude-backup'
$dsConfig = Join-Path $env:USERPROFILE 'sessium\config.sh'
if (Test-Path $dsConfig) {
  Get-Content $dsConfig | ForEach-Object {
    if ($_ -match '^DRIVE_REMOTE="([^"]*)"') { $defRemote = $Matches[1] }
    if ($_ -match '^DRIVE_DIR="([^"]*)"')    { $defFolder = $Matches[1] }
  }
}

# --------------------------------------------------------- check-only mode
if ($CheckOnly) {
  if (-not (Remote-Exists $defRemote)) { Die "remote '$defRemote' is not configured yet - run without -CheckOnly" }
  Run-Tests $defRemote $defFolder
  exit 0
}

# ------------------------------------------------------------- user input
$remote = Ask 'Remote name for Google Drive' $defRemote `
  '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$' `
  'remote names may contain letters, digits, dashes, underscores (max 32 chars)'
$folder = Ask 'Folder on your Drive for backups' $defFolder `
  '^[^/\\:*?"<>|]{1,100}$' `
  'folder name cannot contain any of: / \ : * ? " < > |'

if (Remote-Exists $remote) {
  $yn = Read-Host "Remote '$remote' already exists. Reconfigure (re-authorize) it? [y/N]"
  if ($yn -match '^[yY]') {
    & $rcloneExe config delete $remote *> $null
    Ok "removed old remote '$remote'"
  } else {
    Ok "keeping existing remote - running tests only"
    Run-Tests $remote $folder
    Write-Host "Next step: run your backup/push script."
    exit 0
  }
}

# ---------------------------------------------- OAuth via rclone authorize
Write-Host ""
Write-Host "A browser window will open now - sign in to your Google account and click Allow."
Write-Host "When it succeeds, rclone prints a result JSON in this terminal."
Write-Host ""

$line = $null
$output = (& $rcloneExe authorize drive 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0 -and $output) {
  $line = ($output -split "`r?`n" | Where-Object { $_.TrimStart() -match '^\{' } | Select-Object -Last 1)
}
if (-not $line) {
  Warn "could not capture the result automatically (no browser opened, or you cancelled)."
  Write-Host "If rclone printed a URL above, open it manually, then paste the result JSON here."
  $line = Read-Host 'Paste the JSON (starts with {)'
}
$line = $line.Trim().Trim('"')
$tokenOk = $false
try {
  $tok = $line | ConvertFrom-Json
  if ($tok.access_token) { $tokenOk = $true }
} catch { }
if (-not $tokenOk) { Die "that does not look like a valid rclone token JSON - setup aborted." }
if (-not $tok.refresh_token) {
  Warn "no refresh_token in the result - the token may stop working in about an hour; rerun setup if Drive access fails later."
}
Ok "token captured and validated"

# -------------------------------------------------------- write the remote
$configDir = Split-Path $configFile -Parent
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }
if (-not (Test-Path $configFile)) { New-Item -ItemType File -Force -Path $configFile | Out-Null }

& $rcloneExe config delete $remote *> $null
Add-Content -Path $configFile -Value ""
Add-Content -Path $configFile -Value "[$remote]"
Add-Content -Path $configFile -Value "type = drive"
Add-Content -Path $configFile -Value "token = $line"
Ok "remote '$remote' written to $configFile"

# ------------------------------------------------------------ auto-test
Run-Tests $remote $folder

Write-Host ""
Write-Host "Setup complete. Verify anytime with:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -CheckOnly"
