#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'MobaSync.psm1'
Import-Module -Name $modulePath -Force -DisableNameChecking

try {
    $syncRoot = Find-SyncRoot -StartPath $PSScriptRoot
}
catch {
    # Cannot log to local root yet
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

$common = Get-CommonConfig -SyncRoot $syncRoot
$computerName = [Environment]::MachineName
$cfg = Get-ComputerConfig -SyncRoot $syncRoot -ComputerName $computerName
if ($null -eq $cfg -or -not [bool]$cfg.Enabled -or -not [bool]$cfg.Initialized) {
    [Console]::Error.WriteLine("Watcher: computer config missing/disabled/uninitialized for '$computerName'.")
    exit 3
}

$localRoot = Get-LocalDataRoot -NodeId $cfg.NodeId
$debounce = [int]$common.DebounceSeconds
if ($debounce -lt 1) { $debounce = 15 }

$invokeScript = Join-Path $PSScriptRoot 'Invoke-MobaSync.ps1'

function Invoke-DeferredOrSync {
    param([string]$Reason)
    try {
        Write-SyncLog -LocalDataRoot $localRoot -Message ("Watcher triggering sync; reason={0}" -f $Reason)
        & $invokeScript -Reason $Reason
    }
    catch {
        Write-SyncLog -LocalDataRoot $localRoot -Level ERROR -Message ("Watcher sync error: " + $_.Exception.Message)
    }
}

# Startup: if Moba closed, sync (also clears pending)
if (-not (Test-MobaProcessRunning -ProcessPattern $common.ProcessPattern)) {
    if (Test-PendingSync -LocalDataRoot $localRoot) {
        Invoke-DeferredOrSync -Reason 'PendingOnStart'
    }
    else {
        Invoke-DeferredOrSync -Reason 'WatcherStart'
    }
}
else {
    Write-SyncLog -LocalDataRoot $localRoot -Message 'Watcher start: MobaXterm is running; waiting for exit.'
    if (Test-PendingSync -LocalDataRoot $localRoot) {
        Write-SyncLog -LocalDataRoot $localRoot -Message 'Pending sync retained until MobaXterm closes.'
    }
}

if ($Once) {
    exit 0
}

$script:debounceTimer = $null
$syncLock = New-Object object

function Request-DebouncedSync {
    param([string]$Reason)
    try {
        if ($null -ne $script:debounceTimer) {
            $script:debounceTimer.Stop()
            $script:debounceTimer.Dispose()
            $script:debounceTimer = $null
        }
    }
    catch { }

    $timer = New-Object System.Timers.Timer
    $timer.Interval = [Math]::Max(1000, $debounce * 1000)
    $timer.AutoReset = $false
    $action = {
        $reasonInner = $Event.MessageData
        try {
            Start-Sleep -Milliseconds 200
            if (Test-MobaProcessRunning) {
                Write-SyncLog -LocalDataRoot $localRoot -Message 'Debounce fired but MobaXterm still running; skip.'
                return
            }
            Invoke-DeferredOrSync -Reason $reasonInner
        }
        catch {
            Write-SyncLog -LocalDataRoot $localRoot -Level ERROR -Message $_.Exception.Message
        }
    }
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $action -MessageData $Reason | Out-Null
    $script:debounceTimer = $timer
    $timer.Start()
    Write-SyncLog -LocalDataRoot $localRoot -Message ("Debounce scheduled ({0}s); reason={1}" -f $debounce, $Reason)
}

$useWmi = $false
$subscriber = $null
try {
    # Win32_ProcessStopTrace may require elevation; fall back to polling if it fails.
    $query = "SELECT * FROM Win32_ProcessStopTrace"
    $subscriber = Register-CimIndicationEvent -Query $query -SourceIdentifier 'MobaBookmarkSync.ProcessStop' -Action {
        try {
            $procName = [string]$Event.SourceEventArgs.NewEvent.ProcessName
            if ($procName -like 'MobaXterm*.exe' -or $procName -like 'MobaXterm*') {
                # Re-import is not available in event runspace easily; signal via file flag
                $flag = Join-Path $env:TEMP 'MobaBookmarkSync-stop.flag'
                Set-Content -LiteralPath $flag -Value (Get-Date).ToString('o') -Encoding ASCII
            }
        }
        catch { }
    } -ErrorAction Stop
    $useWmi = $true
    Write-SyncLog -LocalDataRoot $localRoot -Message 'Watcher using CIM Win32_ProcessStopTrace.'
}
catch {
    Write-SyncLog -LocalDataRoot $localRoot -Level WARN -Message ("CIM process stop events unavailable: {0}. Using polling." -f $_.Exception.Message)
    $useWmi = $false
}

$wasRunning = Test-MobaProcessRunning -ProcessPattern $common.ProcessPattern
$flagPath = Join-Path $env:TEMP 'MobaBookmarkSync-stop.flag'

Write-SyncLog -LocalDataRoot $localRoot -Message 'Watcher entering monitor loop.'

while ($true) {
    try {
        $running = Test-MobaProcessRunning -ProcessPattern $common.ProcessPattern

        if ($useWmi -and (Test-Path -LiteralPath $flagPath)) {
            Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
            if (-not $running) {
                Request-DebouncedSync -Reason 'ProcessStopTrace'
            }
        }

        if ($wasRunning -and -not $running) {
            Request-DebouncedSync -Reason 'ProcessExitPoll'
        }

        # Pending sync while closed
        if (-not $running -and (Test-PendingSync -LocalDataRoot $localRoot)) {
            # Only if no debounce pending
            if ($null -eq $script:debounceTimer -or -not $script:debounceTimer.Enabled) {
                Invoke-DeferredOrSync -Reason 'PendingWhileClosed'
            }
        }

        $wasRunning = $running
    }
    catch {
        Write-SyncLog -LocalDataRoot $localRoot -Level ERROR -Message ("Watcher loop error: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 2
}
