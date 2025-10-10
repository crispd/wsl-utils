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
        .\Backup-WSL.ps1 -DistroName Debian -Output C:\Backups\Debian.tar

    TODO: Add compression option?
#>


[CmdletBinding()]
param(
  [string]$DistroName,
  [string]$OutputDir = (Join-Path $env:USERPROFILE 'WSL\backups'),
  [string]$Output,
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
        Join-Path $PSScriptRoot 'wsl-utils\wsl-utils.psm1'                        # module-style under scripts
        Join-Path $env:USERPROFILE 'WSL\modules\wsl-utils\wsl-utils.psm1'       # bootstrap layout
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

function Get-FirstExistingPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string[]]$Candidates)

  foreach ($candidate in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop
      return $resolved.Path
    } catch {}
  }
  return $null
}

# 1) Pick distro (prompt if needed)
$d = Select-WslDistro -Name $DistroName

# --- 1b. Optional pre-clean ---
if ($PreClean) {
  Write-Host "==> Pre-cleaning '$($d.Name)'" -ForegroundColor Green
  $preCleanCandidates = @(
    Join-Path (Split-Path $PSScriptRoot -Parent) 'bash\pre-export-clean.sh',
    Join-Path $PSScriptRoot 'pre-export-clean.sh',
    Join-Path $env:USERPROFILE 'WSL\scripts\pre-export-clean.sh',
    Join-Path $env:USERPROFILE 'WSL\scripts\bash\pre-export-clean.sh'
  )
  $preCleanScript = Get-FirstExistingPath -Candidates $preCleanCandidates

  try {
    if ($preCleanScript) {
      Write-Host "  using: $preCleanScript" -ForegroundColor DarkGray
      $payload = (Get-Content -LiteralPath $preCleanScript -Raw -Encoding UTF8) -replace "`r`n","`n"
      $payload | wsl -d $d.Name -- bash -s --
    } else {
      Write-Host "  using inline cleanup commands (pre-export script not found)" -ForegroundColor DarkGray
      $fallback = @"
set -e
sudo -n true 2>/dev/null || exit 0
sudo dnf -y clean all 2>/dev/null || true
sudo rm -rf /var/log/journal/*/* 2>/dev/null || true
sudo find /var/log -type f -name "*.log" -size +0 -exec sh -c '> "{}"' \; 2>/dev/null || true
rm -rf ~/.cache/* 2>/dev/null || true
"@
      $fallback | wsl -d $d.Name -- bash -s --
    }

    $preCleanExit = $LASTEXITCODE
    if ($preCleanExit -ne 0) {
      throw "Pre-clean failed with exit code $preCleanExit"
    }
  }
  finally {
    try { wsl --terminate $d.Name | Out-Null } catch {}
  }
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

# 3) Determine output location
$requestedFormat = $Format
$customOutput    = -not [string]::IsNullOrWhiteSpace($Output)
$ext             = if ($requestedFormat -eq 'vhd') { 'vhd' } else { 'tar' }
$backupPath      = $null
$resolvedOutputDir = $OutputDir

if ($customOutput) {
  $currentDir = (Get-Location).Path
  if ([IO.Path]::IsPathRooted($Output)) {
    $backupPath = [IO.Path]::GetFullPath($Output)
  } else {
    $backupPath = [IO.Path]::GetFullPath((Join-Path $currentDir $Output))
  }

  $resolvedOutputDir = Split-Path -Parent $backupPath
  if (-not $resolvedOutputDir) { $resolvedOutputDir = $currentDir }
  New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

  $extFromOutput = ([IO.Path]::GetExtension($backupPath)).TrimStart('.').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($extFromOutput)) {
    $backupPath = [IO.Path]::ChangeExtension($backupPath, ".{0}" -f $ext)
  } elseif ($extFromOutput -in @('tar','vhd')) {
    if ($extFromOutput -ne $ext) {
      Write-Warning "Output extension '.$extFromOutput' does not match -Format '$requestedFormat'. Using '.$extFromOutput'."
    }
    $ext    = $extFromOutput
    $Format = ($ext -eq 'vhd') ? 'vhd' : 'tar'
  } else {
    throw "Unsupported output extension '$extFromOutput'. Use .tar or .vhd."
  }
} else {
  New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null
  $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
  $backupPath = Join-Path $resolvedOutputDir ("{0}-{1}.{2}" -f $d.Name, $timestamp, $ext)
}

$OutputDir = $resolvedOutputDir

Write-Host "==> Exporting '$($d.Name)' to:`n    $backupPath" -ForegroundColor Green

# 4) Export (pax warnings on .tar are normal)
if ($Format -eq 'vhd') {
  try {
    wsl --export $d.Name $backupPath --format vhd
  } catch {
    Write-Warning "VHD export not supported on this WSL. Falling back to .tar."
    $ext     = 'tar'
    $Format  = 'tar'
    $newPath = [IO.Path]::ChangeExtension($backupPath, '.tar')
    if ($newPath -and $newPath -ne $backupPath) {
      Write-Host "    -> using: $newPath" -ForegroundColor DarkGray
      $backupPath = $newPath
    }
    wsl --export $d.Name $backupPath
  }
} else {
  wsl --export $d.Name $backupPath
}

# After successful export, optionally clean up old backups (only for generated names)
if (-not $customOutput -and $KeepLast -gt 0) {
    Write-Host "==> Keeping last $KeepLast backups for $($d.Name)"
    $pattern = Join-Path $OutputDir ("{0}-*.{1}" -f $d.Name, $ext)
    Get-ChildItem $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLast |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "==> Export complete." -ForegroundColor Green
Get-Item -LiteralPath $backupPath | Format-List Name,FullName,Length,LastWriteTime

if ($ComputeHash) {
  Write-Host "==> Computing SHA256..." -ForegroundColor Green
  Get-FileHash -Algorithm SHA256 -Path $backupPath
}

Write-Host "Backup-WSL.ps1: Done." -ForegroundColor Green
