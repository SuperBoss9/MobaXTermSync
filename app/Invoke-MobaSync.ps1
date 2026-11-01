#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$ApprovePendingDelete,
    [switch]$DryRun,
    [string]$Reason = 'Manual'
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

$common = Get-CommonConfig -SyncRoot $syncRoot
$computerName = [Environment]::MachineName
$cfg = Get-ComputerConfig -SyncRoot $syncRoot -ComputerName $computerName

if ($null -eq $cfg) {
    Write-Error "Computer config not found for '$computerName'. Run Install-MobaSync.ps1 first."
    exit 3
}
if (-not [bool]$cfg.Enabled) {
    Write-Host "Computer '$computerName' is disabled in config. Exiting."
    exit 0
}
if (-not [bool]$cfg.Initialized -and -not $ApprovePendingDelete) {
    Write-Error "Computer '$computerName' is not Initialized. Run Install-MobaSync.ps1."
    exit 4
}

$localRoot = Get-LocalDataRoot -NodeId $cfg.NodeId
Write-SyncLog -LocalDataRoot $localRoot -Message ("Invoke-MobaSync starting; reason={0}" -f $Reason)

try {
    $result = Invoke-MobaSyncCore -SyncRoot $syncRoot -ComputerConfig $cfg -CommonConfig $common `
        -ApprovePendingDelete:$ApprovePendingDelete -DryRun:$DryRun

    if ($result.Status -eq 'deferred') {
        Write-Host $result.Message
        exit 0
    }
    if ($result.Status -eq 'locked') {
        Write-Host $result.Message
        exit 0
    }
    if ($result.Status -eq 'mass-delete-blocked') {
        Write-Warning $result.Message
        exit 5
    }
    if ($result.Status -eq 'error') {
        Write-Error $result.Message
        exit 1
    }

    Write-Host ("Sync status: {0}" -f $result.Status)
    if ($result.PSObject.Properties['Published']) {
        Write-Host ("Published operations: {0}" -f $result.Published)
    }
    if ($result.PSObject.Properties['Applied']) {
        Write-Host ("Applied bookmarks: {0}" -f $result.Applied)
    }
    exit 0
}
catch {
    Write-SyncLog -LocalDataRoot $localRoot -Level ERROR -Message $_.Exception.Message
    Write-Error $_.Exception.Message
    exit 1
}
