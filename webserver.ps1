# =============================================================================
# webserver.ps1 - local host process for web/index.html (technician menu page)
#
# REBUILT 2026-10-14. The original file was found zero-filled: 42,139 NUL bytes,
# last written 2026-10-14 05:23:04, untracked in git, no other copy on the disk,
# clusters physically allocated but all zeros. Nothing of it was recoverable.
# This reconstruction follows the intact contract in web/index.html and WEBUI.md,
# plus the proven tool logic in menu.ps1 / backup.ps1 / restore.ps1.
# The zeroed original is kept as evidence at
#   _acl_report\webserver_corrupted_20261014.bin
#
#   http://localhost:8765            (-Port to change)
#   GET  /            -> web/index.html
#   GET  /api/info    -> repo info, health, stores, users, jobs
#   GET  /api/jobs    -> job list (Activity panel, polled every second)
#   POST /api/key     -> save + test-unlock the passphrase
#   POST /api/run     -> start an action as a background job
#
# Actions: plakar_backup plakar_restore plakar_delete plakar_list plakar_check
#          plakar_maintenance plakar_prune plakar_locate plakar_ui usmt_scan
#          usmt_offline usmt_restore usmt_check store_details open_private_url
#          tool_update_check tool_sync
#
# Each job writes its own log: logs\<jobid>_<action>.log, and ends with
# "EXITCODE: n" like the earlier host did. USMT writes its own log outside the
# store (logs\<jobid>_scanstate.log / _loadstate.log / _usmtutils.log); the pool
# allows four jobs at a time, so USMT actions queue on a mutex because only one
# migration tool can run at once (USMT code 29). Exit code 3 is reported as
# status "partial" because /c skipped errors.
# =============================================================================

param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$NoElevate,
    [string]$GracePeriod = ''
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ScriptDrive = Split-Path -Qualifier $ScriptDir
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------------------
# Self-elevation, the same way menu.ps1 does it. If UAC is declined we keep
# running un-elevated instead of exiting, so the page still works for read-only
# panels; plakar/USMT operations will then fail on permissions.
# ---------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin -and -not $NoElevate) {
    $PSexe = (Get-Process -Id $PID).Path
    $re = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port"
    if ($NoBrowser)  { $re += ' -NoBrowser' }
    if ($NoElevate)  { $re += ' -NoElevate' }
    if ($GracePeriod){ $re += " -GracePeriod `"$GracePeriod`"" }
    try {
        Start-Process -FilePath $PSexe -ArgumentList $re -Verb RunAs
        exit
    } catch {
        Write-Host "Elevation was declined. Continuing un-elevated." -ForegroundColor Yellow
        $IsAdmin = $false
    }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$Repo      = Join-Path $ScriptDir 'plakar_repo'
$PlakarExe = Join-Path $ScriptDir 'plakar.exe'
$KeyFile   = Join-Path $ScriptDir '.plakar_key'
$LogFolder = Join-Path $ScriptDir 'logs'
$HealthFile = Join-Path $LogFolder 'health.json'
$WebRoot    = Join-Path $ScriptDir 'web'
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder | Out-Null }

# USMT logs and its working directory must stay outside StorePath: /l inside the
# store is rejected (code 13) and a _work folder inside the store gets gathered,
# listed as a "user", and backed up to Plakar.
$WorkFolder = Join-Path $ScriptDir 'work'
if (-not (Test-Path $WorkFolder)) { New-Item -ItemType Directory -Path $WorkFolder | Out-Null }

# USMT writes its log and progress files in the OEM code page (850 on this PC),
# not UTF-8. Capture it once: /api/info temporarily switches
# [Console]::OutputEncoding to UTF-8, so a job runspace must not read it live.
$OemEncoding = [Console]::OutputEncoding

# A verbose USMT run can emit hundreds of thousands of lines. The in-memory view
# is capped so a long scan cannot grow without limit; the per-job log file still
# keeps everything.
$MaxJobLines = 5000

# Only one migration tool can run at a time (USMT code 29). The runspace pool
# allows up to four jobs, so USMT jobs are serialised through this mutex. Named
# so a scanstate started from menu.ps1 on the same machine is also seen.
$UsmtGate = New-Object System.Threading.Mutex($false, 'PlakarUSB-USMT-Gate')

# USMT: architecture + folder detection, same candidates as menu.ps1. The ADK has
# no arm64 USMT build, so ARM64 machines run the x86 tools.
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' } }
if ($Arch -eq 'ARM64') { $ArchCandidates = @('amd64', 'ARM64', 'x86') } else { $ArchCandidates = @($Arch, 'X64', 'x86') }
$USMTPath = $null
$candidates = @()
foreach ($candArch in $ArchCandidates) {
    $candidates += (Join-Path $ScriptDir "USMT\$candArch")
    $candidates += (Join-Path $ScriptDir "..\USMT\$candArch")
}
$drive = Split-Path -Qualifier $ScriptDir
if ($drive) {
    foreach ($candArch in $ArchCandidates) { $candidates += (Join-Path $drive "USMT\$candArch") }
}
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'scanstate.exe')) { $USMTPath = $c; break }
}
if (-not $USMTPath) { $USMTPath = Join-Path $ScriptDir "USMT\$Arch" }

# Return codes shared by scanstate / loadstate / usmtutils.
# https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes
$UsmtCodeText = @{
    0  = 'Success'
    1  = 'Help requested'
    2  = 'Cancelled (Ctrl+C, or an EFS file aborted the run)'
    3  = 'At least one error was skipped because of /c - partial success'
    11 = 'Invalid parameters'
    12 = 'Argument or store path longer than 256 characters'
    13 = 'Log path is invalid (/l must be outside the store)'
    14 = '/lac was used without a password'
    26 = 'Initialization error (offline XML entries, or multiple Windows installs)'
    27 = 'Invalid store location (unusable, read-only, or store on the system drive)'
    28 = 'XML file specified with /i is missing or invalid'
    29 = 'Migration could not start (250 MB temp space, working dir, or another USMT tool running)'
    31 = 'Discover phase failed'
    32 = 'Could not set the migration type'
    33 = 'Keyfile error'
    34 = 'Insufficient rights (run as Administrator)'
    35 = 'Store could not be deleted (reboot, or use usmtutils /rd)'
    36 = 'Unsupported platform (/offline requires WinPE)'
    37 = 'Encrypted store but no key was provided'
    38 = 'Store is corrupted (looks encrypted but is not)'
    39 = 'Config.xml could not be read'
    40 = 'Progress log could not be created'
    41 = 'Progress file could not be created'
    42 = 'Store is corrupted'
    61 = 'Stopped on an I/O error (non-fatal)'
    71 = 'Environment initialization failed (needs elevated privileges)'
    72 = 'Fatal migration error'
}

function Get-USMTCodeText {
    param([int]$Code)
    if ($UsmtCodeText.ContainsKey($Code)) { return $UsmtCodeText[$Code] }
    return 'Unknown return code'
}

function Read-USMTManifest {
    param([string]$StorePath)
    $p = Join-Path $StorePath 'store_manifest.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Resolve-USMTXmlFile {
    param([string]$FileName)
    $inUsmt = Join-Path $USMTPath $FileName
    if (Test-Path $inUsmt) { return $inUsmt }
    $inRoot = Join-Path $ScriptDir $FileName
    if (Test-Path $inRoot) { return $inRoot }
    return $inUsmt
}

# ---------------------------------------------------------------------------
# Keyfile handling. plakar reads .plakar_key raw, so the BOM can be part of the
# passphrase. Try the encoding variants and keep the one that unlocks.
# ---------------------------------------------------------------------------
function Concat-Bytes {
    param([byte[]]$Left, [byte[]]$Right)
    if (-not $Left -or $Left.Length -eq 0) { return [byte[]]$Right }
    if (-not $Right -or $Right.Length -eq 0) { return [byte[]]$Left }
    $out = New-Object byte[] ($Left.Length + $Right.Length)
    [Array]::Copy($Left, 0, $out, 0, $Left.Length)
    [Array]::Copy($Right, 0, $out, $Left.Length, $Right.Length)
    return [byte[]]$out
}

function Get-TrailingTrimmedBytes {
    param([byte[]]$Data)
    if (-not $Data -or $Data.Length -eq 0) { return [byte[]]@() }
    $n = $Data.Length
    while ($n -gt 0 -and ($Data[$n-1] -eq 9 -or $Data[$n-1] -eq 10 -or $Data[$n-1] -eq 13 -or $Data[$n-1] -eq 32)) { $n-- }
    if ($n -le 0) { return [byte[]]@() }
    if ($n -eq $Data.Length) { return [byte[]]$Data }
    $out = New-Object byte[] $n
    [Array]::Copy($Data, 0, $out, 0, $n)
    return $out
}

$KeyArgs = @()
if (Test-Path -LiteralPath $KeyFile) { $KeyArgs = @('-keyfile', $KeyFile) }

function Test-PlakarRepoUnlock {
    param([string[]]$K)
    if ($K.Count -eq 0) { return $true }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    try {
        # Empty stdin. Without a keyfile plakar asks for the passphrase, and a prompt in
        # a background host never gets an answer. Piping an empty string gives it EOF, so
        # it fails fast instead of blocking the caller.
        '' | & $PlakarExe @K -quiet at $Repo ls 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false } finally { $ErrorActionPreference = $prev }
}

function Resolve-PlakarKeyFile {
    # 'no keyfile' is neutral: it is correct both for a genuinely unencrypted repository
    # and for an encrypted one whose passphrase file has gone missing. The page shows
    # keyOk separately, so the difference is visible there.
    if (-not (Test-Path -LiteralPath $KeyFile)) { return 'no keyfile' }
    if (Test-PlakarRepoUnlock $KeyArgs) { return 'ok' }

    $bytes = [System.IO.File]::ReadAllBytes($KeyFile)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $body = $bytes
    if ($hasBom) { $body = New-Object byte[] ($bytes.Length - 3); [Array]::Copy($bytes, 3, $body, 0, $body.Length) }
    $body = Get-TrailingTrimmedBytes $body
    $bom = [byte[]](0xEF,0xBB,0xBF); $lf = [byte[]](10); $crlf = [byte[]](13,10)
    $variants = @($body, (Concat-Bytes $bom $body), (Concat-Bytes $body $lf), (Concat-Bytes $body $crlf),
                  (Concat-Bytes (Concat-Bytes $bom $body) $lf), (Concat-Bytes (Concat-Bytes $bom $body) $crlf))

    $tmp = Join-Path $env:TEMP ('plakar-key-' + [guid]::NewGuid().ToString('N'))
    try {
        foreach ($v in $variants) {
            if (-not $v -or $v.Length -eq 0) { continue }
            [System.IO.File]::WriteAllBytes($tmp, [byte[]]$v)
            if (Test-PlakarRepoUnlock @('-keyfile', $tmp)) {
                [System.IO.File]::WriteAllBytes($KeyFile, [byte[]]$v)
                $script:KeyArgs = @('-keyfile', $KeyFile)
                return 'ok (encoding fixed)'
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return 'did not unlock'
}

$KeyStatus = Resolve-PlakarKeyFile

# Junk patterns for plakar backups, same list as menu.ps1. plakar uses gitignore
# semantics: a pattern containing a slash is anchored to the snapshot root, so
# 'AppData/Local/Temp/' does NOT match. A bare name matches at any depth, which is what
# these are. They are opt-in per job rather than always on, because a technician
# sometimes wants Temp for forensics and a cache is only regenerable if the machine is
# still running. The page sends excludeJunk with each backup; the default there is on.
$JunkPatterns = @('Temp/','Cache/','INetCache/','Thumbnails/','Explorer/','NuGet/','npm-cache/','pkg-npm-caches/','*.tmp')

# ---------------------------------------------------------------------------
# Jobs: runspace pool, one runspace per job, log file per job
# ---------------------------------------------------------------------------
$Jobs = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$Pool = [runspacefactory]::CreateRunspacePool(1, 4)
$Pool.Open()

$HealthLock = New-Object System.Threading.Mutex

# The job body runs in a runspace, so every helper it needs must be defined
# inside the script block itself - functions from the main script are not
# visible there.
$JobBody = {
    param($Ctx, $Job)

    $utf8 = New-Object System.Text.UTF8Encoding $false

    function Update-Health {
        param([string]$Kind, [hashtable]$Data)
        $null = $Ctx.HealthLock.WaitOne()
        try {
            $h = @{}
            if (Test-Path -LiteralPath $Ctx.HealthFile) {
                try {
                    $obj = Get-Content -LiteralPath $Ctx.HealthFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($obj) {
                        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
                    }
                } catch { $h = @{} }
            }
            $h[$Kind] = $Data
            [System.IO.File]::WriteAllText($Ctx.HealthFile, ($h | ConvertTo-Json -Depth 5), $utf8)
        } finally { $Ctx.HealthLock.ReleaseMutex() }
    }

    function AddLine {
        param([string]$s)
        $Job.Lines.Enqueue($s)
        $dropped = ''
        while ($Job.Lines.Count -gt $Ctx.MaxLines) {
            [void]$Job.Lines.TryDequeue([ref]$dropped)
        }
        try { [System.IO.File]::AppendAllText($Job.LogFile, $s + "`r`n", $utf8) } catch { }
    }

    # menu.sh and menu.ps1 cap their logs; the web host writes one log per job,
    # so cap them the same way: gzip anything over 10 MB, keep the newest 5 .gz files.
    function Rotate-Logs {
        param([string]$Dir, [int]$MaxMb = 10, [int]$Keep = 5)
        if (!(Test-Path -LiteralPath $Dir)) { return }
        try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch { }
        $limit = $MaxMb * 1MB
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
            if ($f.Length -le $limit) { continue }
            $gz = $f.FullName + '.gz'
            try {
                $in = [System.IO.File]::OpenRead($f.FullName)
                try {
                    $out = [System.IO.File]::Create($gz)
                    try {
                        $zip = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
                        try { $in.CopyTo($zip) } finally { $zip.Dispose() }
                    } finally { $out.Dispose() }
                } finally { $in.Dispose() }
                Remove-Item -LiteralPath $f.FullName -Force
            } catch { }
        }
        $old = @(Get-ChildItem -LiteralPath $Dir -Filter '*.log.gz' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($old.Count -gt $Keep) { $old | Select-Object -Skip $Keep | Remove-Item -Force -ErrorAction SilentlyContinue }
    }

    # Reads only the bytes appended since the last call. USMT holds its log and
    # progress files open for writing, so the file must be opened with
    # FileShare ReadWrite. Only complete lines are returned; a half-written last
    # line is left for the next poll.
    function Read-NewTailLines {
        param([string]$Path, [hashtable]$State)
        $out = @()
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $out }
        $st = $State[$Path]
        if (-not $st) { $st = @{ pos = 0; enc = $Ctx.OemEncoding }; $State[$Path] = $st }
        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            try {
                if ($st.pos -gt $fs.Length) { $st.pos = 0 }   # file truncated or recreated
                [void]$fs.Seek($st.pos, [System.IO.SeekOrigin]::Begin)
                $buf = New-Object byte[] 65536
                $ms = New-Object System.IO.MemoryStream
                while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
                $bytes = $ms.ToArray()
                $ms.Dispose()
                if ($bytes.Length -eq 0) { return $out }
                if ($st.pos -eq 0) {
                    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $st.enc = [System.Text.Encoding]::Unicode }
                    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $st.enc = $utf8 }
                }
                $nl = -1
                for ($i = $bytes.Length - 1; $i -ge 0; $i--) { if ($bytes[$i] -eq 10) { $nl = $i; break } }
                if ($nl -lt 0) { return $out }   # partial line, wait for the newline
                $text = $st.enc.GetString($bytes, 0, $nl + 1)
                if ($st.pos -eq 0) { $text = $text.TrimStart([char]0xFEFF) }
                $st.pos += $nl + 1
                foreach ($l in ($text -split "`r?`n")) {
                    if ($l.Trim() -ne '') { $out += $l.Trim() }
                }
            } finally { try { $fs.Dispose() } catch { } }
        } catch { }
        return $out
    }

    # --- USMT helpers (the job body runs in a runspace, so they live here) ---
    function Get-USMTCodeText {
        param([int]$Code)
        if ($Ctx.CodeText.ContainsKey($Code)) { return $Ctx.CodeText[$Code] }
        return 'Unknown return code'
    }

    function ConvertTo-SafeName {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return 'item' }
        $clean = ($Text -replace '[^\w.\-]', '_')
        if ([string]::IsNullOrWhiteSpace($clean)) { return 'item' }
        return $clean
    }

    # Where the browser actually is. Get-Command only finds it when it is on PATH,
    # and Edge is not; App Paths is where the installer registers it. The fallback
    # paths need ${env:ProgramFiles(x86)} with braces - inside a double-quoted string,
    # "$env:ProgramFiles(x86)" expands to 'C:\Program Files' plus the literal '(x86)',
    # which is a path that can never exist. That is why the Shortcuts buttons did
    # nothing on a 64-bit machine, where Edge lives in the (x86) folder.
    function Resolve-Browser {
        param([string]$ExeName, [string]$SubPath)
        $ap = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName" -ErrorAction SilentlyContinue).'(default)'
        if ($ap -and (Test-Path -LiteralPath $ap)) { return $ap }
        $cmd = (Get-Command $ExeName -ErrorAction SilentlyContinue).Source
        if ($cmd) { return $cmd }
        foreach ($root in @($env:ProgramFiles, "${env:ProgramFiles(x86)}")) {
            $p = Join-Path (Join-Path $root $SubPath) $ExeName
            if (Test-Path -LiteralPath $p) { return $p }
        }
        return $null
    }

    function Read-USMTManifest {
        param([string]$StorePath)
        $p = Join-Path $StorePath 'store_manifest.json'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        try {
            $raw = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return $raw | ConvertFrom-Json
        } catch { return $null }
    }

    function Write-USMTManifest {
        param([string]$StorePath, [hashtable]$Info)
        try {
            [System.IO.File]::WriteAllText((Join-Path $StorePath 'store_manifest.json'), ($Info | ConvertTo-Json -Depth 5), $utf8)
        } catch { AddLine "WARNING: could not write store manifest: $($_.Exception.Message)" }
    }

    function Ensure-USMTWorkDir {
        param([string]$JobName)
        $wd = Join-Path $Ctx.WorkFolder (ConvertTo-SafeName $JobName)
        if (-not (Test-Path -LiteralPath $wd)) {
            try { New-Item -ItemType Directory -Path $wd -ErrorAction Stop | Out-Null } catch { }
        }
        # USMT needs about 250 MB of writable temp space (USMT code 29).
        $env:USMT_WORKING_DIR = $wd
        return $wd
    }

    # /localonly only covers drives the OS reports as Removable or Network. A USB
    # drive that Windows presents as Fixed media is still scanned, so the drive
    # this tool runs from needs an explicit unconditionalExclude for its root. The
    # letter changes with every PC, so the rule is generated per run. It changes
    # what ScanState reads, not where it writes: USMT already excludes StorePath
    # from the scan, so a store that lives on the USB drive is written normally.
    function Write-UsbExclusionXml {
        param([string]$WorkDir, [string]$DriveRoot)
        if ([string]::IsNullOrWhiteSpace($DriveRoot)) { return '' }
        if (-not $DriveRoot.EndsWith('\')) { $DriveRoot += '\' }
        $p = Join-Path $WorkDir 'exclude_usb.xml'
        $xml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n" +
               "<!-- Generated for this run only. The drive letter is the USB drive this tool" +
               " runs from, which changes with every PC, so it cannot be a shipped rule. -->`n" +
               "<migration urlid=`"http://www.microsoft.com/migration/1.0/migxmlext/excludeusb`">`n" +
               "    <component type=`"Documents`" context=`"System`">`n" +
               "        <displayName>Exclude the USB drive the tool runs from</displayName>`n" +
               "        <role role=`"Data`">`n" +
               "            <rules>`n" +
               "                <unconditionalExclude>`n" +
               "                    <objectSet>`n" +
               "                        <pattern type=`"File`">${DriveRoot}*[*]</pattern>`n" +
               "                    </objectSet>`n" +
               "                </unconditionalExclude>`n" +
               "            </rules>`n" +
               "        </role>`n" +
               "    </component>`n" +
               "</migration>"
        try {
            [System.IO.File]::WriteAllText($p, $xml, $utf8)
            return $p
        } catch {
            AddLine "WARNING: could not write the USB exclusion rule: $($_.Exception.Message)"
            return ''
        }
    }

    function Test-USMTStoreLocation {
        param([string]$StorePath)
        $ok = $true
        if ($StorePath.Length -gt 256) {
            AddLine "WARNING: store path is $($StorePath.Length) characters; USMT limits it to 256 (code 12)."
            $ok = $false
        }
        try {
            $q = Split-Path -Qualifier $StorePath
            if ($q) {
                $letter = $q.TrimEnd(':').TrimEnd('\')
                $sys = ($env:SystemDrive -replace ':', '')
                if ($letter -and $letter -ieq $sys) {
                    AddLine "WARNING: the store is on the system drive ($q); USMT rejects stores on C:\ (code 27)."
                    $ok = $false
                }
                $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $letter }
                if ($vol -and $vol.FileSystemType -ne 'NTFS') {
                    AddLine "WARNING: $q is $($vol.FileSystemType); USMT needs NTFS for large stores (code 27)."
                    $ok = $false
                }
            }
        } catch { }
        return $ok
    }

    function Acquire-USMTGate {
        param([int]$TimeoutMs)
        try { return $Ctx.USMTGate.WaitOne($TimeoutMs) } catch { return $false }
    }

    function Resolve-USMTOptions {
        param($Payload)
        $efs = [string]$Payload.efs
        if (-not @('abort', 'skip', 'decryptcopy', 'copyraw') -contains $efs) { $efs = 'skip' }
        return @{
            EfsMode    = $efs
            NoCompress = [bool]$Payload.nocompress
            LocalOnly  = if ($null -eq $Payload.localonly) { $true } else { [bool]$Payload.localonly }
            ExcludeUsb = if ($null -eq $Payload.excludeUsb) { $true } else { [bool]$Payload.excludeUsb }
            KeyFile    = [string]$Payload.keyfile
        }
    }

    function Build-ScanArgs {
        param([string]$Store, [string[]]$Xmls, [string[]]$Users, [hashtable]$Opts, [string]$LogPath, [string]$ProgressPath, [string]$OfflineXml)
        $argv = @($Store)
        foreach ($x in $Xmls) { $argv += "/i:$x" }
        if ($Users.Count -gt 0) { foreach ($u in $Users) { $argv += "/ui:$u" } } else { $argv += '/all' }
        if (-not [string]::IsNullOrWhiteSpace($OfflineXml)) { $argv += "/offline:$OfflineXml" }
        if ($Opts.LocalOnly) { $argv += '/localonly' }
        $argv += "/efs:$($Opts.EfsMode)"
        $argv += @('/o', '/c', '/v:5')
        $argv += "/l:$LogPath"
        # /progress cannot be inside StorePath either (code 13/40). It is the file
        # that records what /c skipped, and RunTool tails it so the Activity panel
        # shows activity while the scan is running.
        if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) { $argv += "/progress:$ProgressPath" }
        if ($Opts.NoCompress) { $argv += '/nocompress' }
        if ($Opts.KeyFile) { $argv += @('/encrypt', "/keyfile:$($Opts.KeyFile)") }
        return $argv
    }

    # Windows joins ProcessStartInfo.Arguments with C runtime quoting rules.
    # A trailing backslash must be doubled or it escapes the closing quote.
    function ConvertTo-WinArgument {
        param([string]$Value)
        if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
        if ($Value -notmatch '[\s"]') { return $Value }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $Value.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append('\', ($slashes * 2) + 1)
                [void]$sb.Append('"')
                $slashes = 0
                continue
            }
            if ($slashes -gt 0) { [void]$sb.Append('\', $slashes); $slashes = 0 }
            [void]$sb.Append($ch)
        }
        if ($slashes -gt 0) { [void]$sb.Append('\', ($slashes * 2)) }
        [void]$sb.Append('"')
        return $sb.ToString()
    }

    function RunTool {
        param([string]$exe, [string[]]$argv, [string[]]$TailPaths = @(), [string]$SkipTag = '')
        if (-not (Test-Path -LiteralPath $exe)) { AddLine "ERROR: tool not found: $exe"; return 1 }
        # plakar writes UTF-8. PowerShell's & operator decodes a pipe with the
        # OEM code page (850 on this PC), so the check mark U+2713 (bytes
        # E2 9C 93) is stored as the three characters Ô£ô. Decode plakar
        # ourselves. USMT writes the OEM code page, so leave that alone.
        $enc = if ([IO.Path]::GetFileName($exe) -ieq 'plakar.exe') { $utf8 } else { $Ctx.OemEncoding }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # plakar prompts for the passphrase when there is no keyfile. A background host
        # has nobody to answer that prompt, so the process waits forever and the single
        # HTTP loop stops serving anything behind it - the page appears frozen. Close
        # stdin instead: the prompt reads EOF and plakar exits with the unlock error.
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = $enc
        $psi.StandardErrorEncoding = $enc
        $quoted = foreach ($a in $argv) { ConvertTo-WinArgument ([string]$a) }
        $psi.Arguments = $quoted -join ' '
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            if (-not $proc.Start()) { AddLine "ERROR: could not start $exe"; return 1 }
            try { $proc.StandardInput.Close() } catch { }
            # Read line by line, not to EOF. A busy scanstate keeps its pipes open
            # for minutes and writes its activity to the /l: log and the /progress:
            # file, so reading to EOF would show nothing until the tool exits.
            # ReadLineAsync keeps stderr flowing while this loop polls stdout, the
            # tail files, and the process. Every buffered line is drained in one
            # pass: taking a single line per poll capped plakar at about 4 lines/s
            # (the pipe fills, the tool blocks on its next write, and we only pick
            # up one line per poll).
            $outTask = $proc.StandardOutput.ReadLineAsync()
            $errTask = $proc.StandardError.ReadLineAsync()
            $outDone = $false
            $errDone = $false
            $tailState = @{}
            $lastActivity = Get-Date
            $exeName = [IO.Path]::GetFileName($exe)
            # plakar marks what it could not read with KO. A file that is in use (an
            # Outlook OST, a browser cache, the NTFS journal) is skipped and the run still
            # exits 0, so without a count the page cannot tell what was not captured.
            # Same rule as menu.ps1: count the lines, and when a snapshot tag is passed
            # write the paths to logs\skipped_<tag>.txt so a technician can read them
            # after the run. The raw KO lines stay in the job log as before.
            $skipped = 0
            $koLines = @()
            while ($true) {
                while (-not $outDone -and $outTask.Wait(0)) {
                    try { $line = $outTask.Result } catch { $line = $null }
                    if ($null -eq $line) { $outDone = $true; break }
                    AddLine $line; $lastActivity = Get-Date
                    if ($exeName -ieq 'plakar.exe' -and $line -like '*: KO *') { $skipped++; $koLines += $line }
                    $outTask = $proc.StandardOutput.ReadLineAsync()
                }
                while (-not $errDone -and $errTask.Wait(0)) {
                    try { $line = $errTask.Result } catch { $line = $null }
                    if ($null -eq $line) { $errDone = $true; break }
                    AddLine $line; $lastActivity = Get-Date
                    if ($exeName -ieq 'plakar.exe' -and $line -like '*: KO *') { $skipped++; $koLines += $line }
                    $errTask = $proc.StandardError.ReadLineAsync()
                }
                foreach ($tp in $TailPaths) {
                    foreach ($l in (Read-NewTailLines -Path $tp -State $tailState)) { AddLine $l; $lastActivity = Get-Date }
                }
                if ($outDone -and $errDone -and $proc.HasExited) { break }
                # Long quiet phases (a big file, a locked profile) look like a hang
                # in the Activity panel, so say the tool is still working.
                if ($TailPaths.Count -gt 0 -and ((Get-Date) - $lastActivity).TotalSeconds -ge 30) {
                    $lastActivity = Get-Date
                    AddLine "STILL RUNNING: $exeName is working (no new output for 30 s, $($Job.Lines.Count) lines so far)"
                }
                Start-Sleep -Milliseconds 25
            }
            # Drain whatever the tail files still hold after the tool exited.
            foreach ($tp in $TailPaths) {
                foreach ($l in (Read-NewTailLines -Path $tp -State $tailState)) { AddLine $l }
            }
            $proc.WaitForExit()
            if ($skipped -gt 0) {
                AddLine "SKIPPED: $skipped entries could not be read. The paths are in the lines above and in the job log."
                # menu.ps1 writes the same list to logs\skipped_<tag>.txt; the web host does
                # the same when the job knows its snapshot tag, so the three hosts agree.
                if ($SkipTag -and $koLines.Count -gt 0) {
                    $skipFile = Join-Path $Ctx.LogFolder ('skipped_' + $SkipTag + '.txt')
                    try {
                        [System.IO.File]::WriteAllText($skipFile, (($koLines -join "`r`n") + "`r`n"), $utf8)
                        AddLine "Skipped paths written to: $skipFile"
                    } catch { AddLine "Could not write the skipped list: $($_.Exception.Message)" }
                }
            }
            return $proc.ExitCode
        } catch {
            AddLine "ERROR: $($_.Exception.Message)"
            return 1
        } finally {
            try { $proc.Dispose() } catch { }
        }
    }

    function LockHint {
        param([string]$actionName)
        $lockDir = Join-Path $Ctx.Repo 'locks'
        $files = @(Get-ChildItem -LiteralPath $lockDir -File -Force -ErrorAction SilentlyContinue)
        $procs = @(Get-Process -Name 'plakar' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
        if ($files.Count -eq 0) { return "HINT: $actionName failed for another reason; see the lines above." }
        if ($procs.Count -gt 0) {
            return "HINT: $actionName needs the exclusive repository lock, held by the running plakar process (PID $(($procs | ForEach-Object { $_.Id }) -join ', ')). Close the Plakar UI window or stop that process, then run $actionName again."
        }
        return "HINT: $actionName needs the exclusive repository lock, but no other plakar process is running. The lock file in plakar_repo\locks is stale (left by a plakar that died mid-run). Copy it somewhere, delete it, then run $actionName again."
    }

    $code = 0
    $ka = $Ctx.KeyArgs

    switch ($Job.Action) {

        'plakar_list' {
            $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'ls', '-tags'))
        }

        'plakar_check' {
            AddLine 'Running fast integrity check (read-only, nothing is modified)...'
            $before = @()
            $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'check'))
            $flagged = 0
            foreach ($l in $Job.Lines) {
                if ($l -match 'check completed without errors') { continue }
                if ($l -match 'ERROR|error:|corrupt|missing|failed|flagged') { $flagged++ }
            }
            Update-Health 'check' @{ at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); exitCode = $code; flagged = $flagged }
        }

        'plakar_maintenance' {
            AddLine 'Running maintenance (reclaims orphaned packfiles)...'
            if ($Ctx.GracePeriod) { AddLine "Grace period override: $Ctx.GracePeriod (coloured packfiles can be deleted in this run)" }
            $saved = $env:PLAKAR_GRACEPERIOD
            try {
                if ($Ctx.GracePeriod) { $env:PLAKAR_GRACEPERIOD = $Ctx.GracePeriod }
                $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'maintenance'))
            } finally {
                if ($Ctx.GracePeriod) { $env:PLAKAR_GRACEPERIOD = $saved }
            }
            $coloured = 0; $orphaned = 0; $rmBlobs = 0; $rmPacks = 0
            foreach ($l in $Job.Lines) {
                if ($l -match 'Coloured (\d+) packfiles \((\d+) orphaned\)') { $coloured = [int]$Matches[1]; $orphaned = [int]$Matches[2] }
                if ($l -match '(\d+) blobs and (\d+) packfiles were removed') { $rmBlobs = [int]$Matches[1]; $rmPacks = [int]$Matches[2] }
            }
            if ($code -ne 0) { AddLine (LockHint 'maintenance') }
            Update-Health 'maintenance' @{
                at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); exitCode = $code
                coloured = $coloured; orphaned = $orphaned
                removedBlobs = $rmBlobs; removedPackfiles = $rmPacks
            }
        }

        'plakar_backup' {
            $folder = $Job.Payload.folder
            $tag = $Job.Payload.tag
            if ([string]::IsNullOrWhiteSpace($folder)) { AddLine 'ERROR: folder cannot be empty.'; $code = 1; break }
            if (-not (Test-Path -LiteralPath $folder)) { AddLine "ERROR: path not found: $folder"; $code = 1; break }
            if ([string]::IsNullOrWhiteSpace($tag)) { $tag = 'backup' }
            $snapTag = "${tag}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

            $ignoreArgs = @()
            if ($Job.Payload.excludeJunk) {
                foreach ($pattern in $Ctx.JunkPatterns) { $ignoreArgs += @('-ignore', $pattern) }
                AddLine "Excluding junk: $($Ctx.JunkPatterns -join ', ')"
            }

            AddLine "Backing up $folder as $snapTag ..."
            # -name, -environment and -category are stored in the snapshot metadata. They
            # are what make prune and locate filterable once the stick holds profiles from
            # several machines; the tag alone is not enough.
            $category = if ([string]::IsNullOrWhiteSpace($Job.Payload.category)) { 'profile' } else { [string]$Job.Payload.category }
            $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'backup') + $ignoreArgs +
                @('-name', $tag, '-environment', $env:COMPUTERNAME, '-category', $category, '-tag', $snapTag, $folder)) `
                -SkipTag $snapTag
        }

        # plakar has no retention of its own, so a technician USB fills up over time.
        # Without -apply prune only reports, which is why the plan is shown first and the
        # page has to tick apply to delete anything. Prune does not reclaim space: the
        # space goes to maintenance after the grace period.
        'plakar_prune' {
            $days = 30
            $cap = 1
            try { $days = [int]$Job.Payload.days } catch { $days = 30 }
            try { $cap = [int]$Job.Payload.perDay } catch { $cap = 1 }
            if ($days -lt 1) { $days = 30 }
            if ($cap -lt 1) { $cap = 1 }

            $argv = $ka + @('at', $Ctx.Repo, 'prune', '-days', "$days", '-per-day', "$cap", '-group-by', 'name')
            $category = [string]$Job.Payload.category
            if (-not [string]::IsNullOrWhiteSpace($category)) { $argv += @('-category', $category) }

            AddLine "Policy: keep the last $days days, max $cap snapshot(s) per day, grouped by name."

            $code = RunTool $Ctx.PlakarExe $argv
            if ($code -ne 0) { AddLine (LockHint 'prune'); break }

            if ($Job.Payload.apply) {
                AddLine 'Applying the policy...'
                $code = RunTool $Ctx.PlakarExe ($argv + @('-apply'))
                if ($code -ne 0) { AddLine (LockHint 'prune') }
                else { AddLine 'Policy applied. The space is reclaimed by maintenance after the grace period, not by prune itself.' }
            } else {
                AddLine 'Plan only. Tick apply to delete the snapshots listed above.'
            }
        }

        # Searches every snapshot, not just the last one. Useful when you no longer know
        # which backup a file came from, and the only way to find the one huge file that
        # made a profile backup slow, because plakar has no size cap.
        'plakar_locate' {
            $pattern = [string]$Job.Payload.pattern
            if ([string]::IsNullOrWhiteSpace($pattern)) { AddLine 'ERROR: pattern cannot be empty.'; $code = 1; break }
            $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'locate', $pattern))
            $hits = 0
            foreach ($l in $Job.Lines) { if ($l -match '^[0-9a-f]{8}:/') { $hits++ } }
            AddLine "$hits match(es). To read one: plakar at <repo> cat <snapshotID>:<path>"
        }

        'plakar_restore' {
            $tag = $Job.Payload.tag; $to = $Job.Payload.to
            if ([string]::IsNullOrWhiteSpace($tag)) { AddLine 'ERROR: snapshot tag cannot be empty.'; $code = 1; break }
            if ([string]::IsNullOrWhiteSpace($to)) { AddLine 'ERROR: restore path cannot be empty.'; $code = 1; break }
            if (-not (Test-Path -LiteralPath $to)) {
                AddLine "Creating restore folder: $to"
                try { New-Item -ItemType Directory -Path $to -ErrorAction Stop | Out-Null }
                catch { AddLine "ERROR: failed to create restore folder: $($_.Exception.Message)"; $code = 1; break }
            }
            AddLine "Restoring snapshot $tag to $to ..."
            $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'restore', '-tag', $tag, '-to', $to))
        }

        'plakar_delete' {
            $tag = $Job.Payload.tag
            if ([string]::IsNullOrWhiteSpace($tag)) { AddLine 'ERROR: tag cannot be empty.'; $code = 1; break }
            AddLine "Deleting snapshot $tag ..."
            $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'rm', '-tag', $tag, '-apply'))
            if ($code -eq 0 -and $Job.Payload.maintenance) {
                AddLine 'Running maintenance to reclaim space...'
                $saved = $env:PLAKAR_GRACEPERIOD
                try {
                    if ($Ctx.GracePeriod) { $env:PLAKAR_GRACEPERIOD = $Ctx.GracePeriod }
                    $code = RunTool $Ctx.PlakarExe ($ka + @('at', $Ctx.Repo, 'maintenance'))
                } finally {
                    if ($Ctx.GracePeriod) { $env:PLAKAR_GRACEPERIOD = $saved }
                }
                $coloured = 0; $orphaned = 0; $rmBlobs = 0; $rmPacks = 0
                foreach ($l in $Job.Lines) {
                    if ($l -match 'Coloured (\d+) packfiles \((\d+) orphaned\)') { $coloured = [int]$Matches[1]; $orphaned = [int]$Matches[2] }
                    if ($l -match '(\d+) blobs and (\d+) packfiles were removed') { $rmBlobs = [int]$Matches[1]; $rmPacks = [int]$Matches[2] }
                }
                if ($code -ne 0) { AddLine (LockHint 'maintenance') }
                Update-Health 'maintenance' @{
                    at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); exitCode = $code
                    coloured = $coloured; orphaned = $orphaned
                    removedBlobs = $rmBlobs; removedPackfiles = $rmPacks
                }
            }
        }

        'plakar_ui' {
            $uiArgs = @()
            if ($ka.Count -gt 0) { $uiArgs += $ka }
            $uiArgs += @('at', $Ctx.Repo, 'ui')
            try {
                $p = Start-Process -FilePath $Ctx.PlakarExe -ArgumentList $uiArgs `
                    -RedirectStandardOutput $Job.LogFile -RedirectStandardError (Join-Path $Ctx.LogFolder ($Job.Id + '_plakar_ui.err')) -PassThru
                AddLine "Plakar UI process started (PID $($p.Id)); it keeps running after this job ends."
                Start-Sleep -Seconds 8
                $txt = Get-Content -LiteralPath $Job.LogFile -Raw -ErrorAction SilentlyContinue
                if ($txt -match 'http://[^\s]+') { AddLine "Plakar UI is at $($Matches[0])" }
                $code = 0
            } catch {
                AddLine "ERROR: could not start Plakar UI: $($_.Exception.Message)"
                $code = 1
            }
        }

        'usmt_scan' {
            if (-not (Test-Path -LiteralPath $Ctx.ScanState)) { AddLine "ERROR: scanstate.exe not found in $Ctx.USMTPath"; $code = 1; break }
            $users = @($Job.Payload.users)
            if ($users.Count -eq 0) { AddLine 'ERROR: no users selected.'; $code = 1; break }
            $opts = Resolve-USMTOptions $Job.Payload
            if ($opts.NoCompress -and $opts.KeyFile) { AddLine 'ERROR: /encrypt cannot be combined with /nocompress (USMT code 11).'; $code = 11; break }
            if (-not (Acquire-USMTGate 120000)) { AddLine 'ERROR: another migration tool is running (USMT code 29). Only one USMT tool can run at a time.'; $code = 29; break }
            try {
                $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
                $names = $users | ForEach-Object { ConvertTo-SafeName -Text (($_ -split '\\')[-1]) }
                $list = ($names | Select-Object -First 2) -join '_'
                if ($names.Count -gt 2) { $list += '_etc' }
                $storeName = "USMT_Store_${list}_$ts"
                $store = Join-Path $Ctx.USMTPath $storeName
                $Job.Store = $storeName
                # /l must be outside StorePath (USMT code 13).
                $logPath = Join-Path $Ctx.LogFolder ($Job.Id + '_scanstate.log')
                $progressPath = Join-Path $Ctx.LogFolder ($Job.Id + '_progress.txt')
                $Job.ProgressFile = $progressPath
                Test-USMTStoreLocation -StorePath $store | Out-Null
                if (-not (Test-Path -LiteralPath $store)) { New-Item -ItemType Directory -Path $store | Out-Null }
                $work = Ensure-USMTWorkDir -JobName $storeName
                $usbXml = ''
                if ($opts.ExcludeUsb) { $usbXml = Write-UsbExclusionXml -WorkDir $work -DriveRoot $Ctx.ScriptDrive }
                $xmls = @($Ctx.XmlSet)
                if ($usbXml) { $xmls += $usbXml }

                $argv = Build-ScanArgs -Store $store -Xmls $xmls -Users $users -Opts $opts -LogPath $logPath -ProgressPath $progressPath
                AddLine "Store: $store"
                AddLine "Users: $($users -join ', ')"
                AddLine "Options: efs=$($opts.EfsMode) localonly=$($opts.LocalOnly) nocompress=$($opts.NoCompress) encrypt=$([bool]$opts.KeyFile)"
                if ($usbXml) { AddLine "USB drive excluded from the scan: $Ctx.ScriptDrive (rule: $usbXml)" }
                AddLine "USMT log: $logPath"
                AddLine "Progress log: $progressPath (streamed into this job while the tool runs)"
                AddLine "Command: scanstate.exe $($argv -join ' ')"
                $tails = @($logPath, $progressPath)
                $code = RunTool $Ctx.ScanState $argv $tails

                $manifest = @{
                    tool         = 'scanstate'
                    storeName    = $storeName
                    created      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    users        = $users
                    xmls         = $xmls
                    source       = 'C:\Users'
                    efsMode      = $opts.EfsMode
                    localOnly    = [bool]$opts.LocalOnly
                    usbExclusion = if ($usbXml) { Split-Path -Qualifier $usbXml } else { '' }
                    noCompress   = [bool]$opts.NoCompress
                    encrypted    = [bool]$opts.KeyFile
                    keyFile      = $opts.KeyFile
                    exitCode     = $code
                }
                Write-USMTManifest -StorePath $store -Info $manifest
            } finally { try { $Ctx.USMTGate.ReleaseMutex() } catch { } }
        }

        'usmt_offline' {
            if (-not (Test-Path -LiteralPath $Ctx.ScanState)) { AddLine "ERROR: scanstate.exe not found in $Ctx.USMTPath"; $code = 1; break }
            $winDir = $Job.Payload.winDir
            if ([string]::IsNullOrWhiteSpace($winDir)) { AddLine 'ERROR: Windows folder cannot be empty.'; $code = 1; break }
            $opts = Resolve-USMTOptions $Job.Payload
            if ($opts.NoCompress -and $opts.KeyFile) { AddLine 'ERROR: /encrypt cannot be combined with /nocompress (USMT code 11).'; $code = 11; break }
            try {
                $cur = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')
                $in  = [System.IO.Path]::GetFullPath($winDir).TrimEnd('\')
                if ($in -ieq $cur) { AddLine "ERROR: $winDir is the currently booted Windows folder. Offline ScanState must target a Windows installation that is not booted."; $code = 1; break }
            } catch { }
            $cfg = Join-Path $winDir 'System32\config'
            if (-not (Test-Path $cfg) -or -not (Test-Path (Join-Path $cfg 'SYSTEM')) -or -not (Test-Path (Join-Path $cfg 'SOFTWARE'))) {
                AddLine "ERROR: invalid offline Windows directory: $winDir (expected <WindowsDir>\System32\config\SYSTEM)"; $code = 1; break
            }
            if (-not (Acquire-USMTGate 120000)) { AddLine 'ERROR: another migration tool is running (USMT code 29). Only one USMT tool can run at a time.'; $code = 29; break }
            try {
                $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
                $storeName = "USMT_Offline_Store_$ts"
                $store = Join-Path $Ctx.USMTPath $storeName
                $Job.Store = $storeName
                $logPath = Join-Path $Ctx.LogFolder ($Job.Id + '_scanstate.log')
                $progressPath = Join-Path $Ctx.LogFolder ($Job.Id + '_progress.txt')
                $Job.ProgressFile = $progressPath
                Test-USMTStoreLocation -StorePath $store | Out-Null
                if (-not (Test-Path -LiteralPath $store)) { New-Item -ItemType Directory -Path $store | Out-Null }
                $work = Ensure-USMTWorkDir -JobName $storeName

                # Offline.xml maps the source OS's drive letters onto the mounted
                # volume. It stays outside the store so it is not gathered or backed
                # up as migration data.
                $root = Split-Path -Qualifier $winDir
                if ($root -and -not $root.EndsWith('\')) { $root += '\' }
                $xmlPath = Join-Path $work 'Offline.xml'
                $xml = "<offline>`n  <winDir>`n    <path>$winDir</path>`n  </winDir>`n  <mappings>`n    <path>C:\, $root</path>`n  </mappings>`n</offline>"
                [System.IO.File]::WriteAllText($xmlPath, $xml, $utf8)

                $usbXml = ''
                if ($opts.ExcludeUsb) {
                    $toolRoot = $Ctx.ScriptDrive
                    if ($toolRoot -and -not $toolRoot.EndsWith('\')) { $toolRoot += '\' }
                    if ($toolRoot -and $root -and ($toolRoot -ieq $root)) {
                        AddLine 'WARNING: the offline Windows folder is on the same drive this tool runs from, so the USB exclusion rule is skipped for this run.'
                    } else {
                        $usbXml = Write-UsbExclusionXml -WorkDir $work -DriveRoot $Ctx.ScriptDrive
                    }
                }
                $xmls = @($Ctx.XmlSet)
                if ($usbXml) { $xmls += $usbXml }

                $argv = Build-ScanArgs -Store $store -Xmls $xmls -Users @() -Opts $opts -LogPath $logPath -ProgressPath $progressPath -OfflineXml $xmlPath
                AddLine "Store: $store"
                AddLine "Offline Windows: $winDir"
                AddLine "Mapping: C:\ -> $root"
                AddLine "Options: efs=$($opts.EfsMode) localonly=$($opts.LocalOnly) nocompress=$($opts.NoCompress) encrypt=$([bool]$opts.KeyFile)"
                if ($usbXml) { AddLine "USB drive excluded from the scan: $Ctx.ScriptDrive (rule: $usbXml)" }
                AddLine "USMT log: $logPath"
                AddLine "Progress log: $progressPath (streamed into this job while the tool runs)"
                AddLine "Command: scanstate.exe $($argv -join ' ')"
                $tails = @($logPath, $progressPath)
                $code = RunTool $Ctx.ScanState $argv $tails

                $manifest = @{
                    tool       = 'scanstate'
                    storeName  = $storeName
                    created    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    users      = @()
                    xmls       = @($Ctx.XmlSet)
                    source     = $winDir
                    efsMode    = $opts.EfsMode
                    localOnly  = [bool]$opts.LocalOnly
                    noCompress = [bool]$opts.NoCompress
                    encrypted  = [bool]$opts.KeyFile
                    keyFile    = $opts.KeyFile
                    offlineXml = $xmlPath
                    usbExclusion = if ($usbXml) { Split-Path -Qualifier $usbXml } else { '' }
                    exitCode   = $code
                }
                Write-USMTManifest -StorePath $store -Info $manifest
            } finally { try { $Ctx.USMTGate.ReleaseMutex() } catch { } }
        }

        'usmt_restore' {
            if (-not (Test-Path -LiteralPath $Ctx.LoadState)) { AddLine "ERROR: loadstate.exe not found in $Ctx.USMTPath"; $code = 1; break }
            $store = $Job.Payload.store
            $pass = $Job.Payload.password
            if ([string]::IsNullOrWhiteSpace($store) -or -not (Test-Path -LiteralPath $store)) { AddLine "ERROR: store not found: $store"; $code = 1; break }
            if ([string]::IsNullOrWhiteSpace($pass)) { AddLine 'ERROR: password cannot be blank.'; $code = 1; break }
            $files = @(Get-ChildItem -LiteralPath $store -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) { AddLine 'ERROR: store appears empty or corrupted.'; $code = 1; break }
            if (-not (Acquire-USMTGate 120000)) { AddLine 'ERROR: another migration tool is running (USMT code 29). Only one USMT tool can run at a time.'; $code = 29; break }
            try {
                # LoadState has to match how the store was created; the manifest
                # keeps those decisions from the scan run.
                $manifest = Read-USMTManifest -StorePath $store
                $xmls = $Ctx.XmlSet
                if ($manifest -and $manifest.xmls) {
                    $recorded = @($manifest.xmls | Where-Object { Test-Path -LiteralPath $_ })
                    if ($recorded.Count -gt 0) { $xmls = $recorded }
                }

                $argv = @($store)
                foreach ($x in $xmls) { $argv += "/i:$x" }

                if ($manifest -and $manifest.noCompress) {
                    $argv += '/nocompress'
                    AddLine 'Store was created with /nocompress (manifest): LoadState uses the same option.'
                }

                $keyFile = if ($manifest) { [string]$manifest.keyFile } else { '' }
                if ($manifest -and $manifest.encrypted) {
                    if ($keyFile -and (Test-Path -LiteralPath $keyFile)) {
                        $argv += @('/decrypt', "/keyfile:$keyFile")
                        AddLine "Store is encrypted (manifest): LoadState uses the recorded keyfile."
                    } else {
                        AddLine 'WARNING: the store is encrypted but the recorded keyfile is not available (USMT code 37).'
                    }
                }

                $map = [string]$Job.Payload.userMap
                if (-not [string]::IsNullOrWhiteSpace($map)) {
                    if ($map -notmatch '^[^\s:_]+_[^\s:_]+:[^\s:_]+_[^\s:_]+$') {
                        AddLine 'ERROR: user mapping must look like OldDomain_OldUser:NewDomain_NewUser.'
                        $code = 11
                        break
                    }
                    $argv += "/mu:$map"
                    AddLine "User mapping: $map (the target account must already exist here)"
                }

                $argv += @('/c', '/v:5')
                $logPath = Join-Path $Ctx.LogFolder ($Job.Id + '_loadstate.log')
                $progressPath = Join-Path $Ctx.LogFolder ($Job.Id + '_progress.txt')
                $Job.ProgressFile = $progressPath
                $argv += "/l:$logPath"
                $argv += "/progress:$progressPath"
                $argv += "/lac:$pass"
                $argv += '/lae'
                Ensure-USMTWorkDir -JobName 'loadstate' | Out-Null
                $Job.Store = (Split-Path -Leaf $store)

                AddLine "LoadState into THIS machine from $store ..."
                AddLine 'Remember: a reboot is usually needed to finish the restore.'
                AddLine "USMT log: $logPath"
                AddLine "Progress log: $progressPath (streamed into this job while the tool runs)"
                AddLine 'Command: loadstate.exe ' + (($argv | ForEach-Object { if ($_ -match '/lac:') { '/lac:<hidden>' } else { $_ } }) -join ' ')
                $tails = @($logPath, $progressPath)
                $code = RunTool $Ctx.LoadState $argv $tails
            } finally { try { $Ctx.USMTGate.ReleaseMutex() } catch { } }
        }

        'usmt_check' {
            if (-not (Test-Path -LiteralPath $Ctx.UsmtUtils)) { AddLine "ERROR: usmtutils.exe not found in $Ctx.USMTPath"; $code = 1; break }
            $store = $Job.Payload.store
            if ([string]::IsNullOrWhiteSpace($store) -or -not (Test-Path -LiteralPath $store)) { AddLine "ERROR: store not found: $store"; $code = 1; break }
            $manifest = Read-USMTManifest -StorePath $store
            if ($manifest -and $manifest.noCompress) {
                AddLine 'This store was created with /nocompress; usmtutils /verify only reports on compressed stores.'
                $code = 1
                break
            }
            if (-not (Acquire-USMTGate 120000)) { AddLine 'ERROR: another migration tool is running (USMT code 29). Only one USMT tool can run at a time.'; $code = 29; break }
            try {
                $logPath = Join-Path $Ctx.LogFolder ($Job.Id + '_usmtutils.log')
                $Job.ProgressFile = $logPath
                $argv = @('/verify:summary', $store, '/v:4', "/l:$logPath")
                $keyFile = if ($manifest) { [string]$manifest.keyFile } else { '' }
                if ($keyFile -and (Test-Path -LiteralPath $keyFile)) { $argv += @('/decrypt', "/keyfile:$keyFile") }
                AddLine "Verifying $store ..."
                AddLine "USMT log: $logPath (streamed into this job while the tool runs)"
                $tails = @($logPath)
                $code = RunTool $Ctx.UsmtUtils $argv $tails
                AddLine "Return code $code : $(Get-USMTCodeText $code)"
            } finally { try { $Ctx.USMTGate.ReleaseMutex() } catch { } }
        }

        'store_details' {
            $store = $Job.Payload.store
            if (-not (Test-Path -LiteralPath $store)) { AddLine "ERROR: USMT store not found at $store"; $code = 1; break }
            $files = @(Get-ChildItem -LiteralPath $store -Recurse -File -Force -ErrorAction SilentlyContinue)
            $mb = [math]::Round(((($files | Measure-Object -Property Length -Sum).Sum) / 1MB), 2)
            AddLine "Location: $store"
            AddLine "Size: $mb MB ($($files.Count) files)"
            AddLine "Created: $((Get-Item -LiteralPath $store).CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))"

            $manifest = Read-USMTManifest -StorePath $store
            if ($manifest) {
                AddLine 'Recorded at scan time:'
                AddLine "  - tool:     $($manifest.tool)"
                AddLine "  - created:  $($manifest.created)"
                AddLine "  - source:   $($manifest.source)"
                AddLine "  - users:    $(if ($manifest.users) { $manifest.users -join ', ' } else { 'all (/all)' })"
                AddLine "  - compression: $(if ($manifest.noCompress) { 'off (/nocompress)' } else { 'on' })"
                AddLine "  - encryption:    $(if ($manifest.encrypted) { 'yes' } else { 'no' })"
                if ($manifest.keyFile) { AddLine "  - keyfile:  $($manifest.keyFile)" }
                AddLine "  - EFS mode: $($manifest.efsMode)"
                if ($manifest.usbExclusion) { AddLine "  - USB drive excluded from the scan: $($manifest.usbExclusion)" }
                AddLine "  - exit code: $($manifest.exitCode) ($(Get-USMTCodeText ([int]$manifest.exitCode)))"
            } else {
                AddLine 'No store_manifest.json in this store (it was created by an older run).'
            }

            AddLine 'Contents:'
            foreach ($f in ($files | Select-Object -First 20)) {
                AddLine ("  - " + $f.Name + " (" + [math]::Round($f.Length / 1MB, 2) + " MB)")
            }
            if ($files.Count -gt 20) { AddLine "  ... and $($files.Count - 20) more files" }

            $userDirs = @(Get-ChildItem -LiteralPath $store -Directory -Force -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -ne 'USMT' -and $_.Name -ne '_work' })
            if ($userDirs.Count -gt 0) {
                AddLine 'Backed up users/data:'
                foreach ($d in $userDirs) {
                    $sub = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
                    AddLine ("  - " + $d.Name + " (" + [math]::Round(((($sub | Measure-Object -Property Length -Sum).Sum) / 1MB), 2) + " MB)")
                }
            }
            $code = 0
        }
        'open_private_url' {
            $url = $Job.Payload.url
            if ([string]::IsNullOrWhiteSpace($url)) { AddLine 'ERROR: url cannot be empty.'; $code = 1; break }
            # Only http(s). The page is the only caller, but this keeps a file:,
            # script: or unc path from reaching Start-Process.
            if ($url -notmatch '^https?://') { AddLine "ERROR: not an http(s) URL: $url"; $code = 1; break }

            # When the host is elevated the browser it starts is elevated too, and Edge
            # shows a warning banner for that. Cosmetic, but worth knowing.
            $exe = Resolve-Browser 'msedge.exe' 'Microsoft\Edge\Application'
            $flag = '-inprivate'
            $label = 'Microsoft Edge (InPrivate)'
            if (-not $exe) {
                $exe = Resolve-Browser 'chrome.exe' 'Google\Chrome\Application'
                $flag = '--incognito'
                $label = 'Google Chrome (Incognito)'
            }

            if ($exe) {
                AddLine "Opening $url in $label"
                try { Start-Process -FilePath $exe -ArgumentList @($flag, $url); $code = 0 }
                catch { AddLine "ERROR: could not start $exe : $($_.Exception.Message)"; $code = 1 }
            } else {
                AddLine 'Edge/Chrome not found; opening the default browser (not guaranteed private).'
                try { Start-Process $url; $code = 0 }
                catch { AddLine "ERROR: could not open the URL: $($_.Exception.Message)"; $code = 1 }
            }
        }

        # The tooling check and the drive sync live in sync_tools.ps1, so that script
        # stays the only place that decides what a tooling copy is. The page sends the
        # flags, this host runs the script and reads its JSON back.
        'tool_update_check' {
            if (-not (Test-Path -LiteralPath $Ctx.SyncScript)) { AddLine "ERROR: sync_tools.ps1 not found in $Ctx.ScriptDir"; $code = 1; break }
            $argv = @('-NoProfile', '-NonInteractive', '-File', $Ctx.SyncScript, '-Json', '-CheckUpdate', '-DryRun')
            $drives = @($Job.Payload.drives | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
            if ($drives.Count -gt 0) { $argv += @('-Drives') + $drives }
            AddLine 'Command: powershell.exe ' + ($argv -join ' ')
            $code = RunTool $Ctx.ShellExe $argv
            # RunTool streamed the raw JSON into this job; keep the log intact and show a compact summary here.
            $raw = (@($Job.Lines) -join "`n")
            $start = $raw.IndexOf('{')
            if ($start -lt 0) { AddLine 'ERROR: no JSON in the output from sync_tools.ps1'; $code = 1; break }
            $parsed = $null
            try { $parsed = $raw.Substring($start) | ConvertFrom-Json } catch { $parsed = $null }
            if (-not $parsed) { AddLine 'ERROR: could not read the JSON from sync_tools.ps1'; $code = 1; break }
            $Job.Lines = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $u = $parsed.update
            if ($u) {
                AddLine ('tool check: template tool ' + $u.local + ', latest on GitHub ' + $u.latest + ' -> ' + $u.status)
            } else {
                AddLine 'tool check: not asked (-CheckUpdate)'
            }
            foreach ($d in @($parsed.drives)) {
                $tv = if ($d.toolVersion) { $d.toolVersion } else { 'unknown' }
                $rv = if ($d.repoVersion) { $d.repoVersion } else { 'no repository' }
                if ($d.refused) { $state = 'REFUSED: ' + $d.refused }
                elseif ($d.upToDate) { $state = 'up to date' }
                else { $state = ([string]$d.diffCount) + ' file(s) differ' }
                $edits = @($d.localEdits)
                if ($edits.Count -gt 0) { $state += ' (drive edits: ' + ($edits -join ', ') + ')' }
                AddLine ('  ' + $d.drive + ' | tool ' + $tv + ' | repo ' + $rv + ' | ' + $state)
            }
            $Ctx.ToolInfo = $parsed
        }

        'tool_sync' {
            if (-not (Test-Path -LiteralPath $Ctx.SyncScript)) { AddLine "ERROR: sync_tools.ps1 not found in $Ctx.ScriptDir"; $code = 1; break }
            $argv = @('-NoProfile', '-NonInteractive', '-File', $Ctx.SyncScript)
            if ($Job.Payload.dryRun) { $argv += '-DryRun' }
            if ($Job.Payload.restore) { $argv += '-Restore' }
            if ($Job.Payload.binaries) { $argv += '-IncludeBinaries' }
            if ($Job.Payload.key) { $argv += '-IncludeKey' }
            if ($Job.Payload.force) { $argv += '-Force' }
            if ($Job.Payload.check) { $argv += '-CheckUpdate' }
            $drives = @($Job.Payload.drives | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
            if ($drives.Count -gt 0) { $argv += @('-Drives') + $drives }
            AddLine 'Command: powershell.exe ' + ($argv -join ' ')
            $code = RunTool $Ctx.ShellExe $argv
        }

        default {
            AddLine "ERROR: unknown action '$($Job.Action)'"
            $code = 1
        }
    }

    if ($code -eq 3) { AddLine 'NOTE: code 3 means at least one error was skipped by /c - the result is usable but incomplete.' }
    AddLine "EXITCODE: $code"
    $Job.ExitCode = $code
    $Job.Status = if ($code -eq 0) { 'completed' } elseif ($code -eq 3) { 'partial' } else { 'failed' }
    Rotate-Logs -Dir $Ctx.LogFolder
}

function New-Job {
    param([string]$action, [hashtable]$payload, [string]$label)
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $logFile = Join-Path $Ctx.LogFolder ($id + '_' + $action + '.log')
    $job = @{
        Id = $id; Label = $label; Action = $action; Status = 'running'
        Started = Get-Date; ExitCode = $null; LogFile = $logFile; Store = $null
        ProgressFile = $null
        Lines = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        Payload = $payload
    }
    try { [System.IO.File]::WriteAllText($logFile, '', $Utf8NoBom) } catch { }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    $ps.AddScript($JobBody).AddArgument($Ctx).AddArgument($job) | Out-Null
    $job.Handle = $ps.BeginInvoke()
    $job.PS = $ps
    $Ctx.Jobs[$id] = $job
    return $job
}

function Job-View {
    param($job, $now)
    $ps = $job.PS
    if ($ps -and $job.Handle -and $job.Handle.IsCompleted) {
        if ($job.Status -eq 'running') {
            $errs = $job.Handle.Errors
            if ($errs -and $errs.Count -gt 0) { $job.Status = 'failed' } else { $job.Status = 'gone' }
            $job.ExitCode = 1
        }
        try { $ps.Dispose() } catch { }
    }
    $elapsed = [int]($now - $job.Started).TotalSeconds
    $el = if ($elapsed -ge 60) { "$([math]::Floor($elapsed/60))m$($elapsed % 60)s" } else { "${elapsed}s" }
    $lines = @($job.Lines)
    @{
        id = $job.Id; label = $job.Label; status = $job.Status; exitCode = $job.ExitCode
        started = $job.Started.ToString('HH:mm:ss'); elapsed = $el; lineCount = $lines.Count
        store = $job.Store; logFile = $job.LogFile; progress = $job.ProgressFile
        output = (@($lines | Select-Object -Last 200))
        lastLine = if ($lines.Count -gt 0) { $lines[-1] } else { '' }
    }
}

# ---------------------------------------------------------------------------
# /api/info
# ---------------------------------------------------------------------------
$InfoCache = @{ at = $null; json = $null }

function Get-Info {
    $now = Get-Date
    if ($InfoCache.at -and ($now - $InfoCache.at).TotalSeconds -lt 5) { return $InfoCache.json }

    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $Utf8NoBom
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    try {
        # Empty stdin, same reason as RunTool: no keyfile means plakar prompts, and a
        # prompt here would hang this request and every request queued behind it.
        $info = '' | & $PlakarExe @KeyArgs -quiet at $Repo info 2>$null | Out-String
        $keyOk = ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
        [Console]::OutputEncoding = $prevEnc
    }

    $snapCount = 0; $sizeGB = 0; $logicalGB = 0
    if (Test-Path -LiteralPath $Repo) {
        $sizeGB = [math]::Round(((Get-ChildItem -LiteralPath $Repo -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB), 2)
    }
    if ($info -match 'Snapshots:\s+(\d+)') { $snapCount = [int]$Matches[1] }
    if ($info -match 'Logical size:.*\((\d+) bytes\)') { $logicalGB = [math]::Round(([long]$Matches[1] / 1GB), 2) }

    # plakar ls -tags: date  hash  size  duration  path  tags=...
    $raw = ''
    $snaps = @()
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $Utf8NoBom
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    try {
        $ls = '' | & $PlakarExe @KeyArgs -quiet at $Repo ls -tags 2>$null | Out-String
    } finally {
        $ErrorActionPreference = $prev
        [Console]::OutputEncoding = $prevEnc
    }
    foreach ($l in ($ls -split "`r?`n")) {
        if ($l.Trim() -eq '') { continue }
        $raw += $l + "`n"
        if ($l -match '^(\S+)\s+(\S+)\s+(.+?)\s+(\S+)\s+(\S+)\s+tags=(.*)$') {
            $tags = ($Matches[6] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            $snaps += @{ date = $Matches[1]; hash = $Matches[2]; size = $Matches[3]; path = $Matches[5]; tags = $tags }
        }
    }
    $tagsAll = @(); foreach ($s in $snaps) { foreach ($t in $s.tags) { $tagsAll += $t } }
    # Wrap in @() before serialising. An empty pipeline result is not an array, and
    # ConvertTo-Json writes it as {} instead of []; the page reads {} as one element
    # and the tag dropdown showed "[object Object]".
    $tagsAll = @($tagsAll | Select-Object -Unique)

    # health
    $lockDir = Join-Path $Repo 'locks'
    $lockFiles = @(Get-ChildItem -LiteralPath $lockDir -File -Force -ErrorAction SilentlyContinue)
    $pids = @(Get-Process -Name 'plakar' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $pfRoot = Join-Path $Repo 'packfiles'
    $pfFiles = @(Get-ChildItem -LiteralPath $pfRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    $pfMB = [math]::Round(((($pfFiles | Measure-Object -Property Length -Sum).Sum) / 1MB), 2)
    $tmpPacks = @($pfFiles | Where-Object { $_.Name -like 'tmp.*' })
    $health = $null
    if (Test-Path -LiteralPath $HealthFile) {
        try { $health = Get-Content -LiteralPath $HealthFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $health = $null }
    }
    $healthObj = @{
        lockFileCount = $lockFiles.Count
        lockStale = ($lockFiles.Count -gt 0 -and $pids.Count -eq 0)
        livePlakarPids = $pids
        packfileCount = $pfFiles.Count
        packfileMB = $pfMB
        leftoverTmpPackfiles = $tmpPacks.Count
        lastMaintenance = $health
        lastCheck = $null
    }
    if ($health) {
        $healthObj.lastMaintenance = $health.maintenance
        $healthObj.lastCheck = $health.check
    } else {
        $healthObj.lastMaintenance = $null
    }

    # USMT stores
    $stores = @()
    if (Test-Path -LiteralPath $USMTPath) {
        foreach ($d in (Get-ChildItem -LiteralPath $USMTPath -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like 'USMT_Store_*' -or $_.Name -like 'USMT_Offline_Store_*' } |
                        Sort-Object CreationTime -Descending)) {
            $f = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -notmatch '\\_work\\' })
            $m = Read-USMTManifest -StorePath $d.FullName
            $codeText = ''
            if ($m -and $null -ne $m.exitCode) { $codeText = Get-USMTCodeText ([int]$m.exitCode) }
            $stores += @{
                name = $d.Name; created = $d.CreationTime.ToString('yyyy-MM-dd HH:mm')
                sizeGB = [math]::Round(((($f | Measure-Object -Property Length -Sum).Sum) / 1GB), 2)
                fileCount = $f.Count; path = $d.FullName
                users = if ($m -and $m.users) { @($m.users) } else { @() }
                source = if ($m) { [string]$m.source } else { '' }
                tool = if ($m) { [string]$m.tool } else { '' }
                noCompress = [bool]($m -and $m.noCompress)
                encrypted = [bool]($m -and $m.encrypted)
                efsMode = if ($m) { [string]$m.efsMode } else { '' }
                exitCode = if ($m) { $m.exitCode } else { $null }
                codeText = $codeText
            }
        }
    }

    # users under C:\Users
    $sys = @('All Users','Default','Default User','Public','WDAGUtilityAccount','desktop.ini')
    $users = @()
    foreach ($d in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $sys -notcontains $_.Name })) {
        $users += @{ name = $d.Name; path = $d.FullName; full = "$env:COMPUTERNAME\$($d.Name)" }
    }

    $json = @{
        repo = $Repo
        usbDrive = $ScriptDrive
        usmtPath = $USMTPath
        scanstateFound = (Test-Path (Join-Path $USMTPath 'scanstate.exe'))
        keyStatus = $KeyStatus
        isAdmin = $IsAdmin
        junkPatterns = @($JunkPatterns)
        repoInfo = @{
            snapshotCount = $snapCount; sizeGB = $sizeGB; logicalGB = $logicalGB
            keyOk = $keyOk; raw = $raw.TrimEnd(); tags = @($tagsAll); snapshots = @($snaps)
        }
        health = $healthObj
        stores = @($stores)
        users = @($users)
        tooling = $Ctx.ToolInfo
        jobs = @($Ctx.Jobs.Values | ForEach-Object { Job-View $_ $now })
    }
    $InfoCache.at = $now
    $InfoCache.json = $json
    return $json
}

# ---------------------------------------------------------------------------
# Host process context (used by the job bodies and the HTTP loop)
# ---------------------------------------------------------------------------
$Ctx = @{
    ScriptDir = $ScriptDir; ScriptDrive = $ScriptDrive; Repo = $Repo; PlakarExe = $PlakarExe; KeyFile = $KeyFile
    KeyArgs = $KeyArgs; LogFolder = $LogFolder; HealthFile = $HealthFile
    USMTPath = $USMTPath; ScanState = (Join-Path $USMTPath 'scanstate.exe')
    LoadState = (Join-Path $USMTPath 'loadstate.exe'); UsmtUtils = (Join-Path $USMTPath 'usmtutils.exe')
    MigUserXML = (Resolve-USMTXmlFile 'miguser.xml'); MigAppXML = (Resolve-USMTXmlFile 'migapp.xml')
    MigDocsXML = (Resolve-USMTXmlFile 'migdocs.xml')
    GracePeriod = $GracePeriod; Jobs = $Jobs; WebRoot = $WebRoot; HealthLock = $HealthLock
    JunkPatterns = $JunkPatterns
    WorkFolder = $WorkFolder; USMTGate = $UsmtGate; CodeText = $UsmtCodeText
    OemEncoding = $OemEncoding; MaxLines = $MaxJobLines
    SyncScript = (Join-Path $ScriptDir 'sync_tools.ps1'); ToolInfo = $null
    ShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    MigModernXML = (Resolve-USMTXmlFile 'migmodern.xml')
    XmlSet = (@((Resolve-USMTXmlFile 'miguser.xml'), (Resolve-USMTXmlFile 'migapp.xml'),
                (Resolve-USMTXmlFile 'migdocs.xml'), (Resolve-USMTXmlFile 'migmodern.xml')) |
               Where-Object { Test-Path -LiteralPath $_ })
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
# localhost and 127.0.0.1 are different HTTP.sys prefixes. A request to the
# other name is rejected with 400 Invalid Hostname before this script sees it.
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

function Send-Json {
    param($ctx, $obj, [int]$status = 200)
    $json = ConvertTo-Json $obj -Depth 8
    $bytes = $Utf8NoBom.GetBytes($json)
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.ContentLength64 = $bytes.Length
    try { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) } catch { }
    try { $ctx.Response.Close() } catch { }
}

function Send-File {
    param($ctx, [string]$path)
    if (-not (Test-Path -LiteralPath $path)) {
        $ctx.Response.StatusCode = 404
        $bytes = $Utf8NoBom.GetBytes('not found')
        $ctx.Response.ContentType = 'text/plain; charset=utf-8'
        $ctx.Response.ContentLength64 = $bytes.Length
        try { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) } catch { }
        try { $ctx.Response.Close() } catch { }
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = 'text/html; charset=utf-8'
    $ctx.Response.ContentLength64 = $bytes.Length
    try { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) } catch { }
    try { $ctx.Response.Close() } catch { }
}

# Is the page already being served by another instance of this host? Double-clicking
# webui.bat twice is the usual way binding fails: the first instance still holds the
# prefix, so Start() throws a conflict rather than a permissions error. Confirm it is
# really this host (not some other program on the port) by asking for /api/info and
# checking the shape of the answer.
function Test-ExistingHost {
    param([int]$Port)
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Port/api/info" -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -ne 200) { return $false }
        return ($resp.Content -match '"repo"')
    } catch { return $false }
}

function Open-Page {
    param([int]$Port)
    if ($NoBrowser) { return }
    # Same path as the Shortcuts buttons, so browser resolution lives in one place and
    # the open also shows up in the Activity panel.
    New-Job 'open_private_url' @{ url = "http://localhost:$Port/" } 'open page' | Out-Null
}

try {
    $listener.Start()
} catch {
    if (Test-ExistingHost $Port) {
        Write-Host "Another instance of this host is already serving http://localhost:$Port/." -ForegroundColor Yellow
        Write-Host 'Opening the page and exiting; close that window to stop the host.' -ForegroundColor Gray
        Open-Page $Port
        try { $listener.Close() } catch { }
        exit 0
    }

    # 127.0.0.1 can be refused when that prefix has no URL reservation. localhost
    # alone is reserved for everyone, so it is enough for the browser window.
    try { $listener.Close() } catch { }
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    try {
        $listener.Start()
    } catch {
        Write-Host "Could not bind http://localhost:$Port/ - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Nothing is serving that port, so this is not a second instance of this host.' -ForegroundColor Yellow
        Write-Host 'Free the port, or run webui.bat from an elevated PowerShell.' -ForegroundColor Yellow
        # When webui.bat is double-clicked the window closes as soon as the script
        # exits, so the technician never sees this. Hold the window open.
        if (-not [Console]::IsInputRedirected) { $null = Read-Host 'Press Enter to close' }
        exit 1
    }
}

Write-Host "Plakar + USMT technician page: http://localhost:$Port/" -ForegroundColor Green
Write-Host "Repository: $Repo" -ForegroundColor Gray
Write-Host "USMT: $USMTPath" -ForegroundColor Gray
Write-Host "Keyfile: $KeyFile ($KeyStatus)" -ForegroundColor Gray
Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray

Open-Page $Port

while ($listener.IsListening) {
    # Named $request on purpose. PowerShell variables are case-insensitive, so
    # $ctx = ... would overwrite the $Ctx hashtable and every later route would
    # see an HttpListenerContext instead of the host context.
    try {
        $request = $listener.GetContext()
    } catch { break }

    $path = $request.Request.Url.AbsolutePath
    $verb = $request.Request.HttpMethod

    try {
        if ($verb -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            Send-File $request (Join-Path $Ctx.WebRoot 'index.html')
            continue
        }

        if ($path -eq '/api/info') { Send-Json $request (Get-Info); continue }

        if ($path -eq '/api/jobs') {
            $now = Get-Date
            Send-Json $request @($Ctx.Jobs.Values | ForEach-Object { Job-View $_ $now })
            continue
        }

        if ($verb -eq 'POST' -and $path -eq '/api/key') {
            $reader = New-Object System.IO.StreamReader($request.Request.InputStream, $request.Request.ContentEncoding)
            $body = $reader.ReadToEnd(); $reader.Close()
            $obj = $body | ConvertFrom-Json
            $pass = [string]$obj.passphrase
            if ([string]::IsNullOrEmpty($pass)) {
                if (Test-Path -LiteralPath $KeyFile) { Remove-Item -LiteralPath $KeyFile -Force -ErrorAction SilentlyContinue }
                $script:KeyArgs = @()
                $script:KeyStatus = 'no passphrase (unencrypted)'
                Send-Json $request @{ message = 'No passphrase set; .plakar_key removed and the repository is treated as unencrypted.' }
            } else {
                [System.IO.File]::WriteAllText($KeyFile, $pass, $Utf8NoBom)
                $script:KeyArgs = @('-keyfile', $KeyFile)
                if (Test-PlakarRepoUnlock $KeyArgs) {
                    $script:KeyStatus = 'ok'
                    Send-Json $request @{ message = 'Passphrase saved to .plakar_key and it unlocks this repository.' }
                } else {
                    $script:KeyStatus = Resolve-PlakarKeyFile
                    Send-Json $request @{ message = "Saved, but the passphrase did not unlock this repository ($script:KeyStatus)." }
                }
            }
            continue
        }

        if ($verb -eq 'POST' -and $path -eq '/api/run') {
            $reader = New-Object System.IO.StreamReader($request.Request.InputStream, $request.Request.ContentEncoding)
            $body = $reader.ReadToEnd(); $reader.Close()
            $obj = $body | ConvertFrom-Json
            $action = [string]$obj.action
            $payload = @{}
            foreach ($p in $obj.PSObject.Properties) {
                if ($p.Name -eq 'action') { continue }
                $v = $p.Value
                if ($v -is [System.Object[]]) { $v = @($v | ForEach-Object { [string]$_ }) }
                $payload[$p.Name] = $v
            }
            $label = $action
            if ($payload.tag) { $label = "$action ($($payload.tag))" }
            if ($payload.store) { $label = "$action ($($payload.store))" }
            $job = New-Job $action $payload $label
            Send-Json $request (Job-View $job (Get-Date))
            continue
        }

        Send-Json $request @{ error = 'unknown route' } 404
    } catch {
        try { Send-Json $request @{ error = $_.Exception.Message } 500 } catch { }
    }
}

try { $listener.Close() } catch { }
try { $Pool.Dispose() } catch { }
