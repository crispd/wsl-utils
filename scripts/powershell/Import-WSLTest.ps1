<# Import-WSLTest.ps1 — import a .tar/.vhd/.vhdx backup as a new TEST distro.
   - Prompts for backup (defaults to $env:USERPROFILE\WSL\backups; supports -Recurse)
   - Imports .tar/.vhd/.vhdx (vhdx: copy + --import-in-place to keep backup immutable)
   - Sets default user via repo script scripts/bash/set-default-user.sh
   - Enables lingering, restarts, verifies with whoami
#>

[CmdletBinding()]
param(
  [Alias('TarPath')][string]$BackupPath,
  [Alias('NewDistroName')][string]$DistroName,
  [Alias('InstallLocation')][string]$InstallDir,
  [Alias('DefaultUserName')][string]$DefaultUser,
  [string]$SearchDir = (Join-Path $env:USERPROFILE 'WSL\backups'),
  [switch]$Recurse
)

# Robust import of wsl-utils (bootstrap or repo layout)
$imported = $false
try {
    Import-Module 'wsl-utils' -Force -ErrorAction Stop   # works after bootstrap (in PSModulePath)
    $imported = $true
} catch {}

if (-not $imported) {
    $candidates = @(
        Join-Path $PSScriptRoot 'wsl-utils.psm1',                                   # old same-folder layout
        Join-Path $PSScriptRoot 'wsl-utils\wsl-utils.psm1',                         # module-style under scripts
        Join-Path $env:USERPROFILE 'WSL\modules\wsl-utils\wsl-utils.psm1'            # bootstrap layout
    ) | Where-Object { Test-Path $_ }

    if ($candidates.Count -gt 0) {
        Import-Module $candidates[0] -Force
        $imported = $true
    }
}

if (-not $imported) {
    throw "Unable to load 'wsl-utils'. Ensure bootstrap installed it or adjust PSModulePath."
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BackupCandidates {
  param([Parameter(Mandatory)][string]$Dir, [switch]$Recurse)
  $paths = @(
    (Join-Path $Dir '*.tar'),
    (Join-Path $Dir '*.vhd'),
    (Join-Path $Dir '*.vhdx')
  )
  $gci = @{ Path = $paths; File = $true; ErrorAction = 'SilentlyContinue' }
  if ($Recurse) { $gci.Recurse = $true }
  Get-ChildItem @gci | Sort-Object LastWriteTime -Descending
}

# 1) Choose backup
if (-not $BackupPath) {
  Write-Host "Looking for backups under: $SearchDir" -ForegroundColor Cyan

  $files = if (Test-Path $SearchDir) {
    @( Get-BackupCandidates -Dir $SearchDir -Recurse:$Recurse )
  } else {
    @()
  }

  if (@($files).Count -gt 0) {
    Write-Host "Recent backups:" -ForegroundColor Cyan
    $i=1; foreach ($f in $files | Select-Object -First 15) {
      Write-Host ("[{0}] {1} ({2:n0} bytes)  {3}" -f $i, $f.FullName, $f.Length, $f.LastWriteTime)
      $i++
    }
    Write-Host ""
    $sel = Read-Host "Enter NUMBER to select, or type a full path (Enter to pick [1])"
    if ([string]::IsNullOrWhiteSpace($sel)) { $sel = '1' }
    if ($sel -match '^\d+$') {
      $idx = [int]$sel
      if ($idx -lt 1 -or $idx -gt [Math]::Min(15, @($files).Count)) {
        throw "Invalid selection index: $idx"
      }
      $BackupPath = $files[$idx-1].FullName
    } else {
      $BackupPath = $sel.Trim()
    }
  } else {
    if (Test-Path $SearchDir) {
      Write-Warning "No .tar/.vhd/.vhdx files found in $SearchDir."
    } else {
      Write-Warning "Backup folder does not exist: $SearchDir"
    }

    $BackupPath = Read-Host "Enter path to backup (.tar, .vhd, or .vhdx)"
  }
}

# 2) Normalize & classify
try { $BackupPath = (Resolve-Path $BackupPath).Path } catch { throw "Backup not found: $BackupPath" }
if (-not (Test-Path $BackupPath)) { throw "Backup not found: $BackupPath" }

$lower  = $BackupPath.ToLowerInvariant()
$IsTar  = $lower.EndsWith('.tar')
$IsVhd  = $lower.EndsWith('.vhd')
$IsVhdx = $lower.EndsWith('.vhdx')
if (-not ($IsTar -or $IsVhd -or $IsVhdx)) { throw "Unsupported backup extension. Use .tar, .vhd, or .vhdx." }
Write-Host "  Using: $BackupPath" -ForegroundColor DarkGray

# 3) Name + install folder
if (-not $DistroName) {
  $base = Split-Path $BackupPath -LeafBase
  if ($base -match '^(?<n>.+?)(-\d{4}-\d{2}-\d{2}(_\d{6})?)$') { $base = $Matches.n }
  $DistroName = Get-UniqueName -Base "$base-test"
}
$DistroName = Get-UserInput -Prompt "New distro name (Enter for default)" -Default $DistroName
Write-Host "  Using: $DistroName" -ForegroundColor DarkGray

if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE ("WSL\" + $DistroName) }
Write-Host ""
$InstallDir = Get-UserInput -Prompt "Install folder (new or empty)" -Default $InstallDir
if (Test-Path $InstallDir) {
  if ((Get-ChildItem -Force -ErrorAction SilentlyContinue $InstallDir | Measure-Object).Count -gt 0) { throw "Install folder is not empty: $InstallDir" }
} else {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}
Write-Host "  Using: $InstallDir" -ForegroundColor DarkGray


# 4) Import
Write-Host "==> Importing '$BackupPath' as '$DistroName' into '$InstallDir'..." -ForegroundColor Green
if ($IsVhdx) {
  $destVhdx = Join-Path $InstallDir 'ext4.vhdx'
  Copy-Item -Path $BackupPath -Destination $destVhdx -Force
  wsl --import-in-place $DistroName $destVhdx
} elseif ($IsVhd) {
  wsl --import $DistroName $InstallDir $BackupPath --vhd
} else {
  wsl --import $DistroName $InstallDir $BackupPath --version 2
}
Write-Host "The operation completed successfully." -ForegroundColor DarkGreen

# 5) Default user
if (-not $DefaultUser) {
  $DefaultUser = Read-Host "Default username to set (press Enter for root)"
  if ([string]::IsNullOrWhiteSpace($DefaultUser)) { $DefaultUser = 'root' }
}

# 6) Run the repo Bash helper inside WSL to set default user
Write-Host "==> Setting default user inside '$DistroName'..." -ForegroundColor Green

# Find set-default-user.sh in several candidate locations; if missing, emit a fallback copy
# TODO: This is dumb. It introduces a bash payload that helps find another bash script. Need to revisit the way powershell scripts are organized in repo and found by eachother...
$candidates = @(
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'bash\set-default-user.sh'),
    (Join-Path $PSScriptRoot 'set-default-user.sh'),
    (Join-Path $PSScriptRoot 'linux\set-default-user.sh'),
    (Join-Path $env:USERPROFILE 'WSL\scripts\set-default-user.sh'),
    (Join-Path $env:USERPROFILE 'WSL\scripts\bash\set-default-user.sh'),
    (Join-Path $env:USERPROFILE 'WSL\\scripts\\bash\\set-default-user.sh')
) | Where-Object { Test-Path -LiteralPath $_ }

if ($candidates.Count -eq 0) {
    $fallbackTarget = Join-Path $env:USERPROFILE 'WSL\\scripts\\bash\\set-default-user.sh'
    $fallbackDir = Split-Path -Parent $fallbackTarget
    if (-not (Test-Path -LiteralPath $fallbackDir)) { New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null }

    # Minimal, conservative helper: ensures user exists and sets /etc/wsl.conf default user
    $fallbackContent = @'
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
  echo "Usage: set-default-user.sh <username>" >&2
  exit 2
fi

if ! id "$USER_NAME" >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "$USER_NAME"
  else
    echo "useradd not available; cannot create user \"$USER_NAME\"." >&2
    exit 1
  fi
fi

if getent group wheel >/dev/null 2>&1; then
  sudo usermod -aG wheel "$USER_NAME" || true
elif getent group sudo >/dev/null 2>&1; then
  sudo usermod -aG sudo "$USER_NAME" || true
fi

TMP="$(mktemp)"
if [[ -f /etc/wsl.conf ]]; then
  sudo cp /etc/wsl.conf "$TMP"
fi
awk -v u="$USER_NAME" '
BEGIN{printed=0}
/^\[user\]\s*$/ {print; print "default=" u; skip=1; printed=1; next}
/^\[/ {print; skip=0; next}
{ if (!skip) print }
END{ if (!printed) { print "[user]"; print "default=" u } }
' "$TMP" 2>/dev/null | sudo tee /etc/wsl.conf >/dev/null || echo -e "[user]\ndefault=$USER_NAME" | sudo tee /etc/wsl.conf >/dev/null

echo "default user set to: $USER_NAME"
'@

    Set-Content -LiteralPath $fallbackTarget -Value $fallbackContent -Encoding UTF8 -NoNewline
    $ShPath = $fallbackTarget
    Write-Host "  - Emitted fallback: $fallbackTarget"
} else {
    $ShPath = $candidates[0]
    Write-Host "  - Using helper: $ShPath"
}


# Read the helper script and normalize to LF
$Payload = (Get-Content -Raw -Encoding UTF8 $ShPath) -replace "`r`n","`n"

# Run the script inside WSL; pass the username as a separate argv
# Capture output to a log file
$logDir = Join-Path $env:USERPROFILE 'WSL\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $env:USERPROFILE 'WSL\logs\Import-WSLTest.log'
if (Test-Path $log) { Remove-Item -Force $log } # Guard against appending to old log
Write-Host "Log file: $log" -ForegroundColor DarkGray

# run the WSL step, capture exit code, and write/echo output
$out  = $Payload | wsl -d $DistroName -u root -- bash -s -- $DefaultUser 2>&1
$code = $LASTEXITCODE
$out | Tee-Object -FilePath $log | Write-Host
if ($code -ne 0) { throw "set-default-user.sh failed with exit code $code" }

# 7) Restart & verify
wsl --terminate $DistroName
$who = wsl -d $DistroName -- sh -lc 'whoami' 2>$null
$state = wsl -l -v | Select-String -SimpleMatch " $DistroName " | ForEach-Object { $_.ToString() }
$state | Tee-Object -FilePath $log | Write-Host

Write-Host "=> Default user now: $who"
# optional: quick systemd + automount probe
$probe = wsl -d $DistroName -- sh -lc 'systemctl is-system-running 2>/dev/null || true; stat -c %n /mnt/c >/dev/null 2>&1 && echo "mnt/c OK" || echo "mnt/c not mounted"'
Write-Host $probe

# 8) Finish
Write-Host "==> Import complete." -ForegroundColor Green
Write-Host "Launch test distro:" -ForegroundColor Cyan
Write-Host "  wsl -d $DistroName"
Write-Host "Default user set to: $DefaultUser"
Write-Host "Install folder: $InstallDir"
Write-Host "To remove the test distro: wsl --unregister $DistroName"
Write-Host ""  # blank line
Write-Host "Import-WSLTest.ps1: Done." -ForegroundColor Green



