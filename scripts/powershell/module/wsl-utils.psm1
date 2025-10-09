# wsl-utils.psm1 — shared helpers for WSL scripting (PS 5.1+/7)
# Approved verbs, robust parsing, and exported members.
# TODO: Rename this file to something more specific, like wsl-list-helpers.psm1, so that it is not confused with a full WSL management module. Requires updating all files that reference it.

function Get-WslList {
  <#
    Parses `wsl -l -v` robustly:
      - strips embedded NULs (UTF-16-ish output cases)
      - skips headers/blank lines and optional leading '*'
      - splits on runs of 2+ of: space/tab/NBSP/figure/narrow-NBSP
      - builds columns from the END:  ... Name | State | Version
    Set $env:WSL_UTILS_DEBUG=1 to see debug output.
  #>
  $raw   = & wsl -l -v 2>$null
  $items = @()

  $splitPattern = '[ \t\u00A0\u2007\u202F]{2,}'

  if ($raw) {
    foreach ($line0 in $raw) {
      if ([string]::IsNullOrWhiteSpace($line0)) { continue }

      # key fix: remove embedded NULs first
      $line = ($line0 -replace '\x00','')

      # skip title/header rows
      if ($line -match '^\s*Windows Subsystem for Linux Distributions:' ) { continue }
      if ($line -match '^\s*\*?\s*NAME\b.*\bVERSION\b') { continue }

      # trim leading spaces + optional '*', keep alignment
      $line2 = ($line -replace '^\s*\*\s*','').TrimEnd()

      # split on wide whitespace runs
      $parts = [regex]::Split($line2.Trim(), $splitPattern) | Where-Object { $_ -ne '' }
      if ($env:WSL_UTILS_DEBUG -eq '1') { Write-Host "DBG parts: «$($parts -join ' | ')»" -ForegroundColor DarkGray }

      if ($parts.Count -ge 3) {
        $verStr = $parts[-1].Trim()
        $state  = $parts[-2].Trim()
        $name   = ($parts[0..($parts.Count-3)] -join ' ').Trim()

        # compute values first (no inline if-expressions)
        $verVal   = if ($verStr -match '^\d+$') { [int]$verStr } else { $null }
        $stateVal = if (-not [string]::IsNullOrWhiteSpace($state)) { $state } else { '(unknown)' }

        if ($name) {
          $items += [pscustomobject]@{
            Name    = $name
            State   = $stateVal
            Version = $verVal
          }
        }
      }
    }
  }

  # final fallback (older/localized outputs)
  if (-not $items) {
    $names = (& wsl -l -q 2>$null) | Where-Object { $_ -and $_.Trim() -ne '' }
    foreach ($n in $names) {
      $items += [pscustomobject]@{ Name = $n.Trim(); State = '(unknown)'; Version = $null }
    }
  }

  if (-not $items) { throw "No WSL distros detected." }
  return $items
}

function Write-WslList {
  [CmdletBinding()]
  param([Parameter(Mandatory)][object[]]$List)
  Write-Host "Available WSL distros:" -ForegroundColor Cyan
  $i = 1
  foreach ($d in $List) {
    $verText = if ($null -ne $d.Version -and $d.Version -ne 0) { "$($d.Version)" } else { "" }
    Write-Host ("[{0}] {1}   (State: {2}, Version: {3})" -f $i, $d.Name, $d.State, $verText)
    $i++
  }
  Write-Host ""  # blank line before prompts
}

function Confirm-YesNo {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [bool]$DefaultYes = $true
  )
  $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
  while ($true) {
    $resp = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($resp)) { return $DefaultYes }
    switch ($resp.ToLowerInvariant()) {
      'y' { return $true }
      'yes' { return $true }
      'n' { return $false }
      'no' { return $false }
      default { Write-Host "Please answer y/n." -ForegroundColor Yellow }
    }
  }
}

function Get-UserInput {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Default = ''
  )
  while ($true) {
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $v = Read-Host $label
    if ([string]::IsNullOrWhiteSpace($v)) {
      if ($Default) { return $Default } else { continue }
    }
    return $v.Trim()
  }
}

function Get-ExistingDistroNames {
  (& wsl -l -q 2>$null) | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
}

function Get-UniqueName {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Base)
  $existing = Get-ExistingDistroNames
  if ($existing -notcontains $Base) { return $Base }
  for ($i=2; $i -lt 1000; $i++) {
    $cand = "$Base$i"
    if ($existing -notcontains $cand) { return $cand }
  }
  throw "Could not determine a unique name near '$Base'."
}

function Select-WslDistro {
  [CmdletBinding()]
  param([string]$Name)

  $list = Get-WslList
  if ($Name) {
    $exact = $list | Where-Object Name -eq $Name
    if ($exact) { return $exact }
    Write-Warning "Distro '$Name' not found."
  }

  Write-WslList -List $list

  while ($true) {
    $choice = Read-Host "Type the NUMBER or NAME of the distro (or 'q' to quit)"
    if ($choice -match '^[Qq]$') { throw "Cancelled by user." }
    if ($choice -match '^\d+$') {
      $idx = [int]$choice
      if ($idx -ge 1 -and $idx -le $list.Count) { return $list[$idx-1] }
    } else {
      $match = $list | Where-Object { $_.Name -eq $choice }
      if ($match) { return $match }
    }
    Write-Warning "Invalid selection. Try again."
  }
}

Export-ModuleMember -Function `
  Get-WslList, Write-WslList, Confirm-YesNo, `
  Get-UserInput, Get-ExistingDistroNames, Get-UniqueName, `
  Select-WslDistro
