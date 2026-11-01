#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region SyncRoot & Paths

function Find-SyncRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath
    )

    $current = (Resolve-Path -LiteralPath $StartPath).Path
    while ($true) {
        $marker = Join-Path $current '.moba-sync-root'
        if (Test-Path -LiteralPath $marker) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            throw "Sync root not found: marker .moba-sync-root was not located above '$StartPath'. Nothing was changed."
        }
        $current = $parent
    }
}

function Get-CommonConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncRoot
    )
    $path = Join-Path $SyncRoot 'config\common.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing common config: $path"
    }
    $cfg = ConvertFrom-MobaJsonFile -Path $path
    $cfg | Add-Member -NotePropertyName '_ConfigPath' -NotePropertyValue $path -Force
    return $cfg
}

function Save-CommonConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncRoot,
        [Parameter(Mandatory = $true)]$Config
    )
    $path = Join-Path $SyncRoot 'config\common.json'
    $obj = [ordered]@{
        ProcessPattern          = [string]$Config.ProcessPattern
        AutoTag                 = [bool]$Config.AutoTag
        DeleteWins              = [bool]$Config.DeleteWins
        DebounceSeconds         = [int]$Config.DebounceSeconds
        BackupCount             = [int]$Config.BackupCount
        MassDeleteLimitPercent  = [int]$Config.MassDeleteLimitPercent
        WeeklyDay               = [string]$Config.WeeklyDay
        WeeklyTime              = [string]$Config.WeeklyTime
    }
    Write-MobaJsonAtomic -Path $path -Object $obj
}

function Find-DefaultMobaIniPath {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $candidates = @(
        (Join-Path $docs 'MobaXterm\MobaXterm.ini'),
        (Join-Path $env:APPDATA 'MobaXterm\MobaXterm.ini'),
        (Join-Path $docs 'MobaXterm.ini')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-ComputerConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncRoot,
        [string]$ComputerName = [Environment]::MachineName
    )
    return (Join-Path $SyncRoot ("config\computers\{0}.json" -f $ComputerName.ToUpperInvariant()))
}

function Get-AllComputerConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncRoot
    )
    $dir = Join-Path $SyncRoot 'config\computers'
    $result = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $result }
    Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | ForEach-Object {
        try {
            $cfg = ConvertFrom-MobaJsonFile -Path $_.FullName
            if ($null -ne $cfg) {
                $cfg | Add-Member -NotePropertyName '_ConfigPath' -NotePropertyValue $_.FullName -Force
                $result += $cfg
            }
        }
        catch {
            # ignore invalid configs during discovery
        }
    }
    return $result
}

function Get-ComputerConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncRoot,
        [string]$ComputerName = [Environment]::MachineName
    )
    $path = Get-ComputerConfigPath -SyncRoot $SyncRoot -ComputerName $ComputerName
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $cfg = ConvertFrom-MobaJsonFile -Path $path
    $cfg | Add-Member -NotePropertyName '_ConfigPath' -NotePropertyValue $path -Force
    return $cfg
}

function Save-ComputerConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Config
    )
    $obj = [ordered]@{
        ComputerName = [string]$Config.ComputerName
        NodeId       = [string]$Config.NodeId
        Tag          = [string]$Config.Tag
        IniPath      = [string]$Config.IniPath
        Enabled      = [bool]$Config.Enabled
        Initialized  = [bool]$Config.Initialized
    }
    Write-MobaJsonAtomic -Path $Path -Object $obj
}

function Get-LocalDataRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeId
    )
    $root = Join-Path $env:LOCALAPPDATA ("MobaBookmarkSync\{0}" -f $NodeId)
    foreach ($sub in @('', 'logs', 'backups')) {
        $p = if ($sub) { Join-Path $root $sub } else { $root }
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
    return $root
}

function Get-OperationsDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncRoot
    )
    $dir = Join-Path $SyncRoot 'data\operations'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

#endregion

#region JSON helpers

function ConvertFrom-MobaJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Empty JSON file: $Path"
    }
    return ($raw | ConvertFrom-Json)
}

function ConvertTo-MobaJson {
    param($Object)
    # Depth high enough for nested clocks/bookmarks; Compress for stable atomic files
    return ($Object | ConvertTo-Json -Depth 12 -Compress:$false)
}

function Complete-AtomicFileReplace {
    param(
        [Parameter(Mandatory = $true)][string]$TempPath,
        [Parameter(Mandatory = $true)][string]$FinalPath
    )
    if (-not (Test-Path -LiteralPath $FinalPath)) {
        [System.IO.File]::Move($TempPath, $FinalPath)
        return
    }
    # File.Replace(..., null) breaks under Windows PowerShell ($null -> illegal path).
    # Use a real backup path, then delete the backup.
    $bak = Join-Path (Split-Path -Parent $FinalPath) (
        '{0}.bak-{1}' -f [IO.Path]::GetFileName($FinalPath), [Guid]::NewGuid().ToString('N')
    )
    [System.IO.File]::Replace($TempPath, $FinalPath, $bak)
    if (Test-Path -LiteralPath $bak) {
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
    }
}

function Write-MobaJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ConvertTo-MobaJson -Object $Object
    $tmp = Join-Path $dir ("{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        $probe = [System.IO.File]::ReadAllText($tmp)
        if ([string]::IsNullOrWhiteSpace($probe)) {
            throw "Temporary JSON is empty: $tmp"
        }
        $null = $probe | ConvertFrom-Json
        Complete-AtomicFileReplace -TempPath $tmp -FinalPath $Path
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

#endregion

#region Logging

function Write-SyncLog {
    param(
        [Parameter(Mandatory = $true)][string]$LocalDataRoot,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    $logDir = Join-Path $LocalDataRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $day = (Get-Date).ToString('yyyy-MM-dd')
    $file = Join-Path $logDir ("sync-{0}.log" -f $day)
    $line = "{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8
}

#endregion

#region INI Read / Write

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($fs)
            return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
        }
        finally { $fs.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Read-MobaIni {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "INI not found: $Path"
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encodingName = 'UTF8'
    $hasBom = $false
    $offset = 0

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encodingName = 'UTF8'
        $hasBom = $true
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encodingName = 'Unicode'
        $hasBom = $true
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encodingName = 'BigEndianUnicode'
        $hasBom = $true
        $offset = 2
    }
    else {
        # Heuristic: NUL bytes suggest UTF-16 without BOM
        $sampleLen = [Math]::Min($bytes.Length, 200)
        $nulCount = 0
        for ($i = 0; $i -lt $sampleLen; $i++) {
            if ($bytes[$i] -eq 0) { $nulCount++ }
        }
        if ($sampleLen -gt 0 -and ($nulCount / [double]$sampleLen) -gt 0.1) {
            $encodingName = 'Unicode'
        }
        else {
            $encodingName = 'Default' # system ANSI for classic Moba INI
        }
    }

    $enc = switch ($encodingName) {
        'UTF8' { [System.Text.UTF8Encoding]::new($false) }
        'Unicode' { [System.Text.UnicodeEncoding]::new($false, $false) }
        'BigEndianUnicode' { [System.Text.UnicodeEncoding]::new($true, $false) }
        default { [System.Text.Encoding]::Default }
    }

    $text = if ($offset -gt 0) {
        $enc.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    else {
        $enc.GetString($bytes)
    }

    $newLine = "`r`n"
    if ($text -match "`r`n") { $newLine = "`r`n" }
    elseif ($text -match "`n") { $newLine = "`n" }
    elseif ($text -match "`r") { $newLine = "`r" }

    $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $rawLines = $normalized -split "`n", -1

    $sections = New-Object System.Collections.ArrayList
    $current = $null

    foreach ($line in $rawLines) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $current = [pscustomobject]@{
                Name  = $Matches[1]
                Lines = (New-Object System.Collections.ArrayList)
            }
            [void]$sections.Add($current)
            continue
        }
        if ($null -eq $current) {
            $current = [pscustomobject]@{
                Name  = $null
                Lines = (New-Object System.Collections.ArrayList)
            }
            [void]$sections.Add($current)
        }

        $eq = $line.IndexOf('=')
        if ($eq -ge 0) {
            $key = $line.Substring(0, $eq)
            $value = $line.Substring($eq + 1)
            [void]$current.Lines.Add([pscustomobject]@{
                    Kind  = 'entry'
                    Key   = $key
                    Value = $value
                    Raw   = $line
                })
        }
        else {
            [void]$current.Lines.Add([pscustomobject]@{
                    Kind  = 'raw'
                    Key   = $null
                    Value = $null
                    Raw   = $line
                })
        }
    }

    return [pscustomobject]@{
        Path         = $Path
        EncodingName = $encodingName
        HasBom       = $hasBom
        NewLine      = $newLine
        Sha256       = (Get-FileSha256 -Path $Path)
        Sections     = $sections
        RawText      = $text
        ByteLength   = $bytes.Length
    }
}

function ConvertTo-MobaIniText {
    param([Parameter(Mandatory = $true)]$Ini)

    # Join logical lines with the original newline style.
    # A trailing empty raw line (from split -1) preserves a final newline.
    $all = New-Object System.Collections.ArrayList
    foreach ($sec in $Ini.Sections) {
        if ($null -ne $sec.Name) {
            [void]$all.Add('[' + $sec.Name + ']')
        }
        foreach ($ln in $sec.Lines) {
            if ($ln.Kind -eq 'entry') {
                [void]$all.Add($ln.Key + '=' + $ln.Value)
            }
            else {
                [void]$all.Add([string]$ln.Raw)
            }
        }
    }
    return ($all -join $Ini.NewLine)
}

function Write-MobaIniAtomic {
    param(
        [Parameter(Mandatory = $true)]$Ini,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $text = ConvertTo-MobaIniText -Ini $Ini
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ("MobaXterm.{0}.tmp" -f [Guid]::NewGuid().ToString('N'))

    $enc = switch ($Ini.EncodingName) {
        'UTF8' {
            if ($Ini.HasBom) { [System.Text.UTF8Encoding]::new($true) }
            else { [System.Text.UTF8Encoding]::new($false) }
        }
        'Unicode' {
            [System.Text.UnicodeEncoding]::new($false, [bool]$Ini.HasBom)
        }
        'BigEndianUnicode' {
            [System.Text.UnicodeEncoding]::new($true, [bool]$Ini.HasBom)
        }
        default {
            [System.Text.Encoding]::Default
        }
    }

    try {
        [System.IO.File]::WriteAllText($tmp, $text, $enc)
        if (-not (Test-Path -LiteralPath $tmp)) {
            throw "Failed to create temporary INI: $tmp"
        }
        $probe = Read-MobaIni -Path $tmp
        if ($null -eq $probe -or $probe.Sections.Count -lt 0) {
            throw "Temporary INI validation failed."
        }
        Complete-AtomicFileReplace -TempPath $tmp -FinalPath $Path
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Backup-MobaIni {
    param(
        [Parameter(Mandatory = $true)][string]$IniPath,
        [Parameter(Mandatory = $true)][string]$LocalDataRoot,
        [int]$BackupCount = 20
    )
    if (-not (Test-Path -LiteralPath $IniPath)) {
        throw "Cannot backup missing INI: $IniPath"
    }
    $backupDir = Join-Path $LocalDataRoot 'backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $sha = Get-FileSha256 -Path $IniPath
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $name = "MobaXterm_{0}_{1}.ini" -f $stamp, $sha.Substring(0, 12)
    $dest = Join-Path $backupDir $name
    Copy-Item -LiteralPath $IniPath -Destination $dest -Force

    $existing = @(Get-ChildItem -LiteralPath $backupDir -Filter 'MobaXterm_*.ini' -File | Sort-Object LastWriteTime -Descending)
    if ($existing.Count -gt $BackupCount) {
        $existing | Select-Object -Skip $BackupCount | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Path = $dest; Sha256 = $sha }
}

#endregion

#region Bookmark helpers

function Test-IsBookmarkMetaKey {
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return $true }
    $k = $Key.Trim()
    return ($k -eq 'SubRep' -or $k -eq 'ImgNum')
}

function Test-IsBookmarkSection {
    param([string]$SectionName)
    if ([string]::IsNullOrEmpty($SectionName)) { return $false }
    return ($SectionName -eq 'Bookmarks' -or $SectionName -like 'Bookmarks_*' -or $SectionName -like 'Bookmarks*')
}

function Get-BookmarkEntries {
    param([Parameter(Mandatory = $true)]$Ini)

    $list = (New-Object System.Collections.ArrayList)
    foreach ($sec in $Ini.Sections) {
        if (-not (Test-IsBookmarkSection -SectionName $sec.Name)) { continue }
        $idx = 0
        foreach ($ln in $sec.Lines) {
            if ($ln.Kind -ne 'entry') { $idx++; continue }
            if (Test-IsBookmarkMetaKey -Key $ln.Key) { $idx++; continue }
            $list.Add([pscustomobject]@{
                    Section     = $sec.Name
                    Name        = $ln.Key
                    Value       = $ln.Value
                    LineIndex   = $idx
                    SectionObj  = $sec
                    LineObj     = $ln
                }) | Out-Null
            $idx++
        }
    }
    return $list
}

function Get-KnownTags {
    param([Parameter(Mandatory = $true)][string]$SyncRoot)
    $tags = @{}
    foreach ($c in @(Get-AllComputerConfigs -SyncRoot $SyncRoot)) {
        if ($c.Tag) {
            $tags[$c.Tag.ToUpperInvariant()] = [string]$c.Tag
        }
    }
    return $tags
}

function Get-BookmarkTagPrefix {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $null }
    if ($Name -match '^\[([^\]]+)\]\s*(.*)$') {
        return [pscustomobject]@{
            Tag      = $Matches[1]
            BaseName = $Matches[2]
            HasPrefix = $true
        }
    }
    return [pscustomobject]@{
        Tag       = $null
        BaseName  = $Name
        HasPrefix = $false
    }
}

function Add-BookmarkTag {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Tag
    )
    $info = Get-BookmarkTagPrefix -Name $Name
    if ($info.HasPrefix) {
        return $Name
    }
    return ('[{0}] {1}' -f $Tag, $Name.Trim())
}

function Get-BookmarkEndpointFingerprint {
    <#
    .SYNOPSIS
      Best-effort parse of Moba bookmark opaque value for conflict detection only.
      Does NOT rewrite the value.
    #>
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        return [pscustomobject]@{ Protocol = ''; Host = ''; Port = ''; User = ''; Fingerprint = '' }
    }
    # Typical: #109#0%host%22%user%...  or #91#4%...
    $parts = $Value.Split('%')
    $protocol = ''
    $hostName = ''
    $port = ''
    $user = ''
    if ($parts.Length -ge 1 -and $parts[0] -match '^#(\d+)#') {
        $protocol = $Matches[1]
    }
    if ($parts.Length -ge 2) { $hostName = $parts[1] }
    if ($parts.Length -ge 3) { $port = $parts[2] }
    if ($parts.Length -ge 4) { $user = $parts[3] }
    $fp = '{0}|{1}|{2}|{3}' -f $protocol.ToLowerInvariant(), $hostName.ToLowerInvariant(), $port, $user.ToLowerInvariant()
    return [pscustomobject]@{
        Protocol    = $protocol
        Host        = $hostName
        Port        = $port
        User        = $user
        Fingerprint = $fp
    }
}

function New-MobaLineList {
    # Comma prevents PowerShell from unrolling / dropping empty ArrayList on return
    , (New-Object System.Collections.ArrayList)
}

function Add-MobaLine {
    param($List, $Item)
    [void]$List.Add($Item)
}

function Set-IniBookmarkEntries {
    param(
        [Parameter(Mandatory = $true)]$Ini,
        [AllowEmptyCollection()][AllowNull()]$Bookmarks,
        [string]$DefaultSection = 'Bookmarks'
    )
    if ($null -eq $Bookmarks) { $Bookmarks = @() }
    else { $Bookmarks = @($Bookmarks) }

    # Remove existing bookmark entries (keep SubRep/ImgNum/raw) from bookmark sections
    foreach ($sec in @($Ini.Sections)) {
        if (-not (Test-IsBookmarkSection -SectionName $sec.Name)) { continue }
        $keep = New-MobaLineList
        foreach ($ln in @($sec.Lines)) {
            if ($null -eq $ln) { continue }
            if ($ln.Kind -eq 'entry' -and -not (Test-IsBookmarkMetaKey -Key $ln.Key)) {
                continue
            }
            Add-MobaLine -List $keep -Item $ln
        }
        # Replace Lines collection with ArrayList for safe mutation
        $sec.Lines = $keep
    }

    # Ensure default section exists
    $target = $null
    foreach ($sec in @($Ini.Sections)) {
        if ($sec.Name -eq $DefaultSection) { $target = $sec; break }
    }
    if ($null -eq $target) {
        $target = [pscustomobject]@{
            Name  = $DefaultSection
            Lines = New-MobaLineList
        }
        Add-MobaLine -List $Ini.Sections -Item $target
        Add-MobaLine -List $target.Lines -Item ([pscustomobject]@{ Kind = 'entry'; Key = 'SubRep'; Value = ''; Raw = 'SubRep=' })
        Add-MobaLine -List $target.Lines -Item ([pscustomobject]@{ Kind = 'entry'; Key = 'ImgNum'; Value = '42'; Raw = 'ImgNum=42' })
    }
    elseif ($null -eq $target.Lines) {
        $target.Lines = New-MobaLineList
    }

    # Place bookmarks: prefer original section if present on object, else default
    $bySection = @{}
    foreach ($b in $Bookmarks) {
        if ($null -eq $b) { continue }
        $secName = $DefaultSection
        if ($null -ne $b.PSObject.Properties['Section'] -and -not [string]::IsNullOrEmpty([string]$b.Section)) {
            $secName = [string]$b.Section
        }
        if (-not $bySection.ContainsKey($secName)) {
            $bySection[$secName] = New-Object System.Collections.ArrayList
        }
        [void]$bySection[$secName].Add($b)
    }

    foreach ($secName in @($bySection.Keys)) {
        $secObj = $null
        foreach ($sec in @($Ini.Sections)) {
            if ($sec.Name -eq $secName) { $secObj = $sec; break }
        }
        if ($null -eq $secObj) {
            $secObj = [pscustomobject]@{
                Name  = $secName
                Lines = New-MobaLineList
            }
            Add-MobaLine -List $Ini.Sections -Item $secObj
            Add-MobaLine -List $secObj.Lines -Item ([pscustomobject]@{ Kind = 'entry'; Key = 'SubRep'; Value = ''; Raw = 'SubRep=' })
            Add-MobaLine -List $secObj.Lines -Item ([pscustomobject]@{ Kind = 'entry'; Key = 'ImgNum'; Value = '42'; Raw = 'ImgNum=42' })
        }
        foreach ($b in @($bySection[$secName])) {
            Add-MobaLine -List $secObj.Lines -Item ([pscustomobject]@{
                    Kind  = 'entry'
                    Key   = [string]$b.Name
                    Value = [string]$b.Value
                    Raw   = ('{0}={1}' -f $b.Name, $b.Value)
                })
        }
    }
}

#endregion

#region Process / Mutex

function Test-MobaProcessRunning {
    param([string]$ProcessPattern = 'MobaXterm*.exe')
    # Match process names that start with MobaXterm and end with .exe semantics via Get-Process
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -like 'MobaXterm*'
        })
    return ($procs.Count -gt 0)
}

function Enter-SyncMutex {
    param(
        [Parameter(Mandatory = $true)][string]$NodeId,
        [int]$TimeoutMs = 0
    )
    $name = 'Local\MobaBookmarkSync-{0}' -f $NodeId
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, $name, [ref]$created)
    $acquired = $false
    try {
        if ($TimeoutMs -le 0) {
            $acquired = $mutex.WaitOne(0)
        }
        else {
            $acquired = $mutex.WaitOne($TimeoutMs)
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-SyncMutex {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() | Out-Null } catch { }
    try { $Mutex.Dispose() } catch { }
}

#endregion

#region State & Operations

function New-EmptyState {
    param(
        [Parameter(Mandatory = $true)][string]$NodeId
    )
    return [ordered]@{
        schema              = 1
        Initialized         = $false
        NodeId              = $NodeId
        SeenClock           = @{}
        Bookmarks           = @{}
        LastSyncUtc         = $null
        LastAppliedIniHash  = $null
    }
}

function Get-LocalState {
    param([Parameter(Mandatory = $true)][string]$LocalDataRoot)
    $path = Join-Path $LocalDataRoot 'state.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return (ConvertFrom-MobaJsonFile -Path $path)
}

function Save-LocalState {
    param(
        [Parameter(Mandatory = $true)][string]$LocalDataRoot,
        [Parameter(Mandatory = $true)]$State
    )
    $path = Join-Path $LocalDataRoot 'state.json'
    Write-MobaJsonAtomic -Path $path -Object $State
}

function Get-PendingSyncPath {
    param([Parameter(Mandatory = $true)][string]$LocalDataRoot)
    return (Join-Path $LocalDataRoot 'pending-sync.json')
}

function Set-PendingSync {
    param(
        [Parameter(Mandatory = $true)][string]$LocalDataRoot,
        [string]$Reason = 'deferred'
    )
    $obj = [ordered]@{
        schema        = 1
        reason        = $Reason
        requestedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-MobaJsonAtomic -Path (Get-PendingSyncPath -LocalDataRoot $LocalDataRoot) -Object $obj
}

function Clear-PendingSync {
    param([Parameter(Mandatory = $true)][string]$LocalDataRoot)
    $p = Get-PendingSyncPath -LocalDataRoot $LocalDataRoot
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
    }
}

function Test-PendingSync {
    param([Parameter(Mandatory = $true)][string]$LocalDataRoot)
    return (Test-Path -LiteralPath (Get-PendingSyncPath -LocalDataRoot $LocalDataRoot))
}

function Get-PendingDeletePath {
    param([Parameter(Mandatory = $true)][string]$LocalDataRoot)
    return (Join-Path $LocalDataRoot 'pending-delete.json')
}

function ConvertTo-Hashtable {
    param($Object)
    $h = @{}
    if ($null -eq $Object) { return $h }
    if ($Object -is [hashtable]) { return $Object }
    foreach ($p in $Object.PSObject.Properties) {
        $h[$p.Name] = $p.Value
    }
    return $h
}

function Merge-VersionClock {
    param($A, $B)
    $ha = ConvertTo-Hashtable $A
    $hb = ConvertTo-Hashtable $B
    $keys = @($ha.Keys + $hb.Keys | Select-Object -Unique)
    $out = @{}
    foreach ($k in $keys) {
        $va = 0; $vb = 0
        if ($ha.ContainsKey($k)) { $va = [int]$ha[$k] }
        if ($hb.ContainsKey($k)) { $vb = [int]$hb[$k] }
        $out[$k] = [Math]::Max($va, $vb)
    }
    return $out
}

function Test-ClockDominates {
    param($A, $B)
    # true if A >= B in all components and > in at least one
    $ha = ConvertTo-Hashtable $A
    $hb = ConvertTo-Hashtable $B
    $keys = @($ha.Keys + $hb.Keys | Select-Object -Unique)
    $strict = $false
    foreach ($k in $keys) {
        $va = 0; $vb = 0
        if ($ha.ContainsKey($k)) { $va = [int]$ha[$k] }
        if ($hb.ContainsKey($k)) { $vb = [int]$hb[$k] }
        if ($va -lt $vb) { return $false }
        if ($va -gt $vb) { $strict = $true }
    }
    return $strict
}

function Test-ClocksConcurrent {
    param($A, $B)
    return -not (Test-ClockDominates -A $A -B $B) -and -not (Test-ClockDominates -A $B -B $A) -and -not (Test-ClocksEqual -A $A -B $B)
}

function Test-ClocksEqual {
    param($A, $B)
    $ha = ConvertTo-Hashtable $A
    $hb = ConvertTo-Hashtable $B
    $keys = @($ha.Keys + $hb.Keys | Select-Object -Unique)
    foreach ($k in $keys) {
        $va = 0; $vb = 0
        if ($ha.ContainsKey($k)) { $va = [int]$ha[$k] }
        if ($hb.ContainsKey($k)) { $vb = [int]$hb[$k] }
        if ($va -ne $vb) { return $false }
    }
    return $true
}

function Get-NextClock {
    param(
        $SeenClock,
        [Parameter(Mandatory = $true)][string]$NodeId
    )
    $h = ConvertTo-Hashtable $SeenClock
    if (-not $h.ContainsKey($NodeId)) { $h[$NodeId] = 0 }
    $h[$NodeId] = [int]$h[$NodeId] + 1
    return $h
}

function Write-SyncOperation {
    param(
        [Parameter(Mandatory = $true)][string]$SyncRoot,
        [Parameter(Mandatory = $true)]$Operation
    )
    $dir = Get-OperationsDir -SyncRoot $SyncRoot
    $ts = ([datetime]$Operation.timestampUtc).ToUniversalTime().ToString('yyyyMMddTHHmmssfff')
    $fileName = '{0}_{1}_{2}.json' -f $ts, $Operation.nodeId, $Operation.operationId
    $final = Join-Path $dir $fileName
    $tmp = Join-Path $dir ('{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $json = ConvertTo-MobaJson -Object $Operation
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        $null = ([System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json)
        [System.IO.File]::Move($tmp, $final)
        return $final
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-SyncOperations {
    param([Parameter(Mandatory = $true)][string]$SyncRoot)

    $dir = Get-OperationsDir -SyncRoot $SyncRoot
    $ops = (New-Object System.Collections.ArrayList)
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -eq '.json' -and
            $_.Name -notlike '*.tmp' -and
            $_.Name -ne '.gitkeep'
        } |
        Sort-Object Name |
        ForEach-Object {
            try {
                $op = ConvertFrom-MobaJsonFile -Path $_.FullName
                if ($null -eq $op) { return }
                if (-not $op.PSObject.Properties['schema']) { return }
                if (-not $op.PSObject.Properties['operationId']) { return }
                if (-not $op.PSObject.Properties['action']) { return }
                if (-not $op.PSObject.Properties['bookmarkId']) { return }
                $op | Add-Member -NotePropertyName '_Path' -NotePropertyValue $_.FullName -Force
                $ops.Add($op) | Out-Null
            }
            catch {
                # ignore invalid / partially synced JSON
            }
        }
    return $ops
}

function Build-GlobalBookmarkIndex {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Operations,
        [bool]$DeleteWins = $true
    )
    $Operations = @($Operations)

    # Group by bookmarkId, reduce to effective state
    $byId = @{}
    foreach ($op in $Operations) {
        $id = [string]$op.bookmarkId
        if (-not $byId.ContainsKey($id)) {
            $byId[$id] = (New-Object System.Collections.ArrayList)
        }
        $byId[$id].Add($op) | Out-Null
    }

    $index = @{}
    foreach ($id in $byId.Keys) {
        $list = @($byId[$id] | Sort-Object {
                [datetime]$_.timestampUtc
            }, {
                [string]$_.operationId
            })

        $current = $null
        foreach ($op in $list) {
            if ($null -eq $current) {
                $current = $op
                continue
            }
            $domNew = Test-ClockDominates -A $op.clock -B $current.clock
            $domOld = Test-ClockDominates -A $current.clock -B $op.clock
            $concurrent = Test-ClocksConcurrent -A $op.clock -B $current.clock

            if ($domNew) {
                $current = $op
            }
            elseif ($domOld) {
                # keep current
            }
            elseif ($concurrent -or $true) {
                # concurrent or equal clocks: deterministic + DeleteWins
                $curDel = ([string]$current.action -eq 'delete')
                $newDel = ([string]$op.action -eq 'delete')
                if ($DeleteWins -and ($curDel -xor $newDel)) {
                    if ($newDel) { $current = $op }
                }
                else {
                    $tNew = [datetime]$op.timestampUtc
                    $tOld = [datetime]$current.timestampUtc
                    if ($tNew -gt $tOld) {
                        $current = $op
                    }
                    elseif ($tNew -eq $tOld -and ([string]$op.operationId -gt [string]$current.operationId)) {
                        $current = $op
                    }
                }
            }
        }

        if ($null -ne $current) {
            $index[$id] = [pscustomobject]@{
                BookmarkId    = $id
                Action        = [string]$current.action
                Name          = [string]$current.name
                Value         = [string]$current.value
                CreatedBy     = [string]$current.createdBy
                LastChangedBy = [string]$current.lastChangedBy
                TimestampUtc  = [string]$current.timestampUtc
                Clock         = $current.clock
                IsDeleted     = ([string]$current.action -eq 'delete')
                LastOp        = $current
            }
        }
    }
    return $index
}

#endregion

#region Diff / Sync core

function Get-StateBookmarkMap {
    param($State)
    $map = @{}
    if ($null -eq $State -or $null -eq $State.Bookmarks) { return $map }
    foreach ($p in $State.Bookmarks.PSObject.Properties) {
        $map[$p.Name] = $p.Value
    }
    return $map
}

function Compare-LocalBookmarks {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$CurrentBookmarks,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)]$KnownTags,
        [bool]$AutoTag = $true
    )
    $CurrentBookmarks = @($CurrentBookmarks)
    if ($KnownTags -isnot [hashtable]) {
        $KnownTags = ConvertTo-Hashtable $KnownTags
    }

    $last = Get-StateBookmarkMap -State $State
    # lastApplied by local name
    $lastByName = @{}
    foreach ($id in $last.Keys) {
        $b = $last[$id]
        if ($b.PSObject.Properties['IsDeleted'] -and $b.IsDeleted) { continue }
        $localName = [string]$b.LocalName
        if (-not $localName) { $localName = [string]$b.Name }
        $lastByName[$localName] = [pscustomobject]@{
            BookmarkId = $id
            Name       = [string]$b.Name
            LocalName  = $localName
            Value      = [string]$b.Value
        }
    }

    $currentByName = @{}
    foreach ($b in $CurrentBookmarks) {
        $currentByName[[string]$b.Name] = $b
    }

    $changes = (New-Object System.Collections.ArrayList)

    # Renames: disappeared name + new name with same value
    $removedNames = @($lastByName.Keys | Where-Object { -not $currentByName.ContainsKey($_) })
    $addedNames = @($currentByName.Keys | Where-Object { -not $lastByName.ContainsKey($_) })

    $renamedFrom = @{}
    $renamedTo = @{}
    foreach ($rn in $removedNames) {
        $oldVal = [string]$lastByName[$rn].Value
        $matches = @($addedNames | Where-Object { [string]$currentByName[$_].Value -eq $oldVal })
        if ($matches.Count -eq 1) {
            $nn = $matches[0]
            # ensure not already claimed
            if (-not $renamedTo.ContainsKey($nn)) {
                $renamedFrom[$rn] = $nn
                $renamedTo[$nn] = $rn
            }
        }
    }

    foreach ($name in $currentByName.Keys) {
        $cur = $currentByName[$name]
        if ($renamedTo.ContainsKey($name)) {
            $oldName = $renamedTo[$name]
            $old = $lastByName[$oldName]
            $changes.Add([pscustomobject]@{
                    Kind       = 'rename'
                    BookmarkId = $old.BookmarkId
                    OldName    = $oldName
                    Name       = $name
                    Value      = [string]$cur.Value
                    Section    = $cur.Section
                }) | Out-Null
            continue
        }

        if ($lastByName.ContainsKey($name)) {
            $old = $lastByName[$name]
            if ([string]$old.Value -ne [string]$cur.Value -or [string]$old.Name -ne [string]$name) {
                $changes.Add([pscustomobject]@{
                        Kind       = 'update'
                        BookmarkId = $old.BookmarkId
                        Name       = $name
                        Value      = [string]$cur.Value
                        Section    = $cur.Section
                    }) | Out-Null
            }
        }
        else {
            # new local bookmark
            $finalName = $name
            $info = Get-BookmarkTagPrefix -Name $name
            if ($AutoTag -and -not $info.HasPrefix) {
                $finalName = Add-BookmarkTag -Name $name -Tag $Tag
            }
            elseif ($info.HasPrefix) {
                $tagKey = $info.Tag.ToUpperInvariant()
                # unknown prefix: leave as-is (not managed automatically)
                $finalName = $name
            }
            $changes.Add([pscustomobject]@{
                    Kind       = 'add'
                    BookmarkId = [Guid]::NewGuid().ToString()
                    Name       = $finalName
                    OriginalName = $name
                    Value      = [string]$cur.Value
                    Section    = $cur.Section
                    NeedsRetag = ($finalName -ne $name)
                }) | Out-Null
        }
    }

    foreach ($name in $removedNames) {
        if ($renamedFrom.ContainsKey($name)) { continue }
        $old = $lastByName[$name]
        $changes.Add([pscustomobject]@{
                Kind       = 'delete'
                BookmarkId = $old.BookmarkId
                Name       = $old.Name
                Value      = $old.Value
            }) | Out-Null
    }

    return $changes
}

function New-SyncOperationObject {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$BookmarkId,
        [Parameter(Mandatory = $true)]$ComputerConfig,
        [Parameter(Mandatory = $true)]$Clock,
        [string]$Name,
        [string]$Value,
        [string]$CreatedBy,
        [string]$LastChangedBy
    )
    $opId = [Guid]::NewGuid().ToString()
    $clockObj = [ordered]@{}
    $h = ConvertTo-Hashtable $Clock
    foreach ($k in ($h.Keys | Sort-Object)) {
        $clockObj[$k] = [int]$h[$k]
    }
    return [ordered]@{
        schema         = 1
        operationId    = $opId
        bookmarkId     = $BookmarkId
        nodeId         = [string]$ComputerConfig.NodeId
        nodeName       = [string]$ComputerConfig.ComputerName
        nodeTag        = [string]$ComputerConfig.Tag
        action         = $Action
        name           = $Name
        value          = $Value
        createdBy      = $(if ($CreatedBy) { $CreatedBy } else { [string]$ComputerConfig.ComputerName })
        lastChangedBy  = $(if ($LastChangedBy) { $LastChangedBy } else { [string]$ComputerConfig.ComputerName })
        timestampUtc   = (Get-Date).ToUniversalTime().ToString('o')
        clock          = $clockObj
    }
}

function Invoke-ClassifyInitialImport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$LocalBookmarks,
        [Parameter(Mandatory = $true)]$GlobalIndex,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$ComputerName
    )
    $LocalBookmarks = @($LocalBookmarks)

    $activeGlobal = @($GlobalIndex.Values | Where-Object { -not $_.IsDeleted })
    $usedGlobalIds = @{}

    $exactDupes = (New-Object System.Collections.ArrayList)
    $probableDupes = (New-Object System.Collections.ArrayList)
    $uniqueLocal = (New-Object System.Collections.ArrayList)
    $incoming = (New-Object System.Collections.ArrayList)

    foreach ($lb in $LocalBookmarks) {
        $exact = @($activeGlobal | Where-Object {
                -not $usedGlobalIds.ContainsKey($_.BookmarkId) -and
                $_.Name -eq $lb.Name -and $_.Value -eq $lb.Value
            })
        if ($exact.Count -ge 1) {
            $g = $exact[0]
            $usedGlobalIds[$g.BookmarkId] = $true
            $exactDupes.Add([pscustomobject]@{
                    LocalName  = $lb.Name
                    LocalValue = $lb.Value
                    BookmarkId = $g.BookmarkId
                    GlobalName = $g.Name
                }) | Out-Null
            continue
        }

        # also match if local untagged equals global tagged base+value
        $localInfo = Get-BookmarkTagPrefix -Name $lb.Name
        $exact2 = @($activeGlobal | Where-Object {
                -not $usedGlobalIds.ContainsKey($_.BookmarkId) -and
                $_.Value -eq $lb.Value -and
                (
                    $_.Name -eq $lb.Name -or
                    ((Get-BookmarkTagPrefix -Name $_.Name).BaseName -eq $localInfo.BaseName -and $_.Value -eq $lb.Value)
                )
            } | Where-Object { $_.Value -eq $lb.Value -and (
                    $_.Name -eq $lb.Name -or
                    (Get-BookmarkTagPrefix -Name $_.Name).BaseName -eq $localInfo.BaseName
                )
            })
        # Prefer full name+value already handled; for value+basename:
        $exactVal = @($activeGlobal | Where-Object {
                -not $usedGlobalIds.ContainsKey($_.BookmarkId) -and
                $_.Value -eq $lb.Value -and
                (
                    $_.Name -eq $lb.Name -or
                    (
                        (Get-BookmarkTagPrefix -Name $_.Name).BaseName -eq $localInfo.BaseName -and
                        (Get-BookmarkTagPrefix -Name $_.Name).BaseName -eq $lb.Name -or
                        (Get-BookmarkTagPrefix -Name $_.Name).BaseName -eq $localInfo.BaseName
                    )
                )
            })

        $matchedExact = $false
        foreach ($g in $activeGlobal) {
            if ($usedGlobalIds.ContainsKey($g.BookmarkId)) { continue }
            if ($g.Value -ne $lb.Value) { continue }
            $gInfo = Get-BookmarkTagPrefix -Name $g.Name
            if ($g.Name -eq $lb.Name -or $gInfo.BaseName -eq $localInfo.BaseName -or $gInfo.BaseName -eq $lb.Name) {
                $usedGlobalIds[$g.BookmarkId] = $true
                $exactDupes.Add([pscustomobject]@{
                        LocalName  = $lb.Name
                        LocalValue = $lb.Value
                        BookmarkId = $g.BookmarkId
                        GlobalName = $g.Name
                    }) | Out-Null
                $matchedExact = $true
                break
            }
        }
        if ($matchedExact) { continue }

        $lfp = Get-BookmarkEndpointFingerprint -Value $lb.Value
        $probable = $null
        foreach ($g in $activeGlobal) {
            if ($usedGlobalIds.ContainsKey($g.BookmarkId)) { continue }
            $gfp = Get-BookmarkEndpointFingerprint -Value $g.Value
            if ($lfp.Fingerprint -and $lfp.Fingerprint -eq $gfp.Fingerprint -and $lb.Value -ne $g.Value) {
                $probable = $g
                break
            }
            # same host+protocol but different port/user
            if ($lfp.Host -and $lfp.Host -eq $gfp.Host -and $lfp.Protocol -eq $gfp.Protocol -and $lfp.Fingerprint -ne $gfp.Fingerprint) {
                $probable = $g
                break
            }
        }
        if ($null -ne $probable) {
            $probableDupes.Add([pscustomobject]@{
                    LocalName   = $lb.Name
                    LocalValue  = $lb.Value
                    GlobalName  = $probable.Name
                    GlobalValue = $probable.Value
                    BookmarkId  = $probable.BookmarkId
                    Reason      = 'Same endpoint family (protocol/host), different details'
                }) | Out-Null
            # do not mark used - keep both; conflict recorded
            $uniqueLocal.Add([pscustomobject]@{
                    LocalName = $lb.Name
                    Value     = $lb.Value
                    Section   = $lb.Section
                    ConflictWith = $probable.BookmarkId
                }) | Out-Null
            continue
        }

        $uniqueLocal.Add([pscustomobject]@{
                LocalName = $lb.Name
                Value     = $lb.Value
                Section   = $lb.Section
                ConflictWith = $null
            }) | Out-Null
    }

    foreach ($g in $activeGlobal) {
        if ($usedGlobalIds.ContainsKey($g.BookmarkId)) { continue }
        # if any local exact already matched skip; remaining globals are incoming
        $hasLocal = $false
        foreach ($lb in $LocalBookmarks) {
            if ($lb.Name -eq $g.Name -and $lb.Value -eq $g.Value) { $hasLocal = $true; break }
        }
        if (-not $hasLocal) {
            # also skip if exactDupes already linked
            $linked = @($exactDupes | Where-Object { $_.BookmarkId -eq $g.BookmarkId })
            if ($linked.Count -eq 0) {
                $incoming.Add([pscustomobject]@{
                        BookmarkId = $g.BookmarkId
                        Name       = $g.Name
                        Value      = $g.Value
                        CreatedBy  = $g.CreatedBy
                    }) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        ExactDuplicates   = $exactDupes
        ProbableConflicts = $probableDupes
        UniqueLocal       = $uniqueLocal
        IncomingGlobal    = $incoming
        ComputerName      = $ComputerName
        Tag               = $Tag
    }
}

function Invoke-MobaSyncCore {
    param(
        [Parameter(Mandatory = $true)][string]$SyncRoot,
        [Parameter(Mandatory = $true)]$ComputerConfig,
        [Parameter(Mandatory = $true)]$CommonConfig,
        [switch]$ApprovePendingDelete,
        [switch]$IsInitialImport,
        [switch]$DryRun,
        [string]$InitialImportMode = 'AutoTag'
    )

    $nodeId = [string]$ComputerConfig.NodeId
    $localRoot = Get-LocalDataRoot -NodeId $nodeId
    $mutex = Enter-SyncMutex -NodeId $nodeId -TimeoutMs 0
    if ($null -eq $mutex) {
        Write-SyncLog -LocalDataRoot $localRoot -Level WARN -Message 'Another sync instance holds the mutex; exiting.'
        return [pscustomobject]@{ Status = 'locked'; Message = 'Another sync instance is running.' }
    }

    try {
        if (Test-MobaProcessRunning -ProcessPattern $CommonConfig.ProcessPattern) {
            if (-not $IsInitialImport) {
                Set-PendingSync -LocalDataRoot $localRoot -Reason 'MobaXtermRunning'
                Write-SyncLog -LocalDataRoot $localRoot -Level INFO -Message 'MobaXterm is running; deferred sync via pending-sync.json'
                return [pscustomobject]@{ Status = 'deferred'; Message = 'MobaXterm is running; sync deferred.' }
            }
            else {
                throw 'MobaXterm must be closed during installation/initial import.'
            }
        }

        $iniPath = [string]$ComputerConfig.IniPath
        if (-not (Test-Path -LiteralPath $iniPath)) {
            Write-SyncLog -LocalDataRoot $localRoot -Level ERROR -Message "INI missing: $iniPath"
            return [pscustomobject]@{ Status = 'error'; Message = "INI missing: $iniPath" }
        }

        $ini = $null
        try {
            $ini = Read-MobaIni -Path $iniPath
        }
        catch {
            Write-SyncLog -LocalDataRoot $localRoot -Level ERROR -Message ("INI parse failed: " + $_.Exception.Message)
            return [pscustomobject]@{ Status = 'error'; Message = "INI parse failed: $($_.Exception.Message)" }
        }

        if ($ini.ByteLength -eq 0 -or [string]::IsNullOrWhiteSpace($ini.RawText)) {
            Write-SyncLog -LocalDataRoot $localRoot -Level WARN -Message 'INI is empty; refusing to publish deletes.'
            return [pscustomobject]@{ Status = 'error'; Message = 'INI is empty; refusing mass changes.' }
        }

        $bookmarkSections = @($ini.Sections | Where-Object { Test-IsBookmarkSection -SectionName $_.Name })
        if ($bookmarkSections.Count -eq 0) {
            Write-SyncLog -LocalDataRoot $localRoot -Level WARN -Message 'No bookmark sections found; refusing to publish deletes.'
            return [pscustomobject]@{ Status = 'error'; Message = 'Bookmark sections missing; refusing mass changes.' }
        }

        $ops = @(Get-SyncOperations -SyncRoot $SyncRoot)
        $globalIndex = Build-GlobalBookmarkIndex -Operations $ops -DeleteWins ([bool]$CommonConfig.DeleteWins)
        $knownTags = Get-KnownTags -SyncRoot $SyncRoot
        $localBookmarks = @(Get-BookmarkEntries -Ini $ini)

        $state = Get-LocalState -LocalDataRoot $localRoot
        if ($null -eq $state) {
            $state = New-EmptyState -NodeId $nodeId
        }

        # Initial import path
        if ($IsInitialImport -or -not [bool]$ComputerConfig.Initialized) {
            return Invoke-InitialImportCore -SyncRoot $SyncRoot -ComputerConfig $ComputerConfig `
                -CommonConfig $CommonConfig -Ini $ini -LocalBookmarks $localBookmarks `
                -GlobalIndex $globalIndex -State $state -LocalDataRoot $localRoot `
                -DryRun:$DryRun -InitialImportMode $InitialImportMode -KnownTags $knownTags
        }

        # Approve pending mass delete
        if ($ApprovePendingDelete) {
            $pdPath = Get-PendingDeletePath -LocalDataRoot $localRoot
            if (-not (Test-Path -LiteralPath $pdPath)) {
                return [pscustomobject]@{ Status = 'error'; Message = 'No pending-delete.json to approve.' }
            }
            $pending = ConvertFrom-MobaJsonFile -Path $pdPath
            $seen = ConvertTo-Hashtable $state.SeenClock
            foreach ($d in @($pending.deletes)) {
                $seen = Get-NextClock -SeenClock $seen -NodeId $nodeId
                $op = New-SyncOperationObject -Action 'delete' -BookmarkId $d.BookmarkId `
                    -ComputerConfig $ComputerConfig -Clock $seen -Name $d.Name -Value $d.Value `
                    -CreatedBy $d.CreatedBy -LastChangedBy $ComputerConfig.ComputerName
                if (-not $DryRun) {
                    Write-SyncOperation -SyncRoot $SyncRoot -Operation $op | Out-Null
                }
            }
            if (-not $DryRun) {
                Remove-Item -LiteralPath $pdPath -Force
                $state.SeenClock = $seen
                Save-LocalState -LocalDataRoot $localRoot -State $state
            }
            Write-SyncLog -LocalDataRoot $localRoot -Message ("Approved mass delete: {0} tombstones" -f @($pending.deletes).Count)
            # continue into normal sync after publishing
            $ops = @(Get-SyncOperations -SyncRoot $SyncRoot)
            $globalIndex = Build-GlobalBookmarkIndex -Operations $ops -DeleteWins ([bool]$CommonConfig.DeleteWins)
        }

        $changes = @(Compare-LocalBookmarks -CurrentBookmarks $localBookmarks -State $state `
                -Tag $ComputerConfig.Tag -KnownTags $knownTags -AutoTag ([bool]$CommonConfig.AutoTag))

        $deletes = @($changes | Where-Object { $_.Kind -eq 'delete' })
        $activeCount = @($state.Bookmarks.PSObject.Properties).Count
        if ($activeCount -gt 0 -and $deletes.Count -gt 0) {
            $pct = [int][Math]::Floor(($deletes.Count * 100.0) / [Math]::Max($activeCount, 1))
            $limit = [int]$CommonConfig.MassDeleteLimitPercent
            if ($pct -gt $limit) {
                $pd = [ordered]@{
                    schema       = 1
                    createdUtc   = (Get-Date).ToUniversalTime().ToString('o')
                    percent      = $pct
                    limit        = $limit
                    instruction  = 'Run Invoke-MobaSync.ps1 -ApprovePendingDelete after verifying the INI is intentional.'
                    deletes      = @($deletes | ForEach-Object {
                            $bm = $state.Bookmarks.($_.BookmarkId)
                            [ordered]@{
                                BookmarkId = $_.BookmarkId
                                Name       = $_.Name
                                Value      = $_.Value
                                CreatedBy  = $(if ($bm -and $bm.CreatedBy) { $bm.CreatedBy } else { '' })
                            }
                        })
                }
                if (-not $DryRun) {
                    Write-MobaJsonAtomic -Path (Get-PendingDeletePath -LocalDataRoot $localRoot) -Object $pd
                }
                $msg = "Mass delete blocked: $pct% exceeds limit $limit%. Review pending-delete.json and re-run with -ApprovePendingDelete."
                Write-SyncLog -LocalDataRoot $localRoot -Level WARN -Message $msg
                return [pscustomobject]@{ Status = 'mass-delete-blocked'; Message = $msg; PendingDelete = $pd }
            }
        }

        # Publish local changes
        $seenClock = ConvertTo-Hashtable $state.SeenClock
        $published = (New-Object System.Collections.ArrayList)
        $retagMap = @{} # original name -> tagged name

        # Build createdBy map from state
        $stateMap = Get-StateBookmarkMap -State $state

        foreach ($ch in $changes) {
            if ($ch.Kind -eq 'delete') { continue } # handled after mass-check; publish now
        }

        foreach ($ch in $changes) {
            $seenClock = Get-NextClock -SeenClock $seenClock -NodeId $nodeId
            $createdBy = $ComputerConfig.ComputerName
            if ($stateMap.ContainsKey($ch.BookmarkId) -and $stateMap[$ch.BookmarkId].CreatedBy) {
                $createdBy = [string]$stateMap[$ch.BookmarkId].CreatedBy
            }
            elseif ($ch.Kind -eq 'add') {
                $createdBy = $ComputerConfig.ComputerName
            }

            $action = switch ($ch.Kind) {
                'add' { 'add' }
                'update' { 'update' }
                'rename' { 'update' }
                'delete' { 'delete' }
                default { 'update' }
            }

            $op = New-SyncOperationObject -Action $action -BookmarkId $ch.BookmarkId `
                -ComputerConfig $ComputerConfig -Clock $seenClock `
                -Name $ch.Name -Value $(if ($ch.PSObject.Properties['Value']) { $ch.Value } else { '' }) `
                -CreatedBy $createdBy -LastChangedBy $ComputerConfig.ComputerName

            if ($ch.Kind -eq 'add' -and $ch.NeedsRetag) {
                $retagMap[$ch.OriginalName] = $ch.Name
            }

            if (-not $DryRun) {
                Write-SyncOperation -SyncRoot $SyncRoot -Operation $op | Out-Null
            }
            $published.Add($op) | Out-Null
        }

        # Refresh global index after publish
        if (-not $DryRun -and $published.Count -gt 0) {
            $ops = @(Get-SyncOperations -SyncRoot $SyncRoot)
            $globalIndex = Build-GlobalBookmarkIndex -Operations $ops -DeleteWins ([bool]$CommonConfig.DeleteWins)
        }
        elseif ($DryRun -and $published.Count -gt 0) {
            # merge published into temporary view
            $all = @($ops + $published)
            $globalIndex = Build-GlobalBookmarkIndex -Operations $all -DeleteWins ([bool]$CommonConfig.DeleteWins)
        }

        # Apply global state to INI
        $desired = (New-Object System.Collections.ArrayList)
        $newStateBookmarks = [ordered]@{}
        $conflicts = (New-Object System.Collections.ArrayList)

        foreach ($id in $globalIndex.Keys) {
            $g = $globalIndex[$id]
            if ($g.IsDeleted) {
                $newStateBookmarks[$id] = [ordered]@{
                    Name          = $g.Name
                    LocalName     = $g.Name
                    Value         = $g.Value
                    CreatedBy     = $g.CreatedBy
                    LastChangedBy = $g.LastChangedBy
                    IsDeleted     = $true
                    TimestampUtc  = $g.TimestampUtc
                }
                continue
            }
            $section = 'Bookmarks'
            # preserve section from current local if same name exists
            foreach ($lb in $localBookmarks) {
                if ($lb.Name -eq $g.Name -or ($retagMap.ContainsKey($lb.Name) -and $retagMap[$lb.Name] -eq $g.Name)) {
                    $section = $lb.Section
                    break
                }
            }
            $desired.Add([pscustomobject]@{
                    Name    = $g.Name
                    Value   = $g.Value
                    Section = $section
                }) | Out-Null
            $newStateBookmarks[$id] = [ordered]@{
                Name          = $g.Name
                LocalName     = $g.Name
                Value         = $g.Value
                CreatedBy     = $g.CreatedBy
                LastChangedBy = $g.LastChangedBy
                IsDeleted     = $false
                TimestampUtc  = $g.TimestampUtc
            }
        }

        if ($DryRun) {
            return [pscustomobject]@{
                Status     = 'dry-run'
                Published  = $published
                Desired    = $desired
                Conflicts  = $conflicts
                Message    = 'DryRun: no files written.'
            }
        }

        Backup-MobaIni -IniPath $iniPath -LocalDataRoot $localRoot -BackupCount ([int]$CommonConfig.BackupCount) | Out-Null
        Set-IniBookmarkEntries -Ini $ini -Bookmarks @($desired)
        Write-MobaIniAtomic -Ini $ini -Path $iniPath

        $hash = Get-FileSha256 -Path $iniPath
        # Update seen clock to merge all op clocks
        foreach ($op in $ops) {
            $seenClock = Merge-VersionClock -A $seenClock -B $op.clock
        }
        $state.Initialized = $true
        $state.NodeId = $nodeId
        $state.SeenClock = $seenClock
        $state.Bookmarks = $newStateBookmarks
        $state.LastSyncUtc = (Get-Date).ToUniversalTime().ToString('o')
        $state.LastAppliedIniHash = $hash
        Save-LocalState -LocalDataRoot $localRoot -State $state
        Clear-PendingSync -LocalDataRoot $localRoot

        Write-SyncLog -LocalDataRoot $localRoot -Message ("Sync OK; bookmarks={0}; published={1}" -f $desired.Count, $published.Count)
        return [pscustomobject]@{
            Status    = 'ok'
            Published = $published.Count
            Applied   = $desired.Count
        }
    }
    finally {
        Exit-SyncMutex -Mutex $mutex
    }
}

function Invoke-InitialImportCore {
    param(
        [Parameter(Mandatory = $true)][string]$SyncRoot,
        [Parameter(Mandatory = $true)]$ComputerConfig,
        [Parameter(Mandatory = $true)]$CommonConfig,
        [Parameter(Mandatory = $true)]$Ini,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$LocalBookmarks,
        [Parameter(Mandatory = $true)]$GlobalIndex,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$LocalDataRoot,
        [Parameter(Mandatory = $true)]$KnownTags,
        [switch]$DryRun,
        [string]$InitialImportMode = 'AutoTag'
    )
    $LocalBookmarks = @($LocalBookmarks)
    if ($KnownTags -isnot [hashtable]) {
        $KnownTags = ConvertTo-Hashtable $KnownTags
    }

    $report = Invoke-ClassifyInitialImport -LocalBookmarks $LocalBookmarks -GlobalIndex $GlobalIndex `
        -Tag $ComputerConfig.Tag -ComputerName $ComputerConfig.ComputerName

    $autoTag = ($InitialImportMode -eq 'AutoTag') -and ([bool]$CommonConfig.AutoTag)
    $isFirstComputer = (@($GlobalIndex.Keys).Count -eq 0)

    $planAdds = (New-Object System.Collections.ArrayList)
    $finalBookmarks = (New-Object System.Collections.ArrayList)
    $newStateBookmarks = [ordered]@{}
    $seenClock = ConvertTo-Hashtable $State.SeenClock
    $opsToWrite = (New-Object System.Collections.ArrayList)

    # Exact duplicates в†’ keep global id/name
    $mappedLocal = @{}
    foreach ($d in $report.ExactDuplicates) {
        $g = $GlobalIndex[$d.BookmarkId]
        $finalBookmarks.Add([pscustomobject]@{ Name = $g.Name; Value = $g.Value; Section = 'Bookmarks' }) | Out-Null
        $mappedLocal[$d.LocalName] = $d.BookmarkId
        $newStateBookmarks[$d.BookmarkId] = [ordered]@{
            Name = $g.Name; LocalName = $g.Name; Value = $g.Value
            CreatedBy = $g.CreatedBy; LastChangedBy = $g.LastChangedBy; IsDeleted = $false
            TimestampUtc = $g.TimestampUtc
        }
    }

    # Unique local в†’ add with tag (never delete on initial import)
    foreach ($u in $report.UniqueLocal) {
        $name = $u.LocalName
        if ($autoTag) {
            $info = Get-BookmarkTagPrefix -Name $name
            if (-not $info.HasPrefix) {
                $name = Add-BookmarkTag -Name $name -Tag $ComputerConfig.Tag
            }
            elseif ($KnownTags.ContainsKey($info.Tag.ToUpperInvariant())) {
                # already tagged with known tag - keep
            }
        }
        $bid = [Guid]::NewGuid().ToString()
        $seenClock = Get-NextClock -SeenClock $seenClock -NodeId $ComputerConfig.NodeId
        $op = New-SyncOperationObject -Action 'add' -BookmarkId $bid -ComputerConfig $ComputerConfig `
            -Clock $seenClock -Name $name -Value $u.Value `
            -CreatedBy $ComputerConfig.ComputerName -LastChangedBy $ComputerConfig.ComputerName
        $opsToWrite.Add($op) | Out-Null
        $planAdds.Add($op) | Out-Null
        $finalBookmarks.Add([pscustomobject]@{ Name = $name; Value = $u.Value; Section = $(if ($u.Section) { $u.Section } else { 'Bookmarks' }) }) | Out-Null
        $newStateBookmarks[$bid] = [ordered]@{
            Name = $name; LocalName = $name; Value = $u.Value
            CreatedBy = $ComputerConfig.ComputerName; LastChangedBy = $ComputerConfig.ComputerName
            IsDeleted = $false; TimestampUtc = $op.timestampUtc
        }
    }

    # Incoming global
    foreach ($inc in $report.IncomingGlobal) {
        $finalBookmarks.Add([pscustomobject]@{ Name = $inc.Name; Value = $inc.Value; Section = 'Bookmarks' }) | Out-Null
        $g = $GlobalIndex[$inc.BookmarkId]
        $newStateBookmarks[$inc.BookmarkId] = [ordered]@{
            Name = $inc.Name; LocalName = $inc.Name; Value = $inc.Value
            CreatedBy = $inc.CreatedBy; LastChangedBy = $g.LastChangedBy
            IsDeleted = $false; TimestampUtc = $g.TimestampUtc
        }
    }

    $result = [pscustomobject]@{
        Status            = $(if ($DryRun) { 'dry-run' } else { 'ok' })
        IsFirstComputer   = $isFirstComputer
        Report            = $report
        PlannedAdds       = $planAdds
        FinalBookmarkCount= $finalBookmarks.Count
        Message           = $(if ($DryRun) { 'DryRun initial import: no changes written.' } else { 'Initial import applied.' })
    }

    if ($DryRun) {
        return $result
    }

    Backup-MobaIni -IniPath $ComputerConfig.IniPath -LocalDataRoot $LocalDataRoot -BackupCount ([int]$CommonConfig.BackupCount) | Out-Null

    foreach ($op in $opsToWrite) {
        Write-SyncOperation -SyncRoot $SyncRoot -Operation $op | Out-Null
    }

    Set-IniBookmarkEntries -Ini $Ini -Bookmarks @($finalBookmarks)
    Write-MobaIniAtomic -Ini $Ini -Path $ComputerConfig.IniPath

    foreach ($op in @(Get-SyncOperations -SyncRoot $SyncRoot)) {
        $seenClock = Merge-VersionClock -A $seenClock -B $op.clock
    }

    $hash = Get-FileSha256 -Path $ComputerConfig.IniPath
    $State.Initialized = $true
    $State.NodeId = $ComputerConfig.NodeId
    $State.SeenClock = $seenClock
    $State.Bookmarks = $newStateBookmarks
    $State.LastSyncUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State.LastAppliedIniHash = $hash
    Save-LocalState -LocalDataRoot $LocalDataRoot -State $State

    $ComputerConfig.Initialized = $true
    Save-ComputerConfig -Path $ComputerConfig._ConfigPath -Config $ComputerConfig

    Write-SyncLog -LocalDataRoot $LocalDataRoot -Message ("Initial import OK; first={0}; adds={1}; final={2}" -f $isFirstComputer, $planAdds.Count, $finalBookmarks.Count)
    return $result
}

#endregion

#region Scheduled task helpers

function Get-MobaSyncTaskNames {
    param([Parameter(Mandatory = $true)][string]$ComputerName)
    return [pscustomobject]@{
        Watch  = 'MobaBookmarkSync-Watch-{0}' -f $ComputerName
        Weekly = 'MobaBookmarkSync-Weekly-{0}' -f $ComputerName
    }
}

function Register-MobaSyncTasks {
    param(
        [Parameter(Mandatory = $true)][string]$SyncRoot,
        [Parameter(Mandatory = $true)]$ComputerConfig,
        [Parameter(Mandatory = $true)]$CommonConfig,
        [switch]$Force
    )

    $names = Get-MobaSyncTaskNames -ComputerName $ComputerConfig.ComputerName
    $watchScript = Join-Path $SyncRoot 'app\Watch-MobaXterm.ps1'
    $invokeScript = Join-Path $SyncRoot 'app\Invoke-MobaSync.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $watchArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScript`""
    $weeklyArg = "-NoProfile -ExecutionPolicy Bypass -File `"$invokeScript`" -Reason Weekly"

    if ($Force) {
        Unregister-MobaSyncTasks -ComputerName $ComputerConfig.ComputerName
    }

    # Watch at logon
    $watchAction = New-ScheduledTaskAction -Execute $ps -Argument $watchArg -WorkingDirectory (Join-Path $SyncRoot 'app')
    $watchTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $watchPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $names.Watch -Action $watchAction -Trigger $watchTrigger `
        -Settings $watchSettings -Principal $watchPrincipal -Force | Out-Null

    # Weekly
    $day = [string]$CommonConfig.WeeklyDay
    $time = [string]$CommonConfig.WeeklyTime
    $weeklyAction = New-ScheduledTaskAction -Execute $ps -Argument $weeklyArg -WorkingDirectory (Join-Path $SyncRoot 'app')
    $weeklyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $time
    $weeklySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
    try {
        $weeklySettings.WakeToRun = $true
    }
    catch { }
    $weeklyPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $names.Weekly -Action $weeklyAction -Trigger $weeklyTrigger `
        -Settings $weeklySettings -Principal $weeklyPrincipal -Force | Out-Null

    return $names
}

function Unregister-MobaSyncTasks {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName
    )
    $names = Get-MobaSyncTaskNames -ComputerName $ComputerName
    foreach ($n in @($names.Watch, $names.Weekly)) {
        try {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop
        }
        catch {
            # ignore missing
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Find-SyncRoot',
    'Get-CommonConfig',
    'Save-CommonConfig',
    'Find-DefaultMobaIniPath',
    'Get-ComputerConfigPath',
    'Get-AllComputerConfigs',
    'Get-ComputerConfig',
    'Save-ComputerConfig',
    'Get-LocalDataRoot',
    'Get-OperationsDir',
    'ConvertFrom-MobaJsonFile',
    'Write-MobaJsonAtomic',
    'Write-SyncLog',
    'Get-FileSha256',
    'Read-MobaIni',
    'ConvertTo-MobaIniText',
    'Write-MobaIniAtomic',
    'Backup-MobaIni',
    'Test-IsBookmarkMetaKey',
    'Test-IsBookmarkSection',
    'Get-BookmarkEntries',
    'Get-KnownTags',
    'Get-BookmarkTagPrefix',
    'Add-BookmarkTag',
    'Get-BookmarkEndpointFingerprint',
    'Set-IniBookmarkEntries',
    'Test-MobaProcessRunning',
    'Enter-SyncMutex',
    'Exit-SyncMutex',
    'New-EmptyState',
    'Get-LocalState',
    'Save-LocalState',
    'Set-PendingSync',
    'Clear-PendingSync',
    'Test-PendingSync',
    'Get-PendingDeletePath',
    'ConvertTo-Hashtable',
    'Merge-VersionClock',
    'Get-NextClock',
    'Write-SyncOperation',
    'Get-SyncOperations',
    'Build-GlobalBookmarkIndex',
    'Compare-LocalBookmarks',
    'New-SyncOperationObject',
    'Invoke-ClassifyInitialImport',
    'Invoke-InitialImportCore',
    'Invoke-MobaSyncCore',
    'Get-MobaSyncTaskNames',
    'Register-MobaSyncTasks',
    'Unregister-MobaSyncTasks'
)

