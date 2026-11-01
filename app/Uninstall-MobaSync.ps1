#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$RemoveLocalData,
    [switch]$KeepLocalData,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'MobaSync.psm1'
Import-Module -Name $modulePath -Force -DisableNameChecking

try {
    $syncRoot = Find-SyncRoot -StartPath $PSScriptRoot
}
catch {
    Write-Error $_.Exception.Message
    exit 2
}

$computerName = [Environment]::MachineName
$cfg = Get-ComputerConfig -SyncRoot $syncRoot -ComputerName $computerName

Write-Host "Uninstalling MobaBookmarkSync for computer '$computerName'."
Write-Host 'Shared operations journal and other computer configs will NOT be deleted.'
Write-Host 'MobaXterm.ini will NOT be deleted.'

Unregister-MobaSyncTasks -ComputerName $computerName
Write-Host 'Scheduled tasks removed (if present).'

# Stop local watcher processes running our script
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*Watch-MobaXterm.ps1*' } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            Write-Host ("Stopped watcher PID {0}" -f $_.ProcessId)
        }
        catch {
            Write-Warning ("Could not stop PID {0}: {1}" -f $_.ProcessId, $_.Exception.Message)
        }
    }

$localRoot = $null
if ($null -ne $cfg -and $cfg.NodeId) {
    $localRoot = Join-Path $env:LOCALAPPDATA ("MobaBookmarkSync\{0}" -f $cfg.NodeId)
}

if ($localRoot -and (Test-Path -LiteralPath $localRoot)) {
    $remove = $false
    if ($RemoveLocalData) { $remove = $true }
    elseif ($KeepLocalData) { $remove = $false }
    elseif ($Force) { $remove = $false }
    else {
        $ans = Read-Host "Delete local runtime directory '$localRoot'? [y/N]"
        $remove = ($ans -match '^(y|yes)$')
    }

    if ($remove) {
        Remove-Item -LiteralPath $localRoot -Recurse -Force
        Write-Host "Removed local data: $localRoot"
    }
    else {
        Write-Host "Kept local data: $localRoot"
    }
}
else {
    Write-Host 'No local runtime directory found.'
}

Write-Host 'Uninstall finished. Computer config JSON under config\computers was left in place.'
Write-Host 'Remove it manually only if you intend to retire this machine from the sync set.'
exit 0
