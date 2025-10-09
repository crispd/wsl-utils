[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [switch]$Force,
    [switch]$DebugMode,
    [switch]$Silent,
    [switch]$DryRun
)

Write-Host "Checking for Node.js on PATH..."
try {
    $node = Get-Command node -ErrorAction Stop
    Write-Host "Node is already installed at: $($node.Path)"
    node --version
    npm --version
    exit 0
} catch {
    Write-Host "Node not found. Will attempt to install via winget."
}

if (-not $DryRun) {
    Write-Host "Running: winget search node"
    $results = winget search node | Select-Object -First 200

    if (-not $results) {
        Write-Host "winget search returned no results or winget is not available." -ForegroundColor Yellow
        Write-Host "Please run 'winget search node' manually or install Node from https://nodejs.org/"
        exit 1
    }

    $results | ForEach-Object -Begin { $i = 0 } -Process {
        $i++
        Write-Host "[$i] $_"
    }
} else {
    Write-Host "DryRun: skipping winget search (no network calls)"
    $results = @()
    $i = 0
}

$primaryId = 'OpenJS.NodeJS.LTS'
$fallbackId = 'OpenJS.NodeJS'

# Diagnostic: print winget command info
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetCmd) {
    Write-Host "winget command type: $($wingetCmd.CommandType)"
    Write-Host "winget source/path: $($wingetCmd.Source)"
} else {
    Write-Host "winget not found on PATH" -ForegroundColor Yellow
}

function Install-ById($id) {
    Write-Host "Attempting to install package id: $id"
    $wingetCommandStrings = @('install','--id',$id,'-e')
    if ($Force) { $wingetCommandStrings += '--silent' }

    # Preferred: invoke the 'winget' command directly so PowerShell resolves the correct handler
    try {
        if ($DryRun) {
            Write-Output "DRY-RUN: would invoke: winget $($wingetCommandStrings -join ' ')"
            return $true
        }
    if ($DebugMode) { Write-Host "Invoking: winget $($wingetCommandStrings -join ' ')" -ForegroundColor Cyan }
        if (-not $PSCmdlet.ShouldProcess("winget", $wingetCommandStrings -join ' ')) {
            Write-Host "User declined ShouldProcess for winget invocation" -ForegroundColor Yellow
            return $false
        }
        & winget @wingetCommandStrings
        $ec = $LASTEXITCODE
        Write-Host "winget exited with code $ec"
        return ($ec -eq 0)
    } catch {
        Write-Host "Direct invocation of 'winget' failed: $($_.Exception.Message)" -ForegroundColor Yellow
        # Attempt fallback: if winget is an ExternalScript (winget.ps1), run it with powershell -File
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetCmd -and $wingetCmd.CommandType -eq 'ExternalScript') {
            $scriptPath = $wingetCmd.Source
            try {
                if ($DebugMode) { Write-Host "Invoking: powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath $($wingetCommandStrings -join ' ')" -ForegroundColor Cyan }
                & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @wingetCommandStrings
                $ec = $LASTEXITCODE
                Write-Host "powershell winget script exited with code $ec"
                return ($ec -eq 0)
            } catch {
                Write-Host "Fallback powershell invocation failed: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        }
        return $false
    }
}

# Main flow: silent/non-interactive vs interactive menu
if ($Silent) {
    Write-Host "Non-interactive: attempting to install $primaryId (recommended)"
    if (Install-ById $primaryId) {
        Write-Host "Installed $primaryId successfully.";
        exit 0
    }
    Write-Host "Primary install failed; attempting fallback..." -ForegroundColor Yellow
    if (Install-ById $fallbackId) {
        Write-Host "Installed $fallbackId successfully.";
        exit 0
    }
    Write-Host "Both automatic installs failed." -ForegroundColor Red
    exit 1
}

Write-Host "Choose an option to install:"

Write-Host "  1) Install $primaryId (recommended)"
Write-Host "  2) Install $fallbackId"
Write-Host "  3) Pick from the search results by number"
Write-Host "  4) Cancel"

$choice = Read-Host "Enter choice (1-4) [1]"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

switch ($choice) {
    '1' {
        if (Install-ById $primaryId) { Write-Host "Installed $primaryId successfully."; break }
        Write-Host "Primary install failed; attempting fallback..." -ForegroundColor Yellow
        if (Install-ById $fallbackId) { Write-Host "Installed $fallbackId successfully."; break }
        Write-Host "Both automatic installs failed." -ForegroundColor Red
        exit 1
    }
    '2' {
        if (Install-ById $fallbackId) { Write-Host "Installed $fallbackId successfully."; break }
        Write-Host "Fallback install failed." -ForegroundColor Red
        exit 1
    }
    '3' {
        $num = Read-Host "Enter the result number to install"
        if (-not [int]::TryParse($num, [ref]$n) -or $n -lt 1 -or $n -gt $i) {
            Write-Host "Invalid selection" -ForegroundColor Red
            exit 1
        }
        $line = $results[$n-1]
        # attempt to extract an Id token from the line (best-effort)
        if ($line -match "(OpenJS\.[^\s]+)") { $selId = $matches[1] } else { $selId = Read-Host "Enter package id to install" }
        if (Install-ById $selId) { Write-Host "Installed $selId successfully."; break }
        Write-Host "Install of $selId failed." -ForegroundColor Red
        exit 1
    }
    default { Write-Host "Cancelled"; exit 0 }
}

Write-Host "Installation finished; please open a new PowerShell session to refresh PATH and verify with:"
Write-Host "  node --version`n  npm --version"
