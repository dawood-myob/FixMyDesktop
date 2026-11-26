<#
.SYNOPSIS
    Re-arranges Windows desktop icons into a tidy, predictable layout on your largest screen.

.DESCRIPTION
    Layout (on the largest monitor, or the only one):
      top-left      Folders (natural name order)
      top-right     Scripts / batch / command files (and shortcuts to them)
      bottom-right  App shortcuts
      bottom-left   Recycle Bin, with other system icons (This PC...) stacked above it
      bottom-left+  Other files, grouped by type (images, documents, ...)

.PARAMETER DryRun        Show the plan without moving anything.
.PARAMETER Restore       Put icons back where they were before the last run.
.PARAMETER Watch         Stay running and re-arrange automatically after every display change.
.PARAMETER InstallStartup / UninstallStartup  Start/stop -Watch mode at every Windows sign-in.
.PARAMETER Screen        Largest (default), Primary, or a 1-based monitor number.
.PARAMETER SettleSeconds Watch mode: wait this long after a display change before arranging.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Restore,
    [switch]$Watch,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [string]$Screen = 'Largest',
    [string]$ConfigPath,
    [int]$SettleSeconds = 5
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config.json' }
$appDataDir = Join-Path $env:LOCALAPPDATA 'FixMyDesktop'
$backupFile = Join-Path $appDataDir 'last-layout.json'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'FixMyDesktop.lnk'

if (-not ('FixMyDesktop.DesktopListView' -as [type])) {
    Add-Type -Path (Join-Path $root 'lib\DesktopNative.cs') -ReferencedAssemblies 'System.dll'
}
[FixMyDesktop.Monitors]::EnableDpiAwareness()

function Read-Config {
    $cfg = [ordered]@{
        folderColumns = 0; scriptColumns = 0; appColumns = 0; otherColumns = 0
        shortcutsToFoldersGoWithFolders = $true
        plainToolsGoWithScripts = $true
        commandShellNames = @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'wsl.exe', 'bash.exe', 'wt.exe')
        scriptExtensions = @('bat', 'cmd', 'ps1', 'vbs', 'wsf', 'sh', 'py')
        appExtensions = @('lnk', 'url', 'exe', 'appref-ms')
        otherGroups = [ordered]@{}
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) {
            if ($p.Name -eq 'otherGroups') {
                foreach ($g in $p.Value.PSObject.Properties) { $cfg.otherGroups[$g.Name] = @($g.Value) }
            }
            else { $cfg[$p.Name] = $p.Value }
        }
    }
    $cfg
}

function Get-NaturalKey([string]$text) {
    [regex]::Replace($text.ToLowerInvariant(), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}

function Select-Monitor {
    $all = @([FixMyDesktop.Monitors]::GetAll())
    if ($all.Count -eq 0) { throw 'No monitors detected.' }
    if ($Screen -match '^\d+$') {
        $i = [int]$Screen
        if ($i -lt 1 -or $i -gt $all.Count) { throw "Screen $i does not exist ($($all.Count) detected)." }
        return $all[$i - 1]
    }
    if ($Screen -eq 'Primary') { return @($all | Where-Object Primary)[0] }
    # Largest by on-screen (scaled) size; ties go to the primary screen.
    @($all | Sort-Object @{ Expression = 'EffectiveArea'; Descending = $true }, @{ Expression = 'Primary'; Descending = $true })[0]
}

# Maps what the desktop shows (file names, with hidden extensions) to the real file.
function Get-DesktopFileMap {
    $map = @{}
    $files = foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
        if ($dir -and (Test-Path -LiteralPath $dir)) { Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
    }
    foreach ($f in $files) { if (-not $map.ContainsKey($f.Name)) { $map[$f.Name] = $f } }
    foreach ($f in $files) {
        if (-not $f.PSIsContainer -and -not $map.ContainsKey($f.BaseName)) { $map[$f.BaseName] = $f }
    }
    $map
}

# "Plain" tools are what you'd keep with your scripts: an exe with no embedded icon (Windows shows its default
# generic icon, typical for home-built console/dev tools), or a command shell such as cmd/powershell.
function Test-PlainTool([string]$target, [string]$iconLocation, $cfg) {
    if (-not $target -or [IO.Path]::GetExtension($target) -ne '.exe') { return $false }
    if ($cfg.commandShellNames -contains [IO.Path]::GetFileName($target).ToLowerInvariant()) { return $true }
    if (($iconLocation -split ',')[0].Trim()) { return $false }   # shortcut sets its own icon, so it's a "fancy" app
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $false }
    return ([FixMyDesktop.NativeIcons]::Count($target) -eq 0)
}

function Get-Category($file, $cfg, $wsh) {
    if ($file.PSIsContainer) { return @{ Category = 'Folders'; Group = '' } }
    $ext = $file.Extension.TrimStart('.').ToLowerInvariant()

    if ($ext -eq 'lnk') {
        $target = ''; $arguments = ''; $icon = ''
        try { $sc = $wsh.CreateShortcut($file.FullName); $target = $sc.TargetPath; $arguments = $sc.Arguments; $icon = $sc.IconLocation } catch { }
        if ($cfg.shortcutsToFoldersGoWithFolders -and $target -and (Test-Path -LiteralPath $target -PathType Container)) {
            return @{ Category = 'Folders'; Group = '' }
        }
        $scriptPattern = '\.(' + (($cfg.scriptExtensions | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
        if (($target + ' ' + $arguments) -match $scriptPattern) { return @{ Category = 'Scripts'; Group = '' } }
        if ($cfg.plainToolsGoWithScripts -and (Test-PlainTool $target $icon $cfg)) { return @{ Category = 'Scripts'; Group = '' } }
        return @{ Category = 'Apps'; Group = '' }
    }
    if ($cfg.scriptExtensions -contains $ext) { return @{ Category = 'Scripts'; Group = '' } }
    if ($ext -eq 'exe' -and $cfg.plainToolsGoWithScripts -and (Test-PlainTool $file.FullName '' $cfg)) { return @{ Category = 'Scripts'; Group = '' } }
    if ($cfg.appExtensions -contains $ext) { return @{ Category = 'Apps'; Group = '' } }

    foreach ($g in $cfg.otherGroups.Keys) {
        if ($cfg.otherGroups[$g] -contains $ext) { return @{ Category = 'Others'; Group = $g } }
    }
    $fallback = if ($ext) { ".$ext files" } else { 'No extension' }
    @{ Category = 'Others'; Group = $fallback }
}

function Get-DesktopItems($list, $cfg) {
    $shell = New-Object -ComObject Shell.Application
    $recycleName = $shell.NameSpace(0xA).Self.Name
    $wsh = New-Object -ComObject WScript.Shell
    $map = Get-DesktopFileMap
    $groupOrder = @($cfg.otherGroups.Keys)

    $items = for ($i = 0; $i -lt $list.Count; $i++) {
        $name = $list.GetName($i)
        $cat = 'System'; $group = ''
        if ($name -eq $recycleName) { $cat = 'RecycleBin' }
        elseif ($map.ContainsKey($name)) {
            $c = Get-Category $map[$name] $cfg $wsh
            $cat = $c.Category; $group = $c.Group
        }
        $gi = [array]::IndexOf($groupOrder, $group)
        [pscustomobject]@{
            Index = $i; Name = $name; Category = $cat; Group = $group
            GroupRank = if ($gi -ge 0) { $gi } else { 1000 }
            Key = Get-NaturalKey $name
            Col = 0; Row = 0
        }
    }
    @($items)
}

# Columns for a block of n icons: square-ish by count (13 -> 4x4), a full rectangle when one fits (12 -> 4x3, 6 -> 3x2).
# A configured value > 0 overrides the automatic shape.
function Get-BlockColumns([int]$n, [int]$configured, [int]$maxRows) {
    if ($n -le 0) { return 1 }
    if ($configured -gt 0) { $cols = $configured }
    else {
        $cols = [int][Math]::Ceiling([Math]::Sqrt($n))
        $limit = [int][Math]::Ceiling(1.5 * [Math]::Sqrt($n))
        for ($c = $cols; $c -le $limit; $c++) { if ($n % $c -eq 0) { $cols = $c; break } }
    }
    [Math]::Max($cols, [int][Math]::Ceiling($n / $maxRows))
}

# Assigns a grid cell (Col/Row) to every item. Cells are icon-cell sized, so icons never overlap.
function Set-Layout($items, $cfg, $g) {
    $rows = $g.RowEnd - $g.RowStart
    $maxBlockRows = [Math]::Max(1, [int][Math]::Floor($rows * 0.45))
    $by = @{}
    foreach ($c in 'Folders', 'Scripts', 'Apps', 'RecycleBin', 'System', 'Others') { $by[$c] = @($items | Where-Object Category -eq $c) }

    # Folders: top-left
    $folders = @($by.Folders | Sort-Object Key)
    $cols = Get-BlockColumns $folders.Count ([int]$cfg.folderColumns) $maxBlockRows
    for ($i = 0; $i -lt $folders.Count; $i++) {
        $folders[$i].Col = $g.ColStart + ($i % $cols); $folders[$i].Row = $g.RowStart + [int][Math]::Floor($i / $cols)
    }

    # Scripts: top-right
    $scripts = @($by.Scripts | Sort-Object Key)
    $cols = Get-BlockColumns $scripts.Count ([int]$cfg.scriptColumns) $maxBlockRows
    for ($i = 0; $i -lt $scripts.Count; $i++) {
        $scripts[$i].Col = $g.ColEnd - $cols + ($i % $cols); $scripts[$i].Row = $g.RowStart + [int][Math]::Floor($i / $cols)
    }

    # Apps: bottom-right, block grows upward
    $apps = @($by.Apps | Sort-Object Key)
    $cols = Get-BlockColumns $apps.Count ([int]$cfg.appColumns) $maxBlockRows
    $appRows = [int][Math]::Ceiling($apps.Count / $cols)
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $apps[$i].Col = $g.ColEnd - $cols + ($i % $cols); $apps[$i].Row = $g.RowEnd - $appRows + [int][Math]::Floor($i / $cols)
    }

    # Recycle Bin: bottom-left corner; other system icons stack above it
    foreach ($r in $by.RecycleBin) { $r.Col = $g.ColStart; $r.Row = $g.RowEnd - 1 }
    $system = @($by.System | Sort-Object Key)
    $perCol = [Math]::Max(1, $maxBlockRows)
    for ($i = 0; $i -lt $system.Count; $i++) {
        $system[$i].Col = $g.ColStart + [int][Math]::Floor($i / $perCol); $system[$i].Row = $g.RowEnd - 2 - ($i % $perCol)
    }
    $systemCols = if ($system.Count) { [int][Math]::Floor(($system.Count - 1) / $perCol) + 1 } else { 1 }

    # Others: right of the Recycle Bin column, grouped by type, one group per row, block grows upward
    $groups = @($by.Others | Group-Object Group | Sort-Object @{ Expression = { $_.Group[0].GroupRank } }, Name)
    $oc = Get-BlockColumns $by.Others.Count ([int]$cfg.otherColumns) $maxBlockRows
    $totalRows = 0
    foreach ($grp in $groups) { $totalRows += [int][Math]::Ceiling($grp.Count / $oc) }
    $row = $g.RowEnd - $totalRows
    foreach ($grp in $groups) {
        $members = @($grp.Group | Sort-Object Key)
        for ($i = 0; $i -lt $members.Count; $i++) {
            $members[$i].Col = $g.ColStart + $systemCols + 1 + ($i % $oc)
            $members[$i].Row = $row + [int][Math]::Floor($i / $oc)
        }
        $row += [int][Math]::Ceiling($members.Count / $oc)
    }
}

function Save-Backup($list, $items) {
    New-Item -ItemType Directory -Force -Path $appDataDir | Out-Null
    $saved = foreach ($it in $items) { $p = $list.GetPosition($it.Index); @{ name = $it.Name; x = $p[0]; y = $p[1] } }
    @{ savedAt = (Get-Date).ToString('o'); items = @($saved) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupFile -Encoding UTF8
}

function Invoke-Restore {
    if (-not (Test-Path -LiteralPath $backupFile)) { throw "No backup found at $backupFile" }
    $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
    $list = New-Object FixMyDesktop.DesktopListView
    try {
        $saved = @{}
        foreach ($s in $backup.items) { $saved[$s.name] = $s }
        $moved = 0
        for ($i = 0; $i -lt $list.Count; $i++) {
            $n = $list.GetName($i)
            if ($saved.ContainsKey($n)) { $list.SetPosition($i, [int]$saved[$n].x, [int]$saved[$n].y); $moved++ }
        }
        Write-Host "Restored $moved icons to their positions from $($backup.savedAt)."
    }
    finally { $list.Dispose() }
}

function Invoke-Arrange {
    $cfg = Read-Config
    $monitor = Select-Monitor
    $list = New-Object FixMyDesktop.DesktopListView
    try {
        $origin = $list.Origin
        $cell = $list.Spacing
        # Explorer reports spacing at the system DPI; the target monitor may use a different scale.
        $scale = $monitor.Dpi / [double][FixMyDesktop.Monitors]::SystemDpi()
        $cw = [int][Math]::Round($cell[0] * $scale); $ch = [int][Math]::Round($cell[1] * $scale)
        if ($cw -lt 20 -or $ch -lt 20) { throw "Unexpected icon cell size ${cw}x${ch}." }

        # Work area (excludes taskbar) in list-view coordinates, converted to whole icon cells.
        $g = @{
            ColStart = [int][Math]::Ceiling(($monitor.WorkLeft - $origin[0]) / $cw)
            ColEnd   = [int][Math]::Floor(($monitor.WorkRight - $origin[0]) / $cw)
            RowStart = [int][Math]::Ceiling(($monitor.WorkTop - $origin[1]) / $ch)
            RowEnd   = [int][Math]::Floor(($monitor.WorkBottom - $origin[1]) / $ch)
        }

        $items = Get-DesktopItems $list $cfg
        if ($items.Count -eq 0) { Write-Host 'Desktop has no icons.'; return }
        Set-Layout $items $cfg $g

        $width = $monitor.Right - $monitor.Left; $height = $monitor.Bottom - $monitor.Top
        Write-Host ("Target screen: {0}x{1} at ({2},{3}){4}; icon cell {5}x{6}; {7} icons" -f $width, $height, $monitor.Left, $monitor.Top, $(if ($monitor.Primary) { ' [primary]' } else { '' }), $cw, $ch, $items.Count)

        if ($DryRun) {
            $items | Sort-Object Category, Group, Key | Format-Table Name, Category, Group, @{ n = 'X'; e = { $_.Col * $cw } }, @{ n = 'Y'; e = { $_.Row * $ch } } -AutoSize
            Write-Host 'Dry run: nothing moved.'
            return
        }

        Save-Backup $list $items
        if ($list.AutoArrange) {
            $list.AutoArrange = $false
            Write-Host 'Turned off "Auto arrange icons" (needed to place icons freely).'
        }
        foreach ($it in $items) { $list.SetPosition($it.Index, $it.Col * $cw, $it.Row * $ch) }

        # Windows nudges an icon away when another is dropped on its cell, so verify and re-place stragglers.
        for ($pass = 1; $pass -le 10; $pass++) {
            $pos = @{}
            foreach ($it in $items) { $pos[$it.Index] = $list.GetPosition($it.Index) }
            # The grid has a small fixed offset; the most common (actual - requested) delta is that offset.
            $deltas = $items | ForEach-Object { '{0},{1}' -f ($pos[$_.Index][0] - $_.Col * $cw), ($pos[$_.Index][1] - $_.Row * $ch) }
            $offset = ($deltas | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name -split ','
            $stray = @($items | Where-Object {
                    [Math]::Abs($pos[$_.Index][0] - $_.Col * $cw - [int]$offset[0]) -gt 2 -or
                    [Math]::Abs($pos[$_.Index][1] - $_.Row * $ch - [int]$offset[1]) -gt 2 })
            if ($stray.Count -eq 0) { break }
            foreach ($it in $stray) { $list.SetPosition($it.Index, $it.Col * $cw, $it.Row * $ch) }
        }
        if ($stray.Count -gt 0) { Write-Warning "$($stray.Count) icons could not be placed exactly." }

        $summary = $items | Group-Object Category | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Host ("Arranged: " + ($summary -join ', ') + '. Undo with: Arrange-Desktop.cmd -Restore')
    }
    finally { $list.Dispose() }
}

function Invoke-Watch {
    [FixMyDesktop.DisplayWatcher]::Start()
    Write-Host "Watching for display changes (settle delay ${SettleSeconds}s). Press Ctrl+C to stop."
    $handled = [FixMyDesktop.DisplayWatcher]::Counter
    while ($true) {
        Start-Sleep -Seconds 1
        $count = [FixMyDesktop.DisplayWatcher]::Counter
        $idle = [Environment]::TickCount - [FixMyDesktop.DisplayWatcher]::LastTick
        if ($count -ne $handled -and $idle -ge ($SettleSeconds * 1000)) {
            $handled = $count
            try { Write-Host "[$(Get-Date -Format T)] Display changed - arranging."; Invoke-Arrange }
            catch { Write-Warning $_.Exception.Message }
        }
    }
}

if ($InstallStartup) {
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($startupLink)
    $lnk.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $lnk.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Watch -Screen {1}' -f $MyInvocation.MyCommand.Path, $Screen
    $lnk.WorkingDirectory = $root
    $lnk.Save()
    Write-Host "Installed: desktop will auto-arrange after display changes (starts at sign-in). $startupLink"
    return
}
if ($UninstallStartup) {
    if (Test-Path -LiteralPath $startupLink) { Remove-Item -LiteralPath $startupLink; Write-Host 'Startup entry removed.' }
    else { Write-Host 'No startup entry found.' }
    return
}
if ($Restore) { Invoke-Restore; return }
if ($Watch) { Invoke-Arrange; Invoke-Watch; return }
Invoke-Arrange
