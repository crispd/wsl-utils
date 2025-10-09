<#PSScriptInfo
.VERSION 1.3.1
.GUID 6b061b4e-0f55-4d66-9a41-6b6a4c8c9a8d
.AUTHOR crispd
#>

<#
.SYNOPSIS
  Installs or uninstalls dev-env WSL helper files and PATH entries under %USERPROFILE%\WSL.

.DESCRIPTION
  - Default action (no switch): Ensure the folder structure exists, add %USERPROFILE%\WSL\scripts to the user PATH,
    and fetch helper scripts from the GitHub repo (main branch).
  - -Uninstall: Remove PATH entry, migrate backups to %USERPROFILE%\backups, and delete %USERPROFILE%\WSL
               (robustly; if locked, stash and schedule a one-time cleanup on next sign-in).

.EXAMPLE
  Install:
    powershell -NoProfile -ExecutionPolicy Bypass -Command " & { $(irm https://raw.githubusercontent.com/crispd/dev-env/main/scripts/bootstrap.ps1) } "

  Uninstall:
    powershell -NoProfile -ExecutionPolicy Bypass -Command " & { $(irm https://raw.githubusercontent.com/crispd/dev-env/main/scripts/bootstrap.ps1) } -Uninstall "
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Alias('u')]
  [switch]$Uninstall
)

# -----------------------------
# Constants / paths
# -----------------------------
$InstallRoot     = Join-Path $env:USERPROFILE 'WSL'
$ScriptsDir      = Join-Path $InstallRoot    'scripts'
$ModulesRoot     = Join-Path $InstallRoot    'modules'
$LegacyBackups   = Join-Path $InstallRoot    'backups'
$BackupsRoot     = Join-Path $env:USERPROFILE 'backups'
$PathSep         = [IO.Path]::PathSeparator

# Repo download
$RepoOwner       = 'crispd'
$RepoName        = 'dev-env'
$RepoZipUri      = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/main.zip"
$ZipBaseName     = "$RepoName-main"

# -----------------------------
# Helpers (approved verbs)
# -----------------------------

function Show-InfoMessage {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host "  - $Message"
}

function Show-HeaderMessage {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Show-TipMessage {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host "Tip: $Message" -ForegroundColor DarkGray
}

function New-DirectoryIfMissing {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Get-UserPath {
  [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPath {
  param([Parameter(Mandatory)][string]$Value)
  [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

function Test-UserPathContains {
  param([Parameter(Mandatory)][string]$Directory)
  $segments = (Get-UserPath) -split [regex]::Escape($PathSep)
  $segments -contains ([IO.Path]::GetFullPath($Directory))
}

function Add-UserPathEntry {
  param([Parameter(Mandatory)][string]$Directory)
  $dir = [IO.Path]::GetFullPath($Directory)
  if (Test-UserPathContains -Directory $dir) { return $false }
  $old = Get-UserPath
  $new = if ([string]::IsNullOrWhiteSpace($old)) { $dir } else { "$old$PathSep$dir" }
  Set-UserPath -Value $new
  return $true
}

function Remove-UserPathEntry {
  param([Parameter(Mandatory)][string]$Directory)
  $dirFull = [IO.Path]::GetFullPath($Directory)
  $segments = (Get-UserPath) -split [regex]::Escape($PathSep) | Where-Object { $_ -and ($_ -ne $dirFull) }
  Set-UserPath -Value ($segments -join $PathSep)
}

function Move-LegacyBackups {
  if (Test-Path -LiteralPath $LegacyBackups) {
    New-DirectoryIfMissing -Path $BackupsRoot
    Show-InfoMessage -Message "Found legacy backups at $LegacyBackups; migrating to $BackupsRoot"
    try {
      Move-Item -LiteralPath $LegacyBackups -Destination $BackupsRoot -Force -ErrorAction Stop
    } catch {
      # Merge contents if destination exists
      Get-ChildItem -LiteralPath $LegacyBackups -Force | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $BackupsRoot -Force
      }
      Remove-Item -LiteralPath $LegacyBackups -Force -Recurse -ErrorAction SilentlyContinue
    }
  }
}

function Install-FetchScripts {
  <#
    Downloads the repo ZIP and installs any *.ps1 from:
      - scripts\wsl\   (preferred)
      - scripts\       (fallback)
    into $ScriptsDir. Files are unblocked.
  #>
  param()

  New-DirectoryIfMissing -Path $ScriptsDir

  $tmpZip   = Join-Path ([IO.Path]::GetTempPath()) ("$RepoName-main-" + [Guid]::NewGuid().ToString('N') + ".zip")
  $tmpDir   = Join-Path ([IO.Path]::GetTempPath()) ("$RepoName-extract-" + [Guid]::NewGuid().ToString('N'))

  try {
    Show-InfoMessage -Message "Downloading helper scripts archive…"
    Invoke-WebRequest -Uri $RepoZipUri -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop

    Show-InfoMessage -Message "Extracting archive…"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $tmpDir)

    # === Robust wsl-utils module install ===
    try {
      $InstallRoot  = Join-Path $env:USERPROFILE 'WSL'
      $ModulesRoot  = Join-Path $InstallRoot 'modules'
      $WslUtilsDir  = Join-Path $ModulesRoot 'wsl-utils'
      $WslUtilsPsm1 = Join-Path $WslUtilsDir 'wsl-utils.psm1'

      # Find the module file inside the extracted archive
      $wslUtilsSrc = Get-ChildItem -Path $tmpDir -Recurse -File -Filter 'wsl-utils.psm1' -ErrorAction SilentlyContinue |
                    Select-Object -First 1

      if (-not $wslUtilsSrc) {
        Write-Warning "wsl-utils module not found in archive at: $tmpDir"
      } else {
        New-Item -ItemType Directory -Force -Path $WslUtilsDir | Out-Null
        Copy-Item -Force -LiteralPath $wslUtilsSrc.FullName -Destination $WslUtilsPsm1
        Write-Host "  - Installed module: wsl-utils"
        Write-Host "  - From: $($wslUtilsSrc.FullName)"
        Write-Host "  - To:   $WslUtilsPsm1"

        # Ensure user's PSModulePath includes our modules root
        $sep      = [IO.Path]::PathSeparator
        $userPath = [Environment]::GetEnvironmentVariable('PSModulePath','User')
        if ($null -eq $userPath) { $userPath = '' }
        $paths    = $userPath -split [regex]::Escape($sep) | Where-Object { $_ -ne '' }

        if (-not ($paths | Where-Object { $_ -eq $ModulesRoot })) {
          $newPath = if ($paths) { ($paths + $ModulesRoot) -join $sep } else { $ModulesRoot }
          [Environment]::SetEnvironmentVariable('PSModulePath', $newPath, 'User')
          Write-Host "  - Added to user PSModulePath: $ModulesRoot"
        } else {
          Write-Host "  - PSModulePath already includes: $ModulesRoot"
        }
      }
    }
    catch {
      Write-Warning ("Failed to install module 'wsl-utils': {0}" -f $_.Exception.Message)
    }
    # === End robust wsl-utils module install ===

    $root = Join-Path $tmpDir $ZipBaseName

    $candidates = @(
      Join-Path $root 'scripts\wsl'
      Join-Path $root 'scripts'
    )

    $installed = @()
    foreach ($srcDir in $candidates) {
      if (-not (Test-Path -LiteralPath $srcDir)) { continue }
      Get-ChildItem -LiteralPath $srcDir -Filter *.ps1 -File -Recurse | ForEach-Object {
        $dest = Join-Path $ScriptsDir $_.Name
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        try { Unblock-File -LiteralPath $dest } catch {}
        $installed += $dest
      }
      if ($installed.Count -gt 0) { break } # prefer scripts\wsl if present
    }

    if ($installed.Count -gt 0) {
      foreach ($p in $installed) { Show-InfoMessage -Message "Installed: $(Split-Path $p -Leaf)" }
      # Install PowerShell module: wsl-utils
      try {
        $moduleCandidates = @(
          Join-Path $tmpDir 'scripts\wsl-utils.psm1'
          Join-Path $tmpDir 'scripts\wsl\wsl-utils.psm1'
        ) | Where-Object { Test-Path -LiteralPath $_ }

        if ($moduleCandidates.Count -gt 0) {
          New-Item -ItemType Directory -Force -Path $ModulesRoot | Out-Null
          $moduleTarget = Join-Path (Join-Path $ModulesRoot 'wsl-utils') 'wsl-utils.psm1'
          New-Item -ItemType Directory -Force -Path (Split-Path $moduleTarget -Parent) | Out-Null
          Copy-Item -LiteralPath $moduleCandidates[0] -Destination $moduleTarget -Force
          Unblock-File -LiteralPath $moduleTarget -ErrorAction SilentlyContinue

          # Ensure $ModulesRoot is on user PSModulePath
          $uPS = [Environment]::GetEnvironmentVariable('PSModulePath','User')
          if (-not $uPS) { $uPS = '' }
          $parts = $uPS -split [IO.Path]::PathSeparator | Where-Object { $_ }
          if ($parts -notcontains $ModulesRoot) {
            $newPS = ($parts + $ModulesRoot) -join [IO.Path]::PathSeparator
            [Environment]::SetEnvironmentVariable('PSModulePath', $newPS, 'User')
            Show-InfoMessage -Message "Added to user PSModulePath: $ModulesRoot"
          } else {
            Show-InfoMessage -Message "Already on user PSModulePath: $ModulesRoot"
          }

          Show-InfoMessage -Message "Installed module: wsl-utils"
        } else {
          # Write-Warning "wsl-utils module not found in archive. Backup-WSL can still work if run from repo folder." # Removed duplicate warning. Robust handling of wsl-utils import located further up in this file.
        }
      } catch {
        Write-Warning "Failed to install module 'wsl-utils': $($_.Exception.Message)"
      }
    
    } else {
      Write-Warning "No helper scripts found in the archive under 'scripts\wsl' or 'scripts'."
    }
  } catch {
    Write-Warning "Failed to fetch scripts: $($_.Exception.Message)"
  } finally {
    foreach ($p in @($tmpZip,$tmpDir)) {
      try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
  }
}

# -----------------------------
# Install (Initialize)
# -----------------------------
function Initialize-DevEnvBootstrap {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  param()
  Show-HeaderMessage -Message "Installing dev-env WSL helpers…"

  # Folders
  New-DirectoryIfMissing -Path $InstallRoot
  New-DirectoryIfMissing -Path $ScriptsDir
  New-DirectoryIfMissing -Path $BackupsRoot

  # PATH
  if ($PSCmdlet -and $PSCmdlet.ShouldProcess($ScriptsDir, "Add to User PATH")) {
    $added = Add-UserPathEntry -Directory $ScriptsDir
    if ($added) { Show-InfoMessage -Message "Added to user PATH: $ScriptsDir" } else { Show-InfoMessage -Message "Already on user PATH: $ScriptsDir" }
  }

  # Fetch latest helper scripts from the repo
  Install-FetchScripts

  Show-TipMessage -Message "Open a new terminal to pick up PATH changes."
  Show-TipMessage -Message "Run 'Backup-WSL' (or 'Backup-WSL.ps1') to test that commands resolve."
  Write-Host "Done." -ForegroundColor Green
}

# -----------------------------
# Robust Uninstall (Remove)
# -----------------------------
function Remove-DevEnvBootstrap {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
  param()
  Show-HeaderMessage -Message "Uninstalling dev-env WSL helpers…"

  # 0) PATH cleanup first
  if (Test-UserPathContains -Directory $ScriptsDir) {
    if ($PSCmdlet -and $PSCmdlet.ShouldProcess($ScriptsDir, "Remove from User PATH")) {
      Remove-UserPathEntry -Directory $ScriptsDir
      Show-InfoMessage -Message "Removed from user PATH: $ScriptsDir"
    }
  } else {
    Show-InfoMessage -Message "PATH entry already absent: $ScriptsDir"
  }

  # 1) Migrate legacy backups up-front so they survive
  Move-LegacyBackups

  # 2) If we're inside the target tree, step out to a safe working dir
  if ($PWD.Path -like ($InstallRoot + '*')) {
    Show-TipMessage -Message "Close any terminals rooted in $InstallRoot to speed up uninstall."
    try {
      Set-Location -Path $env:TEMP
    } catch {
      Set-Location -Path $env:USERPROFILE
    }
  }

  # 3) Try removal with short backoff retries (handles transient locks like AV/indexer)
  if (Test-Path -LiteralPath $InstallRoot) {
    Show-InfoMessage -Message "Deleting $InstallRoot"
    $removed = $false
    foreach ($ms in 250, 500, 1000) {
      try {
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($InstallRoot, "Remove-Item -Recurse -Force")) {
          Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
        }
        $removed = $true
        break
      } catch {
        Start-Sleep -Milliseconds $ms
      }
    }

    # 4) If still present/locked, stash and schedule RunOnce cleanup
    if (-not $removed -and (Test-Path -LiteralPath $InstallRoot)) {
      $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
      $stash = Join-Path $BackupsRoot "WSL_pending_delete_$stamp"
      New-DirectoryIfMissing -Path $BackupsRoot

      $moved = $false
      try {
        Move-Item -LiteralPath $InstallRoot -Destination $stash -Force -ErrorAction Stop
        $moved = $true
      } catch {
        # robocopy move as last-ditch (handles some odd locks better)
        New-DirectoryIfMissing -Path $stash
        & robocopy $InstallRoot $stash /MOVE /E /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -le 3) { $moved = $true }
        try { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
      }

      if ($moved) {
        # Schedule one-time deletion next sign-in (HKCU RunOnce)
        $cmd = "powershell -NoProfile -WindowStyle Hidden -Command `"Remove-Item -LiteralPath '$stash' -Recurse -Force -ErrorAction SilentlyContinue`""
        try {
          New-ItemProperty `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
            -Name 'DeleteWSLStash' -Value $cmd -PropertyType String -Force | Out-Null
          Show-InfoMessage -Message "Folder was in use; moved to $stash"
          Show-InfoMessage -Message "A one-time cleanup is scheduled for your next sign-in."
        } catch {
          Write-Warning "Couldn't schedule RunOnce cleanup. You can delete '$stash' manually later."
        }
      } else {
        Write-Warning "Could not move or delete $InstallRoot. Close terminals/apps using it and try again."
      }
    } else {
      Show-InfoMessage -Message "Deleted $InstallRoot"
    }
  } else {
    Show-InfoMessage -Message "Nothing to delete at $InstallRoot"
  }

  Write-Host "Done. Backups preserved in $BackupsRoot. Open a new terminal to pick up changes." -ForegroundColor Green
}

# -----------------------------
# Entry
# -----------------------------
Write-Host ""
Write-Host "dev-env bootstrap" -ForegroundColor Yellow
Write-Host "==================" -ForegroundColor Yellow
Show-TipMessage -Message 'Invoke via scriptblock so you can pass parameters:'
Write-Host '  & { $(irm https://raw.githubusercontent.com/crispd/dev-env/main/scripts/bootstrap.ps1) } [-Uninstall]' -ForegroundColor DarkGray
Write-Host ""

if ($Uninstall) {
  Remove-DevEnvBootstrap
} else {
  Initialize-DevEnvBootstrap
}
