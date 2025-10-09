#!/usr/bin/env pwsh
<#
Simple test harness for install-node.ps1 dry-run behavior.
Exits 0 on success, 1 on failure.
#>

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} catch {
    # fallback when run with -File from different cwd
    $scriptDir = (Get-Location).Path
}

$installerPath = Resolve-Path (Join-Path $scriptDir '..\install-node.ps1')
Write-Host "Running dry-run test against: $installerPath"

# Run the installer script in DryRun + Silent mode and capture output
$output = & $installerPath -DryRun -Silent -DebugMode *>&1 | ForEach-Object { $_ }
$outText = ($output -join "`n").Trim()

Write-Host "--- captured output start ---"
Write-Host $outText
Write-Host "--- captured output end ---"

$passed = $false
if ($outText -match 'DRY-RUN: would invoke' -or $outText -match 'DryRun: skipping winget search') {
    $passed = $true
}

if ($passed) {
    Write-Host "TEST PASS: Dry-run output detected"
    exit 0
} else {
    Write-Host "TEST FAIL: expected dry-run output not found" -ForegroundColor Red
    exit 1
}
# Test harness for install-node.ps1 dry-run
# Runs the installer with -DryRun -Silent and asserts that expected output appears.

$script = Join-Path $PSScriptRoot '..\install-node.ps1'
Write-Host "Running dry-run test against $script"

# Capture output
Write-Host "Invoking: $script -DryRun -Silent -DebugMode"
$result = & $script -DryRun -Silent -DebugMode 2>&1 | Out-String

Write-Host "--- Output ---"
Write-Host $result

if ($result -match 'DRY-RUN: would invoke: winget') {
    Write-Host "Dry-run output looks good." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Dry-run output did not include expected DRY-RUN line." -ForegroundColor Red
    exit 1
}
