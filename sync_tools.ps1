#Requires -Version 5.1
# =============================================================================
# sync_tools.ps1 - keeps the tooling on every USB HDD up to date
# =============================================================================
# Data stays per drive: plakar_repo, logs, work and .plakar_key are never
# copied, so a drive never gets another drive's snapshots. Only the tooling is
# synced.
#
# Two things make "always usable" true:
#   1. Before a drive's tooling is overwritten, its current copy is kept in
#      _known_good\. That is the version that was working on that drive, so a
#      bad sync can be undone with -Restore. It keeps one state per file (the state
#      before the most recent sync), not a history.
#   2. A tool may not be older than the version that wrote the repository on
#      that drive. plakar info prints the repository version; this script
#      compares it with the tool in the template root and reports a mismatch
#      without changing anything.
#
# Usage (no elevation needed, this only copies files):
#   .\sync_tools.ps1 -DryRun                 -> check every drive, copy nothing
#   .\sync_tools.ps1                         -> sync all removable drives
#   .\sync_tools.ps1 -Drives E:,F:           -> specific drives
#   .\sync_tools.ps1 -Restore                -> put _known_good back on the drive
#   .\sync_tools.ps1 -IncludeBinaries        -> also copy plakar.exe / plakar
#   .\sync_tools.ps1 -Force                  -> overwrite files the drive owns
#   .\sync_tools.ps1 -IncludeKey             -> also carry .plakar_key
#      (off by default; a drive with a different key is left alone unless -Force,
#      and that drive version is kept in _known_good)
#   .\sync_tools.ps1 -CheckUpdate         -> ask GitHub for the latest plakar release and compare it
#      with the tool in the template root, before syncing (needs network, copies nothing)
#   .\sync_tools.ps1 -Json                  -> one JSON object on stdout instead of the human lines,
#      so the web host can read it (used by the Tooling panel; nothing is copied unless -DryRun is off)
# =============================================================================

[CmdletBinding()]
param(
    [string[]]$Drives = @(),
    [string]$SourceDir = '',
    [switch]$DryRun,
    [switch]$Restore,
    [switch]$IncludeBinaries,
    [switch]$IncludeKey,
    [switch]$CheckUpdate,
    [switch]$Json,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($SourceDir)) { $SourceDir = $ScriptDir }

# The file list is explicit, so the data folders (plakar_repo, logs, work, .plakar_key)
# are never copied. Tooling file list: XMLs are copied lowercase to the drive root, because the
# hosts look them up in lowercase; .sh stays LF and .ps1/.bat stays CRLF, which
# a plain file copy preserves byte for byte.
$ToolFiles = @(
    'menu.ps1','menu.sh','backup.ps1','backup.sh','restore.ps1','restore.sh',
    'plakarusb.sh','reclaim.ps1','fix_acls.ps1','webserver.ps1','webui.bat',
    'howto.txt','README.txt','USMT_SETUP.md','WEBUI.md','.gitattributes','.gitignore',
    'web/index.html',
    'MigApp.xml','MigDocs.xml','MigModern.xml','MigUser.xml'
)
$Binaries = @('plakar.exe','plakar')

# In -Json mode the human lines are dropped and only the JSON is written, so this
# one function is the place where both modes differ.
function Say($msg) {
    if (-not $Json) { Write-Host $msg }
}

function Get-FileHash2($path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
}

function Manifest($base) {
    $m = [ordered]@{ at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); files = [ordered]@{} }
    foreach ($f in $ToolFiles) {
        $h = Get-FileHash2 (Join-Path $base $f)
        if ($h) { $m.files[$f] = $h }
    }
    foreach ($b in $Binaries) {
        $h = Get-FileHash2 (Join-Path $base $b)
        if ($h) { $m.files[$b] = $h }
    }
    return $m
}

function SaveJson($path, $data) {
    [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 6), $Utf8NoBom)
}

function TargetDirs {
    $dirs = @()
    if ($Drives.Count -gt 0) {
        foreach ($d in $Drives) {
            if ($d -match '\\') {
                # A full path, so a folder can be tested without a real drive.
                $dirs += $d
            } else {
                $root = "{0}:\" -f ($d.TrimEnd(':'))
                if (Test-Path -LiteralPath $root) { $dirs += (Join-Path $root 'Plakar_USB_Template') }
            }
        }
    } else {
        foreach ($v in Get-Volume) {
            if ($v.DriveType -eq 'Removable' -and $v.DriveLetter) {
                $root = "{0}:\" -f $v.DriveLetter
                $dirs += (Join-Path $root 'Plakar_USB_Template')
            }
        }
    }
    return $dirs | Where-Object { Test-Path -LiteralPath $_ }
}

# The tool that wrote a repository must not be newer than the tool on the drive.
function RepoVersion($dir) {
    $cfg = Join-Path $dir 'plakar_repo\CONFIG'
    if (-not (Test-Path -LiteralPath $cfg)) { return '' }
    $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($cfg))
    if ($text -match 'v\d+\.\d+\.\d+') { return $Matches[0] }
    return ''
}

function ToolVersion($dir) {
    $exe = Join-Path $dir 'plakar.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return '' }
    $v = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    if ($v) { return $v }
    # plakar.exe has no version resource, so ask the tool itself.
    $line = (& $exe -stdio version 2>$null | Select-Object -First 1)
    if ($line -match 'v\d+(\.\d+)*') { return $Matches[0] }
    return ''
}

# -1 when a is older than b, 1 when newer, 0 when equal.
function CompareVersion($a, $b) {
    $pa = ($a -replace '^v', '') -split '[.-]'
    $pb = ($b -replace '^v', '') -split '[.-]'
    for ($i = 0; $i -lt [math]::Max($pa.Count, $pb.Count); $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { $v = ($pa[$i] -replace '\D', ''); if ($v) { $x = [int]$v } }
        if ($i -lt $pb.Count) { $w = ($pb[$i] -replace '\D', ''); if ($w) { $y = [int]$w } }
        if ($x -ne $y) { return ($x - $y) }
    }
    return 0
}

function LatestPlakarVersion() {
    try {
        $j = Invoke-RestMethod -Uri 'https://api.github.com/repos/PlakarKorp/plakar/releases/latest' -TimeoutSec 20 -UserAgent 'sync_tools'
        if ($j.tag_name) { return $j.tag_name }
        return ''
    } catch { return '' }
}

function Get-UpdateInfo() {
    $local = ToolVersion $SourceDir
    $latest = LatestPlakarVersion
    if (-not $latest) { $status = 'GitHub not reachable, nothing checked' }
    elseif (-not $local) { $status = 'no plakar.exe in the template root to compare' }
    elseif ((CompareVersion $local $latest) -lt 0) { $status = 'behind - update the tool in the template root before syncing' }
    else { $status = 'up to date' }
    return @{ local = $local; latest = $latest; status = $status }
}

function Locked($dir) {
    $locks = Join-Path $dir 'plakar_repo\locks'
    $n = (Get-ChildItem -LiteralPath $locks -File -Force -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) { return "lock files in plakar_repo\locks ($n)" }
    foreach ($p in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) {
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.Name -match '^(plakar|powershell|pwsh)(\.exe)?$' -and $p.CommandLine -match [regex]::Escape($dir)) {
            return "process $($p.Name) PID $($p.ProcessId) is working on this drive"
        }
    }
    return ''
}

function HandleKey($dir) {
    if (-not $IncludeKey) { return 'key not asked (-IncludeKey)' }
    $srcKey = Join-Path $SourceDir '.plakar_key'
    if (-not (Test-Path -LiteralPath $srcKey)) { return 'no .plakar_key in the template root' }
    $driveKey = Join-Path $dir '.plakar_key'
    if (-not (Test-Path -LiteralPath $driveKey)) {
        if ($DryRun) { return 'key would be put on the drive' }
        Copy-Item -LiteralPath $srcKey -Destination $driveKey
        return 'key put on the drive (the drive had none)'
    }
    if ((Get-FileHash2 $driveKey) -eq (Get-FileHash2 $srcKey)) { return 'key already the same' }
    if ($Force) {
        $kgd = Join-Path $dir '_known_good'
        New-Item -ItemType Directory -Path $kgd -Force | Out-Null
        Copy-Item -LiteralPath $driveKey -Destination (Join-Path $kgd '.plakar_key') -Force
        if ($DryRun) { return 'key would be overwritten; drive version kept in _known_good' }
        Copy-Item -LiteralPath $srcKey -Destination $driveKey -Force
        return 'key overwritten, drive version kept in _known_good'
    }
    return 'drive has a different key - left alone (use -Force)'
}

function Handle-Drive($dir) {
    $r = [ordered]@{
        drive = $dir
        keyStatus = ''
        toolVersion = ''
        repoVersion = ''
        upToDate = $false
        diffCount = 0
        diff = @()
        localEdits = @()
        refused = ''
        copied = 0
        skipped = 0
        restored = 0
    }

    Say ''
    Say "=== $dir ==="
    $kg = Join-Path $dir '_known_good'
    $r.keyStatus = HandleKey $dir
    Say "  $($r.keyStatus)"

    if ($Restore) {
        if (-not (Test-Path -LiteralPath $kg)) { Say '  no _known_good on this drive, nothing to restore'; return $r }
        $why = Locked $dir
        if ($why) { $r.refused = $why; Say "  refused: $why"; return $r }
        foreach ($f in $ToolFiles + $Binaries) {
            $srcFile = Join-Path $kg $f
            if (-not (Test-Path -LiteralPath $srcFile)) { continue }
            Copy-Item -LiteralPath $srcFile -Destination (Join-Path $dir $f) -Force
            Say "  restored $f"
            $r.restored++
        }
        Say '  _known_good is kept, so this can be repeated.'
        return $r
    }

    $drive = Manifest $dir
    $diff = @()
    foreach ($f in $ToolFiles) {
        if ($src.files[$f] -and ($drive.files[$f] -ne $src.files[$f])) { $diff += $f }
    }
    if ($IncludeBinaries) {
        foreach ($b in $Binaries) {
            if ($src.files[$b] -and ($drive.files[$b] -ne $src.files[$b])) { $diff += $b }
        }
    }
    $r.diff = @($diff)
    $r.diffCount = $diff.Count
    $r.toolVersion = ToolVersion $dir
    $r.repoVersion = RepoVersion $dir

    if ($diff.Count -eq 0) {
        $r.upToDate = $true
        Say '  already up to date'
        return $r
    }

    # The tool on the drive must be at least as new as the tool that wrote the repo.
    $rv = $r.repoVersion
    $tv = $r.toolVersion
    if ($rv) {
        $shown = if ($tv) { $tv } else { 'not present on this drive' }
        Say "  repository was written by plakar $rv, tool on this drive is $shown"
        if ($tv -and (CompareVersion $tv $rv) -lt 0) {
            $r.refused = 'tool older than the version that wrote its repository'
            Say '  REFUSED: this drive has an older plakar than the one that wrote its repository. Restore _known_good or copy a newer plakar.exe first.'
            return $r
        }
    }
    $why = Locked $dir
    if ($why) { $r.refused = $why; Say "  refused: $why"; return $r }

    # A file whose hash is not the one the last sync put on this drive was edited
    # on the drive itself. It is kept in _known_good, and skipped here unless -Force.
    $prevHash = @{}
    $stamp = Join-Path $dir 'tool_version.json'
    if (Test-Path -LiteralPath $stamp) {
        try {
            $j = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
            foreach ($p in $j.files.PSObject.Properties) { $prevHash[$p.Name] = $p.Value }
        } catch { }
    }
    $local = @()
    foreach ($f in $diff) {
        if ($prevHash[$f] -and $drive.files[$f] -and $drive.files[$f] -ne $prevHash[$f]) { $local += $f }
    }
    $r.localEdits = @($local)
    if ($local.Count -gt 0 -and -not $Force) {
        Say ("  drive has its own edits in: " + ($local -join ', ') + ' - skipped (use -Force)')
    }

    Say ("  " + $diff.Count + " file(s) differ:")
    foreach ($f in $diff) { Say "    $f" }

    if ($DryRun) { return $r }

    # Keep the drive's current working copy before touching it.
    New-Item -ItemType Directory -Path $kg -Force | Out-Null
    foreach ($f in $diff) {
        $here = Join-Path $dir $f
        if (Test-Path -LiteralPath $here) {
            $dest = Join-Path $kg $f
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item -LiteralPath $here -Destination $dest -Force
        }
    }
    $kgManifest = [ordered]@{
        at = $drive.at
        note = 'the tooling that was on this drive before this sync'
        files = $drive.files
    }
    SaveJson (Join-Path $kg 'manifest.json') $kgManifest

    $copied = 0
    $skipped = 0
    foreach ($f in $diff) {
        if (-not $Force -and ($local -contains $f)) { $skipped++; continue }
        New-Item -ItemType Directory -Path (Split-Path (Join-Path $dir $f)) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $SourceDir $f) -Destination (Join-Path $dir $f) -Force
        $copied++
    }
    # The stamp records what is actually on the drive now, so a later run can tell
    # a drive-local edit from a file this script put there.
    SaveJson (Join-Path $dir 'tool_version.json') (Manifest $dir)
    $r.copied = $copied
    $r.skipped = $skipped
    Say ("  " + $copied + " copied, " + $skipped + " skipped. Previous copy kept in: $kg")
    return $r
}

$src = Manifest $SourceDir
$targets = @(TargetDirs)
$report = [ordered]@{
    at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    sourceDir = $SourceDir
    masterTool = ToolVersion $SourceDir
    update = if ($CheckUpdate) { Get-UpdateInfo } else { $null }
    drives = @()
}

if ($targets.Count -eq 0) {
    Say 'No drive with a Plakar_USB_Template folder found. Plug a USB HDD in, or use -Drives E:,F:.'
}
foreach ($dir in $targets) {
    $report.drives = @($report.drives + (Handle-Drive $dir))
}

if ($Json) { Write-Output ($report | ConvertTo-Json -Depth 6) }