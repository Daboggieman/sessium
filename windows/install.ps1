# install.ps1 - install sessium on Windows (Phase 4).
# Copies sessium.ps1 + sessium.cmd to %USERPROFILE%\sessium and adds that
# folder to the user PATH. Nothing admin-required, nothing removed.
#
# Run:  powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = "Stop"

$srcDir = $PSScriptRoot
$destDir = Join-Path $env:USERPROFILE "sessium"

if (-not (Test-Path (Join-Path $srcDir "sessium.ps1"))) {
    Write-Host "[X]  run this from the repo's windows\ folder (sessium.ps1 not found next to install.ps1)" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
Copy-Item (Join-Path $srcDir "sessium.ps1") $destDir -Force
Copy-Item (Join-Path $srcDir "sessium.cmd") $destDir -Force
Write-Host "installed: $destDir\sessium.ps1 (+ .cmd shim)"

# add to the user PATH if not already there
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
if (($userPath -split ";") -notcontains $destDir) {
    [Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(";") + ";" + $destDir), "User")
    Write-Host "PATH updated (new terminals will see 'sessium')"
} else {
    Write-Host "PATH already contains $destDir"
}

# dependency sanity
$rclone = Get-Command rclone -ErrorAction SilentlyContinue
if ($rclone) {
    Write-Host "rclone: $($rclone.Source)"
} else {
    Write-Host "NOTE: rclone not found - run setup-windows.ps1 first" -ForegroundColor Yellow
}

Write-Host "next: sessium status   (or .\setup-windows.ps1 for first-time Drive setup)"
