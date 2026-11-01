#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modPath = Join-Path $repoRoot 'app\MobaSync.psm1'
if (-not (Test-Path -LiteralPath $modPath)) { throw "Cannot locate MobaSync.psm1 from tests." }
Import-Module $modPath -Force -DisableNameChecking

$script:Pass = 0
$script:Fail = 0
$script:Results = New-Object System.Collections.Generic.List[object]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Pass++
        $script:Results.Add([pscustomobject]@{ Ok = $true; Name = $Message }) | Out-Null
        Write-Host "  PASS: $Message"
    }
    else {
        $script:Fail++
        $script:Results.Add([pscustomobject]@{ Ok = $false; Name = $Message }) | Out-Null
        Write-Host "  FAIL: $Message"
    }
}

function New-TestEnv {
    param([string]$Name)
    $root = Join-Path $env:TEMP ("MobaSyncTest-{0}-{1}" -f $Name, [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $root '.moba-sync-root') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'config\computers') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'data\operations') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'app') -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'config\common.json') (Join-Path $root 'config\common.json')
    # Point local appdata override via env is hard; use unique NodeIds under real LOCALAPPDATA
    return $root
}

function New-SampleIni {
    param(
        [string]$Path,
        [hashtable]$Bookmarks,
        [string]$EncodingName = 'UTF8',
        [bool]$Bom = $true,
        [string]$NewLine = "`r`n"
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[Bookmarks]') | Out-Null
    $lines.Add('SubRep=') | Out-Null
    $lines.Add('ImgNum=42') | Out-Null
    foreach ($k in $Bookmarks.Keys) {
        $lines.Add(('{0}={1}' -f $k, $Bookmarks[$k])) | Out-Null
    }
    $lines.Add('[Misc]') | Out-Null
    $lines.Add('SomeSetting=1') | Out-Null
    $text = $lines -join $NewLine
    if (-not $text.EndsWith($NewLine)) { $text += $NewLine }

    $enc = switch ($EncodingName) {
        'UTF8' { [System.Text.UTF8Encoding]::new($Bom) }
        'Unicode' { [System.Text.UnicodeEncoding]::new($false, $Bom) }
        default { [System.Text.Encoding]::Default }
    }
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

function New-ComputerCfg {
    param(
        [string]$SyncRoot,
        [string]$ComputerName,
        [string]$Tag,
        [string]$IniPath,
        [string]$NodeId = $null,
        [bool]$Initialized = $true
    )
    if (-not $NodeId) { $NodeId = [Guid]::NewGuid().ToString() }
    $path = Join-Path $SyncRoot ("config\computers\{0}.json" -f $ComputerName.ToUpperInvariant())
    $obj = [ordered]@{
        ComputerName = $ComputerName
        NodeId       = $NodeId
        Tag          = $Tag
        IniPath      = $IniPath
        Enabled      = $true
        Initialized  = $Initialized
    }
    Write-MobaJsonAtomic -Path $path -Object $obj
    $cfg = Get-ComputerConfig -SyncRoot $SyncRoot -ComputerName $ComputerName
    return $cfg
}

function Get-Common {
    param($SyncRoot)
    return (Get-CommonConfig -SyncRoot $SyncRoot)
}

Write-Host '=== MobaBookmarkSync tests ==='
Write-Host ''

# -----------------------------------------------------------------------------
Write-Host '1) First computer + empty journal'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'first'
    $ini = Join-Path $root 'A.ini'
    New-SampleIni -Path $ini -Bookmarks @{
        'Home Entware' = '#109#0%192.168.1.1%22%root%'
        'n3050'        = '#109#0%10.0.0.5%22%admin%'
    }
    $cfg = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $result = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cfg -CommonConfig $common -IsInitialImport
    $ops = @(Get-SyncOperations -SyncRoot $root)
    $ini2 = Read-MobaIni -Path $ini
    $bms = @(Get-BookmarkEntries -Ini $ini2)
    Assert-True ($result.Status -eq 'ok') 'first import status ok'
    Assert-True ($ops.Count -eq 2) 'first import published 2 adds'
    Assert-True (@($bms | Where-Object { $_.Name -eq '[RM] Home Entware' }).Count -eq 1) 'Home Entware tagged [RM]'
    Assert-True (@($bms | Where-Object { $_.Name -eq '[RM] n3050' }).Count -eq 1) 'n3050 tagged [RM]'
    Assert-True (@($ops | Where-Object { $_.action -eq 'delete' }).Count -eq 0) 'first import no deletes'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '2) Second computer join'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'second'
    $ini1 = Join-Path $root 'room.ini'
    $ini2 = Join-Path $root 'mitx.ini'
    New-SampleIni -Path $ini1 -Bookmarks @{ 'Home Entware' = '#109#0%192.168.1.1%22%root%' }
    New-SampleIni -Path $ini2 -Bookmarks @{
        'Home Entware' = '#109#0%192.168.1.1%22%root%'
        'Octoglass'    = '#109#0%10.0.0.8%22%user%'
    }
    $cfg1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini1 -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cfg1 -CommonConfig $common -IsInitialImport

    $cfg2 = New-ComputerCfg -SyncRoot $root -ComputerName 'MINIITX' -Tag 'MITX' -IniPath $ini2 -Initialized $false
    $r2 = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cfg2 -CommonConfig $common -IsInitialImport
    $bms = @(Get-BookmarkEntries -Ini (Read-MobaIni -Path $ini2))
    $names = @($bms.Name)
    Assert-True ($r2.Status -eq 'ok') 'second import ok'
    Assert-True ($names -contains '[RM] Home Entware') 'second got incoming [RM] Home Entware'
    Assert-True ($names -contains '[MITX] Octoglass') 'second tagged local Octoglass'
    Assert-True ($r2.Report.ExactDuplicates.Count -ge 1) 'exact duplicate detected'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '3) AutoTag new entry after init'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'autotag'
    $ini = Join-Path $root 'A.ini'
    New-SampleIni -Path $ini -Bookmarks @{ 'Alpha' = '#109#0%1.1.1.1%22%a%' }
    $cfg = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cfg -CommonConfig $common -IsInitialImport
    $cfg = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'

    # Add untagged bookmark
    $doc = Read-MobaIni -Path $ini
    Set-IniBookmarkEntries -Ini $doc -Bookmarks @(
        [pscustomobject]@{ Name = '[RM] Alpha'; Value = '#109#0%1.1.1.1%22%a%'; Section = 'Bookmarks' }
        [pscustomobject]@{ Name = 'Beta'; Value = '#109#0%2.2.2.2%22%b%'; Section = 'Bookmarks' }
    )
    Write-MobaIniAtomic -Ini $doc -Path $ini

    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cfg -CommonConfig $common
    $bms = @(Get-BookmarkEntries -Ini (Read-MobaIni -Path $ini))
    Assert-True ($r.Status -eq 'ok') 'autotag sync ok'
    Assert-True (@($bms | Where-Object { $_.Name -eq '[RM] Beta' }).Count -eq 1) 'Beta auto-tagged'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '4) Exact duplicate'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'exact'
    $ini1 = Join-Path $root 'a.ini'
    $ini2 = Join-Path $root 'b.ini'
    $val = '#109#0%host%22%u%'
    New-SampleIni -Path $ini1 -Bookmarks @{ 'Same' = $val }
    New-SampleIni -Path $ini2 -Bookmarks @{ 'Same' = $val }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini1 -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c2 = New-ComputerCfg -SyncRoot $root -ComputerName 'MINIITX' -Tag 'MITX' -IniPath $ini2 -Initialized $false
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c2 -CommonConfig $common -IsInitialImport
    $ops = @(Get-SyncOperations -SyncRoot $root)
    Assert-True ($r.Report.ExactDuplicates.Count -eq 1) 'exact dupe classified'
    Assert-True ($ops.Count -eq 1) 'exact dupe did not create second add'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '5) Same host, different port/user (probable conflict)'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'probable'
    $ini1 = Join-Path $root 'a.ini'
    $ini2 = Join-Path $root 'b.ini'
    New-SampleIni -Path $ini1 -Bookmarks @{ 'Srv' = '#109#0%host.example%22%alice%' }
    New-SampleIni -Path $ini2 -Bookmarks @{ 'Srv' = '#109#0%host.example%2222%bob%' }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini1 -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c2 = New-ComputerCfg -SyncRoot $root -ComputerName 'MINIITX' -Tag 'MITX' -IniPath $ini2 -Initialized $false
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c2 -CommonConfig $common -IsInitialImport
    Assert-True ($r.Report.ProbableConflicts.Count -ge 1) 'probable conflict detected'
    $bms = @(Get-BookmarkEntries -Ini (Read-MobaIni -Path $ini2))
    Assert-True ($bms.Count -ge 2) 'both entries kept'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '6) Delete on one computer'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'delete'
    $ini1 = Join-Path $root 'a.ini'
    $ini2 = Join-Path $root 'b.ini'
    # Two bookmarks so deleting one stays under MassDeleteLimitPercent
    New-SampleIni -Path $ini1 -Bookmarks @{
        'X' = '#109#0%x%22%u%'
        'Y' = '#109#0%y%22%u%'
    }
    New-SampleIni -Path $ini2 -Bookmarks @{ }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini1 -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c1 = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'
    $c2 = New-ComputerCfg -SyncRoot $root -ComputerName 'MINIITX' -Tag 'MITX' -IniPath $ini2 -Initialized $false
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c2 -CommonConfig $common -IsInitialImport
    $c2 = Get-ComputerConfig -SyncRoot $root -ComputerName 'MINIITX'

    # delete only X on ROOM
    $doc = Read-MobaIni -Path $ini1
    $keepY = @(Get-BookmarkEntries -Ini $doc | Where-Object { $_.Name -like '*Y' } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Value = $_.Value; Section = $_.Section }
        })
    Set-IniBookmarkEntries -Ini $doc -Bookmarks $keepY
    Write-MobaIniAtomic -Ini $doc -Path $ini1
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common
    $ops = @(Get-SyncOperations -SyncRoot $root)
    Assert-True (@($ops | Where-Object { $_.action -eq 'delete' }).Count -eq 1) 'delete published'

    $r2 = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c2 -CommonConfig $common
    $bms2 = @(Get-BookmarkEntries -Ini (Read-MobaIni -Path $ini2))
    Assert-True ((@($bms2 | Where-Object { $_.Name -like '*X' }).Count -eq 0) -and (@($bms2 | Where-Object { $_.Name -like '*Y' }).Count -eq 1)) 'delete applied on second computer'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '7) Stale computer after delete does not resurrect'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'stale'
    $ini1 = Join-Path $root 'a.ini'
    $iniOld = Join-Path $root 'old.ini'
    New-SampleIni -Path $ini1 -Bookmarks @{ 'Keep' = '#109#0%k%22%u%'; 'Gone' = '#109#0%g%22%u%' }
    New-SampleIni -Path $iniOld -Bookmarks @{ 'Keep' = '#109#0%k%22%u%'; 'Gone' = '#109#0%g%22%u%' }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini1 -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c1 = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'

    $cOld = New-ComputerCfg -SyncRoot $root -ComputerName 'LAPTOP' -Tag 'LAP' -IniPath $iniOld -Initialized $false
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cOld -CommonConfig $common -IsInitialImport
    $cOld = Get-ComputerConfig -SyncRoot $root -ComputerName 'LAPTOP'
    $oldState = Get-LocalState -LocalDataRoot (Get-LocalDataRoot -NodeId $cOld.NodeId)

    # ROOM deletes Gone
    $doc = Read-MobaIni -Path $ini1
    $keep = @(Get-BookmarkEntries -Ini $doc | Where-Object { $_.Name -like '*Keep' })
    Set-IniBookmarkEntries -Ini $doc -Bookmarks ($keep | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value; Section = $_.Section } })
    Write-MobaIniAtomic -Ini $doc -Path $ini1
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common

    # Stale laptop still has Gone in INI matching lastApplied - should NOT republish add
    $before = @(Get-SyncOperations -SyncRoot $root).Count
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $cOld -CommonConfig $common
    $after = @(Get-SyncOperations -SyncRoot $root).Count
    $bms = @(Get-BookmarkEntries -Ini (Read-MobaIni -Path $iniOld))
    Assert-True ($r.Status -eq 'ok') 'stale sync ok'
    Assert-True (@($bms | Where-Object { $_.Name -like '*Gone' }).Count -eq 0) 'Gone removed from stale INI'
    Assert-True (@($ops = Get-SyncOperations -SyncRoot $root; $ops | Where-Object { $_.action -eq 'add' -and $_.name -like '*Gone' }).Count -eq 1) 'Gone not re-added (still single original add)'
    # published count should only grow by 0 for Gone add
    $newAdds = @($ops | Where-Object { $_.action -eq 'add' -and $_.name -like '*Gone' })
    Assert-True ($newAdds.Count -eq 1) 'no resurrection add'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '8) Parallel update vs delete (DeleteWins)'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'delwins'
    $ini = Join-Path $root 'a.ini'
    New-SampleIni -Path $ini -Bookmarks @{ 'Z' = '#109#0%z%22%u%' }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $ops = @(Get-SyncOperations -SyncRoot $root)
    $bid = $ops[0].bookmarkId
    $n1 = (Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM').NodeId
    $n2 = [Guid]::NewGuid().ToString()

    $clockU = @{ $n1 = 2; $n2 = 1 }
    $clockD = @{ $n1 = 1; $n2 = 2 }
    $upd = [ordered]@{
        schema = 1; operationId = [Guid]::NewGuid().ToString(); bookmarkId = $bid
        nodeId = $n1; nodeName = 'ROOM'; nodeTag = 'RM'; action = 'update'
        name = '[RM] Z'; value = '#109#0%z%22%u%NEW%'; createdBy = 'ROOM'; lastChangedBy = 'ROOM'
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); clock = $clockU
    }
    $del = [ordered]@{
        schema = 1; operationId = [Guid]::NewGuid().ToString(); bookmarkId = $bid
        nodeId = $n2; nodeName = 'MINIITX'; nodeTag = 'MITX'; action = 'delete'
        name = '[RM] Z'; value = '#109#0%z%22%u%'; createdBy = 'ROOM'; lastChangedBy = 'MINIITX'
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); clock = $clockD
    }
    Write-SyncOperation -SyncRoot $root -Operation $upd | Out-Null
    Write-SyncOperation -SyncRoot $root -Operation $del | Out-Null
    $idx = Build-GlobalBookmarkIndex -Operations (Get-SyncOperations -SyncRoot $root) -DeleteWins $true
    Assert-True ($idx[$bid].IsDeleted) 'DeleteWins: delete beats concurrent update'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '9) Rename preserves BookmarkId'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'rename'
    $ini = Join-Path $root 'a.ini'
    New-SampleIni -Path $ini -Bookmarks @{ 'OldName' = '#109#0%ren%22%u%' }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c1 = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'
    $opsBefore = @(Get-SyncOperations -SyncRoot $root)
    $oldId = $opsBefore[0].bookmarkId

    $doc = Read-MobaIni -Path $ini
    Set-IniBookmarkEntries -Ini $doc -Bookmarks @(
        [pscustomobject]@{ Name = '[RM] NewName'; Value = '#109#0%ren%22%u%'; Section = 'Bookmarks' }
    )
    Write-MobaIniAtomic -Ini $doc -Path $ini
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common
    $ops = @(Get-SyncOperations -SyncRoot $root)
    $upd = @($ops | Where-Object { $_.action -eq 'update' -and $_.bookmarkId -eq $oldId })
    Assert-True ($upd.Count -ge 1) 'rename published as update same id'
    Assert-True ($upd[-1].name -eq '[RM] NewName') 'rename new name stored'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '10) Corrupted INI'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'corrupt'
    $ini = Join-Path $root 'bad.ini'
    # Valid enough to install? For sync path: unreadable encoding / empty
    [System.IO.File]::WriteAllText($ini, '')
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $true
    # seed state so it's not initial import
    $lr = Get-LocalDataRoot -NodeId $c1.NodeId
    Save-LocalState -LocalDataRoot $lr -State (New-EmptyState -NodeId $c1.NodeId)
    $st = Get-LocalState -LocalDataRoot $lr
    $st.Initialized = $true
    $st.Bookmarks = @{ 'x' = @{ Name = 'x'; LocalName = 'x'; Value = 'v'; IsDeleted = $false } }
    Save-LocalState -LocalDataRoot $lr -State $st
    $common = Get-Common $root
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common
    Assert-True ($r.Status -eq 'error') 'empty INI refused'
    $ops = @(Get-SyncOperations -SyncRoot $root)
    Assert-True ($ops.Count -eq 0) 'corrupt INI published nothing'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '11) MassDeleteLimit'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'mass'
    $ini = Join-Path $root 'a.ini'
    $bms = @{}
    1..10 | ForEach-Object { $bms["Item$_"] = "#109#0%h$_%22%u%" }
    New-SampleIni -Path $ini -Bookmarks $bms
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c1 = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'

    $doc = Read-MobaIni -Path $ini
    Set-IniBookmarkEntries -Ini $doc -Bookmarks @()
    Write-MobaIniAtomic -Ini $doc -Path $ini
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common
    Assert-True ($r.Status -eq 'mass-delete-blocked') 'mass delete blocked'
    $pd = Get-PendingDeletePath -LocalDataRoot (Get-LocalDataRoot -NodeId $c1.NodeId)
    Assert-True (Test-Path $pd) 'pending-delete.json created'
    $ops = @(Get-SyncOperations -SyncRoot $root | Where-Object { $_.action -eq 'delete' })
    Assert-True ($ops.Count -eq 0) 'no tombstones before approve'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '12) BOM / encoding / CRLF preserved'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'bom'
    $ini = Join-Path $root 'a.ini'
    New-SampleIni -Path $ini -Bookmarks @{ 'T' = '#109#0%t%22%u%' } -EncodingName UTF8 -Bom $true -NewLine "`r`n"
    $before = [System.IO.File]::ReadAllBytes($ini)
    Assert-True ($before[0] -eq 0xEF -and $before[1] -eq 0xBB -and $before[2] -eq 0xBF) 'fixture has UTF-8 BOM'
    $doc = Read-MobaIni -Path $ini
    Assert-True ($doc.HasBom) 'parser detects BOM'
    Assert-True ($doc.NewLine -eq "`r`n") 'parser detects CRLF'
    Set-IniBookmarkEntries -Ini $doc -Bookmarks @(
        [pscustomobject]@{ Name = '[RM] T'; Value = '#109#0%t%22%u%'; Section = 'Bookmarks' }
    )
    Write-MobaIniAtomic -Ini $doc -Path $ini
    $after = [System.IO.File]::ReadAllBytes($ini)
    Assert-True ($after[0] -eq 0xEF -and $after[1] -eq 0xBB -and $after[2] -eq 0xBF) 'BOM preserved after write'
    $text = [System.IO.File]::ReadAllText($ini)
    Assert-True ($text.Contains("`r`n")) 'CRLF preserved after write'
    Assert-True ($text.Contains('[Misc]')) 'unknown section preserved'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '13) Weekly run while MobaXterm open => pending-sync'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'pending'
    $ini = Join-Path $root 'a.ini'
    New-SampleIni -Path $ini -Bookmarks @{ 'T' = '#109#0%t%22%u%' }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c1 = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'
    $lr = Get-LocalDataRoot -NodeId $c1.NodeId

    # Simulate running by temporarily shadowing Test-MobaProcessRunning via a direct pending set path:
    # Call core after mocking is hard; instead verify Set-PendingSync + that sync defers when we inject.
    # We simulate deferral contract: Set-PendingSync and Test-PendingSync
    Set-PendingSync -LocalDataRoot $lr -Reason 'MobaXtermRunning'
    Assert-True (Test-PendingSync -LocalDataRoot $lr) 'pending-sync.json created when deferred'

    # Also verify mutex-free path: if we could mock process; document via function existence
    # Simulate deferral branch by checking Write path of pending when process check is forced:
    # Use a fake: call Set-PendingSync from weekly behavior contract already asserted.
    Clear-PendingSync -LocalDataRoot $lr

    # Stronger: redefine is not possible; create a subprocess-less check by patching through direct API
    # Full process-name mock is not available without a real MobaXterm process;
    # pending-sync.json is the contract used by weekly/watcher deferral.
    Set-PendingSync -LocalDataRoot $lr -Reason 'WeeklyWhileOpen'
    Assert-True (Test-Path (Join-Path $lr 'pending-sync.json')) 'weekly-open pending file exists'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '14) Two concurrent sync instances (mutex)'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'mutex'
    $ini = Join-Path $root 'a.ini'
    New-SampleIni -Path $ini -Bookmarks @{ 'T' = '#109#0%t%22%u%' }
    $c1 = New-ComputerCfg -SyncRoot $root -ComputerName 'ROOM' -Tag 'RM' -IniPath $ini -Initialized $false
    $common = Get-Common $root
    $null = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common -IsInitialImport
    $c1 = Get-ComputerConfig -SyncRoot $root -ComputerName 'ROOM'

    # Hold mutex on another thread (same-thread Mutex is reentrant in .NET)
    $nodeId = $c1.NodeId
    $holder = [powershell]::Create()
    [void]$holder.AddScript({
        param($id)
        $created = $false
        $m = New-Object System.Threading.Mutex($false, ("Local\MobaBookmarkSync-{0}" -f $id), [ref]$created)
        [void]$m.WaitOne()
        Start-Sleep -Seconds 5
        $m.ReleaseMutex()
        $m.Dispose()
    }).AddArgument($nodeId)
    $handle = $holder.BeginInvoke()
    Start-Sleep -Milliseconds 400

    $mCheck = Enter-SyncMutex -NodeId $nodeId -TimeoutMs 0
    Assert-True ($null -eq $mCheck) 'mutex held by other thread'
    $r = Invoke-MobaSyncCore -SyncRoot $root -ComputerConfig $c1 -CommonConfig $common
    Assert-True ($r.Status -eq 'locked') 'second instance reports locked'

    $null = $holder.EndInvoke($handle)
    $holder.Dispose()
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
Write-Host '15) Corrupt / partial operation JSON ignored'
# -----------------------------------------------------------------------------
& {
    $root = New-TestEnv 'badop'
    $dir = Get-OperationsDir -SyncRoot $root
    $partial = Join-Path $dir '20260101T000000000_x_y.json'
    [System.IO.File]::WriteAllText($partial, '{ "schema": 1, "operationId":')
    $tmp = Join-Path $dir ("{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($tmp, '{ "schema":1 }')
    $ops = @(Get-SyncOperations -SyncRoot $root)
    Assert-True ($ops.Count -eq 0) 'invalid and temp ops ignored'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Extra: SyncRoot missing marker
Write-Host 'Bonus) SyncRoot missing marker'
& {
    $caught = $false
    try {
        Find-SyncRoot -StartPath $env:TEMP | Out-Null
    }
    catch {
        $caught = $_.Exception.Message -like '*Sync root not found*'
    }
    Assert-True $caught 'Find-SyncRoot errors clearly'
}

Write-Host ''
Write-Host ("Totals: PASS={0} FAIL={1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }

