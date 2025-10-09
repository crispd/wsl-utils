<#  Backup-WSL.ps1
    DESCRIPTION:
    Export a WSL distro to a .tar (default) or .vhd backup.
    - If -DistroName is omitted or invalid, show `wsl -l -v` and prompt.
    - If the distro is running, offer to terminate it first.
    - Exports to $env:USERPROFILE\WSL\backups\<Name>-YYYY-MM-DD_HHMMSS.tar by default.

    USAGE:
        .\Backup-WSL.ps1
        .\Backup-WSL.ps1 -DistroName Ubuntu-20.04
        .\Backup-WSL.ps1 -DistroName Debian -Format vhd -ComputeHash

    TODO: Add compression option?
    TODO: Add -PreClean option that briefly launches the distro to kill common agents and remove their sockets before export?
#>


[CmdletBinding()]
param(
  [string]$DistroName,
  [string]$OutputDir = (Join-Path $env:USERPROFILE 'WSL\backups'),
  [ValidateSet('tar','vhd')][string]$Format = 'tar',
  [switch]$ComputeHash,
  [switch]$PreClean,
  [int]$KeepLast = 1
)

# Robust import of wsl-utils (bootstrap or repo layout)
$imported = $false
try {
    Import-Module 'wsl-utils' -Force -ErrorAction Stop   # works after bootstrap (in PSModulePath)
    $imported = $true
} catch {}

if (-not $imported) {
    $candidates = @(
        Join-Path $PSScriptRoot 'wsl-utils.psm1'                                   # old same-folder layout
        Join-Path $PSScriptRoot 'wsl-utils\wsl-utils.psm1'                         # module-style under scripts
        Join-Path $env:USERPROFILE 'WSL\modules\wsl-utils\wsl-utils.psm1'          # bootstrap layout
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

# 1) Pick distro (prompt if needed)
$d = Select-WslDistro -Name $DistroName

# --- 1b. Optional pre-clean ---
if ($PreClean) {
    Write-Host "==> Pre-cleaning '$($d.Name)'" -ForegroundColor Green
    $pre = @'
set -e
sudo -n true 2>/dev/null || exit 0
sudo dnf -y clean all 2>/dev/null || true
sudo rm -rf /var/log/journal/*/* 2>/dev/null || true
sudo find /var/log -type f -name "*.log" -size +0 -exec sh -c '> "{}"' \; 2>/dev/null || true
rm -rf ~/.cache/* 2>/dev/null || true
'@
    $pre | wsl -d $d.Name -- bash -lc 'cat > /tmp/preclean.sh && bash /tmp/preclean.sh'
    wsl --terminate $d.Name
}


# 2) If running, offer to terminate
if ($d.State -eq 'Running') {
  if (Confirm-YesNo "Distro '$($d.Name)' is Running. Terminate it now?" $true) {
    wsl --terminate $d.Name | Out-Null
    Start-Sleep -Seconds 1
  } else {
    throw "Backup requires the distro to be stopped. Aborting."
  }
}

# 3) Ensure output dir exists
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# 4) Compose backup path
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$ext = if ($Format -eq 'vhd') { 'vhd' } else { 'tar' }
$backupPath = Join-Path $OutputDir ("{0}-{1}.{2}" -f $d.Name, $timestamp, $ext)

Write-Host "==> Exporting '$($d.Name)' to:`n    $backupPath" -ForegroundColor Green

# 5) Export (pax warnings on .tar are normal)
if ($Format -eq 'vhd') {
  try {
    wsl --export $d.Name $backupPath --format vhd
  } catch {
    Write-Warning "VHD export not supported on this WSL. Falling back to .tar."
    $backupPath = [System.IO.Path]::ChangeExtension($backupPath, '.tar')
    wsl --export $d.Name $backupPath
  }
} else {
  wsl --export $d.Name $backupPath
}

# After successful export, optionally clean up old backups
if ($KeepLast -gt 0) {
    Write-Host "==> Keeping last $KeepLast backups for $($d.Name)"
    $pattern = Join-Path $OutputDir ("{0}-*.{1}" -f $d.Name, $ext)
    Get-ChildItem $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLast |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "==> Export complete." -ForegroundColor Green
Get-Item $backupPath | Format-List Name,FullName,Length,LastWriteTime

if ($ComputeHash) {
  Write-Host "==> Computing SHA256..." -ForegroundColor Green
  Get-FileHash -Algorithm SHA256 -Path $backupPath
}

Write-Host "Backup-WSL.ps1: Done." -ForegroundColor Green
