Describe 'install-node.ps1 dry-run' {
    Context 'When invoked with -DryRun -Silent' {
        It 'emits a DRY-RUN or DryRun message' {
            # Prefer PSScriptRoot (set when running this script file), fallback to current location
            $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
            $installerPath = Join-Path $scriptDir '..\install-node.ps1'

            # Run the installer and capture output
            $output = & $installerPath -DryRun -Silent -DebugMode *>&1 | Out-String

            $matched = $output -match 'DRY-RUN: would invoke|DryRun: skipping winget search'
            $matched | Should Be $true
        }
    }
}
