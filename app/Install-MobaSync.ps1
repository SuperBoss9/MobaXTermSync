#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$IniPath,
    [ValidateSet('AutoTag')]
    [string]$InitialImportMode = 'AutoTag',
    [switch]$ForceReinstall,
    [switch]$DryRun,
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'MobaSync.psm1'
Import-Module -Name $modulePath -Force -DisableNameChecking

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Read-HostRequired {
    param([string]$Prompt)
    while ($true) {
        $v = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Write-Host '  Value is required.' -ForegroundColor Yellow
    }
}

function Read-HostDefault {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )
    if ([string]::IsNullOrEmpty($Default)) {
        $v = Read-Host $Prompt
        return $v.Trim()
    }
    $v = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Read-HostYesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host ("{0} ({1})" -f $Prompt, $hint)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v -match '^(y|yes)$')
}

function Read-HostBool {
    param(
        [string]$Prompt,
        [bool]$Current
    )
    $cur = if ($Current) { 'true' } else { 'false' }
    $v = Read-Host ("{0} [{1}] (true/false)" -f $Prompt, $cur)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Current }
    if ($v -match '^(1|true|yes|y)$') { return $true }
    if ($v -match '^(0|false|no|n)$') { return $false }
    Write-Host '  Keeping current value.' -ForegroundColor Yellow
    return $Current
}

function Pause-Enter {
    Write-Host ''
    [void](Read-Host 'Press Enter to continue')
}

function Write-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Title) -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Test-RequiredFiles {
    param([string]$SyncRoot)
    $required = @(
        (Join-Path $SyncRoot 'app\MobaSync.psm1'),
        (Join-Path $SyncRoot 'app\Invoke-MobaSync.ps1'),
        (Join-Path $SyncRoot 'app\Watch-MobaXterm.ps1'),
        (Join-Path $SyncRoot 'config\common.json')
    )
    foreach ($f in $required) {
        if (-not (Test-Path -LiteralPath $f)) {
            throw "Required file missing: $f"
        }
    }
}

function Show-Status {
    param(
        [string]$SyncRoot,
        [string]$ComputerName,
        $Common,
        $Cfg
    )
    Write-Header 'Status'
    Write-Host ("  Computer:     {0}" -f $ComputerName)
    Write-Host ("  SyncRoot:     {0}" -f $SyncRoot)
    Write-Host ("  Operations:   {0}" -f @(Get-SyncOperations -SyncRoot $SyncRoot).Count)
    Write-Host ''
    Write-Host '  This computer:' -ForegroundColor White
    if ($null -eq $Cfg) {
        Write-Host '    (not configured yet)' -ForegroundColor Yellow
    }
    else {
        Write-Host ("    Tag:         {0}" -f $Cfg.Tag)
        Write-Host ("    NodeId:      {0}" -f $Cfg.NodeId)
        Write-Host ("    IniPath:     {0}" -f $Cfg.IniPath)
        Write-Host ("    Enabled:     {0}" -f $Cfg.Enabled)
        Write-Host ("    Initialized: {0}" -f $Cfg.Initialized)
        $iniOk = Test-Path -LiteralPath $Cfg.IniPath
        Write-Host ("    INI exists:  {0}" -f $iniOk)
        $local = Get-LocalDataRoot -NodeId $Cfg.NodeId
        Write-Host ("    LocalData:   {0}" -f $local)
    }
    Write-Host ''
    Write-Host '  Common settings:' -ForegroundColor White
    Write-Host ("    AutoTag:                {0}" -f $Common.AutoTag)
    Write-Host ("    DeleteWins:             {0}" -f $Common.DeleteWins)
    Write-Host ("    DebounceSeconds:        {0}" -f $Common.DebounceSeconds)
    Write-Host ("    BackupCount:            {0}" -f $Common.BackupCount)
    Write-Host ("    MassDeleteLimitPercent: {0}" -f $Common.MassDeleteLimitPercent)
    Write-Host ("    Weekly:                 {0} {1}" -f $Common.WeeklyDay, $Common.WeeklyTime)
    Write-Host ("    ProcessPattern:         {0}" -f $Common.ProcessPattern)

    Write-Host ''
    Write-Host '  Known computers:' -ForegroundColor White
    $all = @(Get-AllComputerConfigs -SyncRoot $SyncRoot)
    if ($all.Count -eq 0) {
        Write-Host '    (none)'
    }
    else {
        foreach ($c in $all) {
            $mark = if ($c.ComputerName -and $c.ComputerName.ToUpperInvariant() -eq $ComputerName.ToUpperInvariant()) { ' *' } else { '' }
            Write-Host ("    [{0}] {1}  Init={2}  {3}{4}" -f $c.Tag, $c.ComputerName, $c.Initialized, $c.IniPath, $mark)
        }
    }
}

function Resolve-InstallIniPath {
    param(
        [string]$Preferred,
        $ExistingCfg
    )
    $guess = $null
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        $guess = [Environment]::ExpandEnvironmentVariables($Preferred.Trim())
    }
    elseif ($ExistingCfg -and $ExistingCfg.IniPath) {
        $guess = [string]$ExistingCfg.IniPath
    }
    else {
        $guess = Find-DefaultMobaIniPath
    }

    Write-Host ''
    Write-Host 'Path to MobaXterm.ini' -ForegroundColor White
    if ($guess) {
        Write-Host ("  Suggested: {0}" -f $guess) -ForegroundColor DarkGray
    }
    else {
        Write-Host '  No default found. Typical path:' -ForegroundColor DarkGray
        Write-Host ('  {0}' -f (Join-Path $env:USERPROFILE 'Documents\MobaXterm\MobaXterm.ini')) -ForegroundColor DarkGray
    }

    while ($true) {
        $path = Read-HostDefault -Prompt 'IniPath' -Default $(if ($guess) { $guess } else { '' })
        $path = [Environment]::ExpandEnvironmentVariables($path)
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host "  File not found: $path" -ForegroundColor Yellow
            if (-not (Read-HostYesNo -Prompt 'Try again?' -Default $true)) {
                throw "MobaXterm.ini not found: $path"
            }
            continue
        }
        try {
            $null = Read-MobaIni -Path $path
            return $path
        }
        catch {
            Write-Host ("  Invalid INI: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            if (-not (Read-HostYesNo -Prompt 'Try another path?' -Default $true)) {
                throw
            }
        }
    }
}

function Resolve-InstallTag {
    param(
        [string]$Preferred,
        [string]$SyncRoot,
        [string]$ComputerName,
        $ExistingCfg
    )
    $defaultTag = $Preferred
    if ([string]::IsNullOrWhiteSpace($defaultTag) -and $ExistingCfg) {
        $defaultTag = [string]$ExistingCfg.Tag
    }
    if ([string]::IsNullOrWhiteSpace($defaultTag)) {
        # Suggest short prefix from computer name
        $cn = $ComputerName
        if ($cn.Length -le 4) { $defaultTag = $cn.ToUpperInvariant() }
        else { $defaultTag = $cn.Substring(0, [Math]::Min(4, $cn.Length)).ToUpperInvariant() }
    }

    Write-Host ''
    Write-Host 'Tag = prefix for bookmarks created on this PC, e.g. [RM], [MITX]' -ForegroundColor DarkGray
    while ($true) {
        $tag = Read-HostDefault -Prompt 'Tag' -Default $defaultTag
        $tag = $tag.Trim().Trim('[', ']')
        if ([string]::IsNullOrWhiteSpace($tag)) {
            Write-Host '  Tag is required.' -ForegroundColor Yellow
            continue
        }
        $conflict = $null
        foreach ($other in @(Get-AllComputerConfigs -SyncRoot $SyncRoot)) {
            if ($other.ComputerName -and ($other.ComputerName.ToUpperInvariant() -eq $ComputerName.ToUpperInvariant())) {
                continue
            }
            if ($other.Tag -and ($other.Tag.ToUpperInvariant() -eq $tag.ToUpperInvariant())) {
                $conflict = $other
                break
            }
        }
        if ($conflict) {
            Write-Host ("  Tag '{0}' already used by '{1}'." -f $tag, $conflict.ComputerName) -ForegroundColor Yellow
            continue
        }
        return $tag
    }
}

function Show-ClassificationReport {
    param($Report, [int]$OpsCount)
    Write-Host ''
    Write-Host '=== Initial merge classification ===' -ForegroundColor White
    Write-Host ("Exact duplicates:     {0}" -f @($Report.ExactDuplicates).Count)
    foreach ($x in @($Report.ExactDuplicates)) {
        Write-Host ("  = {0}  <=>  {1}" -f $x.LocalName, $x.GlobalName)
    }
    Write-Host ("Probable conflicts:   {0}" -f @($Report.ProbableConflicts).Count)
    foreach ($x in @($Report.ProbableConflicts)) {
        Write-Host ("  ~ local '{0}' vs global '{1}' ({2})" -f $x.LocalName, $x.GlobalName, $x.Reason)
    }
    Write-Host ("Unique local:         {0}" -f @($Report.UniqueLocal).Count)
    foreach ($x in @($Report.UniqueLocal)) {
        Write-Host ("  + {0}" -f $x.LocalName)
    }
    Write-Host ("Incoming global:      {0}" -f @($Report.IncomingGlobal).Count)
    foreach ($x in @($Report.IncomingGlobal)) {
        Write-Host ("  < {0}" -f $x.Name)
    }
    Write-Host ("Global ops existing:  {0}" -f $OpsCount)
    Write-Host ("First computer:       {0}" -f ($OpsCount -eq 0))
    Write-Host ''
}

function Invoke-InstallFlow {
    param(
        [string]$SyncRoot,
        [string]$ComputerName,
        $Common,
        [string]$Tag,
        [string]$IniPath,
        [string]$InitialImportMode,
        [switch]$ForceReinstall,
        [switch]$DryRun,
        [switch]$PromptConfirm
    )

    if (Test-MobaProcessRunning -ProcessPattern $Common.ProcessPattern) {
        throw 'MobaXterm is running. Close all MobaXterm windows and retry.'
    }

    $cfgPath = Get-ComputerConfigPath -SyncRoot $SyncRoot -ComputerName $ComputerName
    $cfg = Get-ComputerConfig -SyncRoot $SyncRoot -ComputerName $ComputerName

    $IniPath = Resolve-InstallIniPath -Preferred $IniPath -ExistingCfg $cfg
    $Tag = Resolve-InstallTag -Preferred $Tag -SyncRoot $SyncRoot -ComputerName $ComputerName -ExistingCfg $cfg

    $iniProbe = Read-MobaIni -Path $IniPath

    if ($null -eq $cfg) {
        $cfg = [pscustomobject]@{
            ComputerName = $ComputerName
            NodeId       = [Guid]::NewGuid().ToString()
            Tag          = $Tag
            IniPath      = $IniPath
            Enabled      = $true
            Initialized  = $false
            _ConfigPath  = $cfgPath
        }
    }
    else {
        $cfg.Tag = $Tag
        $cfg.IniPath = $IniPath
        $cfg.Enabled = $true
        if ($ForceReinstall) {
            $cfg.Initialized = $false
        }
        $cfg | Add-Member -NotePropertyName '_ConfigPath' -NotePropertyValue $cfgPath -Force
    }

    $localRoot = Get-LocalDataRoot -NodeId $cfg.NodeId
    Write-Host ''
    Write-Host ("  Tag:       {0}" -f $cfg.Tag)
    Write-Host ("  NodeId:    {0}" -f $cfg.NodeId)
    Write-Host ("  IniPath:   {0}" -f $cfg.IniPath)
    Write-Host ("  LocalData: {0}" -f $localRoot)
    Write-Host ("  Mode:      {0}" -f $(if ($DryRun) { 'DryRun (no writes)' } else { 'Install' }))

    $ops = @(Get-SyncOperations -SyncRoot $SyncRoot)
    $globalIndex = Build-GlobalBookmarkIndex -Operations $ops -DeleteWins ([bool]$Common.DeleteWins)
    $localBookmarks = @(Get-BookmarkEntries -Ini $iniProbe)
    $report = Invoke-ClassifyInitialImport -LocalBookmarks $localBookmarks -GlobalIndex $globalIndex `
        -Tag $cfg.Tag -ComputerName $ComputerName
    Show-ClassificationReport -Report $report -OpsCount $ops.Count

    if ($DryRun) {
        Write-Host 'DryRun plan (nothing will be written):' -ForegroundColor Yellow
        Write-Host "  - Computer config: $cfgPath"
        Write-Host '  - Backup INI under %LOCALAPPDATA%\MobaBookmarkSync\<NodeId>\backups\'
        Write-Host '  - AutoTag unique local bookmarks'
        Write-Host '  - Reuse exact duplicates; keep probable conflicts'
        Write-Host '  - No delete operations on initial import'
        Write-Host '  - Apply merged bookmarks; write state.json; Initialized=true'
        Write-Host '  - Register logon watcher + weekly scheduled task'
        return [pscustomobject]@{ Status = 'dry-run'; Report = $report }
    }

    if ($PromptConfirm) {
        if (-not (Read-HostYesNo -Prompt 'Proceed with installation?' -Default $true)) {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            return [pscustomobject]@{ Status = 'cancelled' }
        }
    }

    $doForce = [bool]$ForceReinstall
    if ([bool]$cfg.Initialized -and -not $doForce) {
        if ($PromptConfirm) {
            $doForce = Read-HostYesNo -Prompt 'Already Initialized. Re-run initial import (ForceReinstall)?' -Default $false
        }
    }
    if ($doForce) {
        $cfg.Initialized = $false
    }

    $cfg.Initialized = $false
    Save-ComputerConfig -Path $cfgPath -Config $cfg
    $cfg = Get-ComputerConfig -SyncRoot $SyncRoot -ComputerName $ComputerName

    $result = Invoke-MobaSyncCore -SyncRoot $SyncRoot -ComputerConfig $cfg -CommonConfig $Common `
        -IsInitialImport -InitialImportMode $InitialImportMode

    if ($result.Status -ne 'ok' -and $result.Status -ne 'dry-run') {
        throw ("Initial import failed: {0}" -f $result.Message)
    }

    Write-Host $result.Message -ForegroundColor Green
    Write-Host ("Final bookmark count: {0}" -f $result.FinalBookmarkCount)

    $taskNames = Register-MobaSyncTasks -SyncRoot $SyncRoot -ComputerConfig $cfg -CommonConfig $Common -Force
    Write-Host ("Scheduled task (watch):  {0}" -f $taskNames.Watch)
    Write-Host ("Scheduled task (weekly): {0}" -f $taskNames.Weekly)

    $watchScript = Join-Path $SyncRoot 'app\Watch-MobaXterm.ps1'
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $watchScript) `
            -WindowStyle Hidden | Out-Null
        Write-Host 'Watcher started in background.'
    }
    catch {
        Write-Warning ("Could not start watcher now; it will start at next logon. ({0})" -f $_.Exception.Message)
    }

    Write-Host 'Install completed successfully.' -ForegroundColor Green
    return $result
}

function Edit-CommonSettingsInteractive {
    param([string]$SyncRoot)
    $common = Get-CommonConfig -SyncRoot $SyncRoot
    Write-Header 'Edit common settings (config\common.json)'
    Write-Host 'Press Enter to keep the current value.' -ForegroundColor DarkGray

    $common.ProcessPattern = Read-HostDefault -Prompt 'ProcessPattern' -Default ([string]$common.ProcessPattern)
    $common.AutoTag = Read-HostBool -Prompt 'AutoTag' -Current ([bool]$common.AutoTag)
    $common.DeleteWins = Read-HostBool -Prompt 'DeleteWins' -Current ([bool]$common.DeleteWins)

    $ds = Read-HostDefault -Prompt 'DebounceSeconds' -Default ([string]$common.DebounceSeconds)
    if ($ds -match '^\d+$') { $common.DebounceSeconds = [int]$ds }

    $bc = Read-HostDefault -Prompt 'BackupCount' -Default ([string]$common.BackupCount)
    if ($bc -match '^\d+$') { $common.BackupCount = [int]$bc }

    $md = Read-HostDefault -Prompt 'MassDeleteLimitPercent' -Default ([string]$common.MassDeleteLimitPercent)
    if ($md -match '^\d+$') { $common.MassDeleteLimitPercent = [int]$md }

    $days = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
    Write-Host ("  WeeklyDay options: {0}" -f ($days -join ', ')) -ForegroundColor DarkGray
    $wd = Read-HostDefault -Prompt 'WeeklyDay' -Default ([string]$common.WeeklyDay)
    if ($days -contains $wd) {
        $common.WeeklyDay = $wd
    }
    else {
        Write-Host '  Invalid day - kept previous.' -ForegroundColor Yellow
    }

    $wt = Read-HostDefault -Prompt 'WeeklyTime (HH:mm)' -Default ([string]$common.WeeklyTime)
    if ($wt -match '^\d{1,2}:\d{2}$') {
        $common.WeeklyTime = $wt
    }
    else {
        Write-Host '  Invalid time - kept previous.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'New common.json:' -ForegroundColor White
    Write-Host ("  ProcessPattern={0}" -f $common.ProcessPattern)
    Write-Host ("  AutoTag={0}  DeleteWins={1}" -f $common.AutoTag, $common.DeleteWins)
    Write-Host ("  DebounceSeconds={0}  BackupCount={1}  MassDeleteLimitPercent={2}" -f `
            $common.DebounceSeconds, $common.BackupCount, $common.MassDeleteLimitPercent)
    Write-Host ("  Weekly={0} {1}" -f $common.WeeklyDay, $common.WeeklyTime)

    if (Read-HostYesNo -Prompt 'Save common.json?' -Default $true) {
        Save-CommonConfig -SyncRoot $SyncRoot -Config $common
        Write-Host 'Saved.' -ForegroundColor Green
        Write-Host 'Note: weekly schedule of already registered tasks is updated on next Install/Reinstall.' -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Not saved.' -ForegroundColor Yellow
    }
}

function Edit-ComputerSettingsInteractive {
    param(
        [string]$SyncRoot,
        [string]$ComputerName
    )
    $cfgPath = Get-ComputerConfigPath -SyncRoot $SyncRoot -ComputerName $ComputerName
    $cfg = Get-ComputerConfig -SyncRoot $SyncRoot -ComputerName $ComputerName

    Write-Header 'Edit this computer settings'
    if ($null -eq $cfg) {
        Write-Host 'No config yet for this PC. Creating a draft (Initialized stays false until Install).' -ForegroundColor Yellow
        $cfg = [pscustomobject]@{
            ComputerName = $ComputerName
            NodeId       = [Guid]::NewGuid().ToString()
            Tag          = ''
            IniPath      = ''
            Enabled      = $true
            Initialized  = $false
            _ConfigPath  = $cfgPath
        }
    }

    Write-Host ("  ComputerName: {0} (from Windows, not editable)" -f $ComputerName) -ForegroundColor DarkGray
    Write-Host ("  NodeId:       {0}" -f $cfg.NodeId) -ForegroundColor DarkGray
    Write-Host 'Press Enter to keep the current value.' -ForegroundColor DarkGray

    $tag = Resolve-InstallTag -Preferred $cfg.Tag -SyncRoot $SyncRoot -ComputerName $ComputerName -ExistingCfg $cfg
    $ini = Resolve-InstallIniPath -Preferred $cfg.IniPath -ExistingCfg $cfg
    $enabled = Read-HostBool -Prompt 'Enabled' -Current ([bool]$cfg.Enabled)

    $cfg.Tag = $tag
    $cfg.IniPath = $ini
    $cfg.Enabled = $enabled

    Write-Host ''
    Write-Host ("  Tag={0}" -f $cfg.Tag)
    Write-Host ("  IniPath={0}" -f $cfg.IniPath)
    Write-Host ("  Enabled={0}  Initialized={1}" -f $cfg.Enabled, $cfg.Initialized)

    if (Read-HostYesNo -Prompt ("Save {0}?" -f $cfgPath) -Default $true) {
        Save-ComputerConfig -Path $cfgPath -Config $cfg
        Write-Host 'Saved.' -ForegroundColor Green
        if (-not [bool]$cfg.Initialized) {
            Write-Host 'Initialized=false - run Install from the menu when ready.' -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host 'Not saved.' -ForegroundColor Yellow
    }
}

function Start-UninstallInteractive {
    param([string]$SyncRoot)
    $script = Join-Path $SyncRoot 'app\Uninstall-MobaSync.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Host "Uninstall script missing: $script" -ForegroundColor Red
        return
    }
    if (-not (Read-HostYesNo -Prompt 'Remove scheduled tasks and stop watcher for this PC?' -Default $false)) {
        Write-Host 'Cancelled.'
        return
    }
    & $script
}

function Show-MainMenu {
    param(
        [string]$SyncRoot,
        [string]$ComputerName,
        [string]$DefaultTag,
        [string]$DefaultIniPath,
        [string]$InitialImportMode
    )

    while ($true) {
        $common = Get-CommonConfig -SyncRoot $SyncRoot
        $cfg = Get-ComputerConfig -SyncRoot $SyncRoot -ComputerName $ComputerName

        Write-Header 'MobaBookmarkSync'
        Write-Host ("  Computer: {0}" -f $ComputerName)
        Write-Host ("  SyncRoot: {0}" -f $SyncRoot)
        if ($null -eq $cfg) {
            Write-Host '  State:    not installed' -ForegroundColor Yellow
        }
        elseif (-not [bool]$cfg.Initialized) {
            Write-Host ("  State:    configured, not initialized (Tag={0})" -f $cfg.Tag) -ForegroundColor Yellow
        }
        else {
            Write-Host ("  State:    installed (Tag={0}, Enabled={1})" -f $cfg.Tag, $cfg.Enabled) -ForegroundColor Green
        }
        Write-Host ''
        Write-Host '  1) DryRun - preview merge (no changes)'
        Write-Host '  2) Install / Reinstall'
        Write-Host '  3) Edit common settings (common.json)'
        Write-Host '  4) Edit this computer (Tag, IniPath, Enabled)'
        Write-Host '  5) Show status'
        Write-Host '  6) Run sync now (Invoke-MobaSync)'
        Write-Host '  7) Uninstall from this computer'
        Write-Host '  0) Exit'
        Write-Host ''
        $choice = Read-Host 'Select'

        try {
            switch ($choice) {
                '1' {
                    Write-Header 'DryRun'
                    Invoke-InstallFlow -SyncRoot $SyncRoot -ComputerName $ComputerName -Common $common `
                        -Tag $DefaultTag -IniPath $DefaultIniPath -InitialImportMode $InitialImportMode `
                        -DryRun -PromptConfirm:$false | Out-Null
                    Pause-Enter
                }
                '2' {
                    Write-Header 'Install / Reinstall'
                    Invoke-InstallFlow -SyncRoot $SyncRoot -ComputerName $ComputerName -Common $common `
                        -Tag $DefaultTag -IniPath $DefaultIniPath -InitialImportMode $InitialImportMode `
                        -ForceReinstall -PromptConfirm | Out-Null
                    Pause-Enter
                }
                '3' {
                    Edit-CommonSettingsInteractive -SyncRoot $SyncRoot
                    Pause-Enter
                }
                '4' {
                    Edit-ComputerSettingsInteractive -SyncRoot $SyncRoot -ComputerName $ComputerName
                    Pause-Enter
                }
                '5' {
                    Show-Status -SyncRoot $SyncRoot -ComputerName $ComputerName -Common $common -Cfg $cfg
                    Pause-Enter
                }
                '6' {
                    $invoke = Join-Path $SyncRoot 'app\Invoke-MobaSync.ps1'
                    Write-Header 'Manual sync'
                    & $invoke -Reason 'InteractiveMenu'
                    Pause-Enter
                }
                '7' {
                    Start-UninstallInteractive -SyncRoot $SyncRoot
                    Pause-Enter
                }
                '0' { return }
                default {
                    Write-Host 'Unknown option.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }
        catch {
            Write-Host ''
            Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Pause-Enter
        }
    }
}

# -----------------------------------------------------------------------------
# Entry
# -----------------------------------------------------------------------------

try {
    $syncRoot = Find-SyncRoot -StartPath $PSScriptRoot
}
catch {
    Write-Error $_.Exception.Message
    exit 2
}

try {
    Test-RequiredFiles -SyncRoot $syncRoot
}
catch {
    Write-Error $_.Exception.Message
    exit 2
}

$common = Get-CommonConfig -SyncRoot $syncRoot
$computerName = [Environment]::MachineName

$cliMode = (-not $Interactive) -and (
    $PSBoundParameters.ContainsKey('Tag') -or
    $PSBoundParameters.ContainsKey('IniPath') -or
    $DryRun -or
    $ForceReinstall
)

if (-not $cliMode) {
    Show-MainMenu -SyncRoot $syncRoot -ComputerName $computerName `
        -DefaultTag $Tag -DefaultIniPath $IniPath -InitialImportMode $InitialImportMode
    exit 0
}

# Non-interactive / classic CLI path
try {
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = Read-HostRequired -Prompt 'Enter unique Tag (e.g. RM, MITX, LAPTOP)'
    }
    if ([string]::IsNullOrWhiteSpace($IniPath)) {
        $guess = Find-DefaultMobaIniPath
        if ($guess) {
            $IniPath = Read-HostDefault -Prompt 'Full path to MobaXterm.ini' -Default $guess
        }
        else {
            $IniPath = Read-HostRequired -Prompt 'Full path to MobaXterm.ini'
        }
    }

    Invoke-InstallFlow -SyncRoot $syncRoot -ComputerName $computerName -Common $common `
        -Tag $Tag -IniPath $IniPath -InitialImportMode $InitialImportMode `
        -ForceReinstall:$ForceReinstall -DryRun:$DryRun -PromptConfirm:$false | Out-Null
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
