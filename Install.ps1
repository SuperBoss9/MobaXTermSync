#Requires -Version 5.1
# Shortcut launcher for the interactive installer (run from sync root).
$installer = Join-Path $PSScriptRoot 'app\Install-MobaSync.ps1'
if (-not (Test-Path -LiteralPath $installer)) {
    Write-Error "Installer not found: $installer"
    exit 2
}
& $installer -Interactive @args
