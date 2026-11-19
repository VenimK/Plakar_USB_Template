# =============================================================
# Self-Elevating PowerShell Wrapper (Safe)
# =============================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Elevating privileges..."
    $PSexe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $PSexe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ------------------------------
# Helper Functions
# ------------------------------
# Pause is built into Windows PowerShell 5.1 but not into PowerShell 7.
if (-not (Get-Command -Name 'Pause' -ErrorAction SilentlyContinue)) {
    function Pause { $null = Read-Host 'Press Enter to continue...' }
}

function Write-ColorMessage {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    switch ($Type) {
        "Success" { Write-Host $Message -ForegroundColor Green }
        "Error"   { Write-Host $Message -ForegroundColor Red }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Info"    { Write-Host $Message -ForegroundColor Cyan }
        default   { Write-Host $Message }
    }
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Concat-Bytes {
    param([byte[]]$Left, [byte[]]$Right)
    if (-not $Left -or $Left.Length -eq 0) { return [byte[]]$Right }
    if (-not $Right -or $Right.Length -eq 0) { return [byte[]]$Left }
    $out = New-Object byte[] ($Left.Length + $Right.Length)
    [Array]::Copy($Left, 0, $out, 0, $Left.Length)
    [Array]::Copy($Right, 0, $out, $Left.Length, $Right.Length)
    return $out
}

function Get-TrailingTrimmedBytes {
    param([byte[]]$Data)
    if (-not $Data -or $Data.Length -eq 0) { return [byte[]]@() }
    $n = $Data.Length
    while ($n -gt 0 -and ($Data[$n - 1] -eq 9 -or $Data[$n - 1] -eq 10 -or $Data[$n - 1] -eq 13 -or $Data[$n - 1] -eq 32)) {
        $n--
    }
    if ($n -le 0) { return [byte[]]@() }
    if ($n -eq $Data.Length) { return [byte[]]$Data }
    $out = New-Object byte[] $n
    [Array]::Copy($Data, 0, $out, 0, $n)
    return $out
}

function Test-PlakarRepoUnlock {
    param([string[]]$KeyArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $PlakarExe @KeyArgs -quiet at $Repo ls 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Resolve-PlakarKeyFile {
    $script:PlakarKeyArgs = @()
    if (-not (Test-Path -LiteralPath $KeyFile)) { return }

    $script:PlakarKeyArgs = @("-keyfile", $KeyFile)
    if (Test-PlakarRepoUnlock $script:PlakarKeyArgs) { return }

    $bytes = [System.IO.File]::ReadAllBytes($KeyFile)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $body = $bytes
    if ($hasBom) {
        $body = New-Object byte[] ($bytes.Length - 3)
        [Array]::Copy($bytes, 3, $body, 0, $body.Length)
    }
    $body = Get-TrailingTrimmedBytes $body
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $lf = [byte[]](10)
    $crlf = [byte[]](13, 10)
    $candidates = @(
        $body,
        (Concat-Bytes $bom $body),
        (Concat-Bytes $body $lf),
        (Concat-Bytes $body $crlf),
        (Concat-Bytes (Concat-Bytes $bom $body) $lf),
        (Concat-Bytes (Concat-Bytes $bom $body) $crlf)
    )

    $tmp = Join-Path $env:TEMP ("plakar-key-" + [guid]::NewGuid().ToString('N'))
    try {
        foreach ($candidate in $candidates) {
            if (-not $candidate -or $candidate.Length -eq 0) { continue }
            [System.IO.File]::WriteAllBytes($tmp, [byte[]]$candidate)
            if (Test-PlakarRepoUnlock -KeyArgs @("-keyfile", $tmp)) {
                [System.IO.File]::WriteAllBytes($KeyFile, [byte[]]$candidate)
                $script:PlakarKeyArgs = @("-keyfile", $KeyFile)
                Write-ColorMessage "Updated .plakar_key encoding so it unlocks this repository." "Success"
                return
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    Write-ColorMessage "ERROR: .plakar_key did not unlock the repository." "Error"
    Write-ColorMessage "Enter the repository passphrase (or press Enter to skip):" "Warning"
    $entered = ConvertFrom-SecureStringPlain (Read-Host -AsSecureString)
    if ([string]::IsNullOrWhiteSpace($entered)) {
        $script:PlakarKeyArgs = @()
        return
    }

    $enteredBytes = [System.Text.Encoding]::UTF8.GetBytes($entered)
    foreach ($candidate in @($enteredBytes, (Concat-Bytes $bom $enteredBytes))) {
        [System.IO.File]::WriteAllBytes($tmp, [byte[]]$candidate)
        try {
            if (Test-PlakarRepoUnlock -KeyArgs @("-keyfile", $tmp)) {
                [System.IO.File]::WriteAllBytes($KeyFile, [byte[]]$candidate)
                $script:PlakarKeyArgs = @("-keyfile", $KeyFile)
                Write-ColorMessage "Passphrase saved to .plakar_key" "Success"
                return
            }
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-ColorMessage "ERROR: That passphrase did not unlock the repository." "Error"
    $script:PlakarKeyArgs = @()
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-DiskSpace {
    param([string]$Path, [long]$RequiredGB = 5)
    try {
        $Drive = (Get-Item $Path).PSDrive.Name
        $FreeSpace = (Get-PSDrive $Drive).Free / 1GB
        if ($FreeSpace -lt $RequiredGB) {
            Write-ColorMessage "WARNING: Low disk space on drive $Drive`: $([math]::Round($FreeSpace,2)) GB free" "Warning"
            return $false
        }
        return $true
    } catch {
        return $true  # Continue if check fails
    }
}

# plakar runs its Argon2id KDF on every invocation, so an `info` call costs about
# 1 second. ShowMenu runs on every loop iteration, which made the menu feel slow for
# no reason. The numbers only change when something writes to the repo, so the result
# is cached and invalidated by the actions that can change it.
$script:RepoInfoCache = $null

function Invalidate-RepoInfoCache {
    $script:RepoInfoCache = $null
}

function Get-RepositoryInfo {
    if ($script:RepoInfoCache) { return $script:RepoInfoCache }

    $snapshotCount = 0
    $repoSize = 0
    $logicalSize = 0
    try {
        if (Test-Path $Repo) {
            $repoSize = (Get-ChildItem $Repo -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB
        }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $info = & $PlakarExe @PlakarKeyArgs at "$Repo" info 2>$null | Out-String
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -eq 0) {
            if ($info -match 'Snapshots:\s+(\d+)') {
                $snapshotCount = [int]$Matches[1]
            }
            # Plakar reports the bytes still referenced by snapshots. Anything on disk
            # above that is orphaned and only reclaimed by maintenance.
            if ($info -match 'Logical size:.*\((\d+) bytes\)') {
                $logicalSize = [long]$Matches[1] / 1GB
            }
        }
    } catch {
        $snapshotCount = 0
    }
    $script:RepoInfoCache = @{
        SnapshotCount = $snapshotCount
        SizeGB = [math]::Round($repoSize, 2)
        LogicalGB = [math]::Round($logicalSize, 2)
    }
    return $script:RepoInfoCache
}

function Confirm-Action {
    param([string]$Message)
    $response = Read-Host "$Message (y/n)"
    return $response -match '^[Yy]'
}

# Asked per backup rather than applied automatically: a cache is only regenerable if
# the machine is still bootable, so a technician may want Temp for forensics. Default
# is yes because on a typical profile these patterns are about half the bytes and a
# third of the file count, which is roughly half the backup work.
function Ask-ExcludeJunk {
    Write-ColorMessage "Junk patterns ($($JunkPatterns.Count)): $($JunkPatterns -join ', ')" "Info"
    Write-Host "Bare names match at any depth, so a user folder named Cache or Explorer is skipped too." -ForegroundColor Gray
    $response = Read-Host "Exclude them from this backup? (Y/n)"
    if ($response -match '^[Nn]') { return $false }
    return $true
}

function Get-IgnoreArgs {
    param([bool]$Exclude)
    if (-not $Exclude) { return @() }
    $ignoreArgs = @()
    foreach ($pattern in $JunkPatterns) {
        $ignoreArgs += @('-ignore', $pattern)
    }
    return $ignoreArgs
}

# plakar prints one line per entry: OK for what it stored, KO for what it could not
# read. A file that is in use (an Outlook OST, a browser cache, the NTFS journal, the
# page file) is skipped and the snapshot still finishes with exit 0 and passes check,
# so a live profile backup quietly misses whatever was locked. Without a count the
# technician cannot tell which files were not captured, so this prints the lines as
# they arrive, counts them, and writes the skipped paths to a log.
#
# -name, -environment and -category are stored in the snapshot metadata. They are what
# make prune and locate filterable once the stick holds profiles from several machines;
# the tag alone is not enough, and plakar has no size cap, so a pattern list cannot
# limit one huge file either.
function Invoke-PlakarBackup {
    param(
        [string]$Folder,
        [string]$SnapTag,
        [string]$Name,
        [string]$Category,
        [string[]]$IgnoreArgs
    )

    # @Name can only be used as an argument to a command, so the array is built with
    # $script:PlakarKeyArgs and splatted at the call.
    $argv = $script:PlakarKeyArgs + @('at', $Repo, 'backup') + @($IgnoreArgs) +
            @('-name', $Name, '-environment', $env:COMPUTERNAME, '-category', $Category,
             '-tag', $SnapTag, $Folder)

    $stored = 0
    $skipped = @()
    $code = 0

    try {
        # 2>&1 merges plakar's stderr into the pipeline. Under the default preference a
        # native stderr line arrives as an ErrorRecord rather than terminating the run,
        # so the KO lines are counted here instead of aborting the backup.
        & $PlakarExe @argv 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $text = $_.Exception.Message
                Write-Host $text -ForegroundColor Red
                $skipped += $text
            } else {
                Write-Host $_
                $stored++
            }
        }
        $code = $LASTEXITCODE
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
        $code = 1
    }

    Invalidate-RepoInfoCache

    Write-Host ""
    if ($skipped.Count -gt 0) {
        Write-ColorMessage ("Stored {0} entries, skipped {1}." -f $stored, $skipped.Count) "Warning"
        $skipLog = Join-Path $LogsDir ("skipped_" + $SnapTag + ".txt")
        try {
            Set-Content -LiteralPath $skipLog -Value $skipped -Encoding UTF8
            Write-ColorMessage "Skipped paths written to: $skipLog" "Info"
        } catch {
            Write-ColorMessage "Could not write the skipped list: $($_.Exception.Message)" "Error"
        }
    } else {
        Write-ColorMessage ("Stored {0} entries, nothing skipped." -f $stored) "Success"
    }

    if ($code -ne 0) { Write-ColorMessage "Backup FAILED. Exit code: $code" "Error" }
    return $code
}

function Test-ValidPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-ColorMessage "ERROR: Path cannot be empty." "Error"
        return $false
    }
    if (!(Test-Path $Path)) {
        Write-ColorMessage "ERROR: Path not found: $Path" "Error"
        return $false
    }
    return $true
}

# ------------------------------
# USMT support helpers
# ------------------------------
# Return codes shared by scanstate.exe, loadstate.exe and usmtutils.exe.
# Source: https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes
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

# Code 3 means USMT skipped errors because of /c: the store is usable but
# incomplete, so it must not be reported as a plain failure or as a success.
function Get-USMTCodeKind {
    param([int]$Code)
    switch ($Code) {
        0 { 'success' }
        3 { 'partial' }
        default { 'failure' }
    }
}

function Summarize-USMTLog {
    param([string]$LogPath, [int]$MaxLines = 12)
    if ([string]::IsNullOrWhiteSpace($LogPath) -or !(Test-Path -LiteralPath $LogPath)) { return $null }
    $lines = Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue
    if (-not $lines) { return $null }
    $errorLines = @($lines | Where-Object { $_ -match '(?i)\berror\b' })
    $warnLines  = @($lines | Where-Object { $_ -match '(?i)\bwarning\b' })
    return @{
        Path       = $LogPath
        Lines      = $lines.Count
        Errors     = $errorLines.Count
        Warnings   = $warnLines.Count
        ErrorLines = $errorLines | Select-Object -First $MaxLines
    }
}

function Report-USMTResult {
    param(
        [int]$Code,
        [string]$LogPath,
        [string]$Operation,
        [double]$Minutes
    )
    $kind = Get-USMTCodeKind -Code $Code
    switch ($kind) {
        'success' { Write-ColorMessage "[SUCCESS] $Operation completed successfully." "Success" }
        'partial' { Write-ColorMessage "[PARTIAL] $Operation finished with skipped errors - the store may be incomplete." "Warning" }
        default   { Write-ColorMessage "[FAILED] $Operation failed." "Error" }
    }
    Write-ColorMessage "Return code $Code : $(Get-USMTCodeText $Code)" "Info"
    Write-ColorMessage "Time elapsed: $([math]::Round($Minutes, 1)) minutes" "Info"

    $summary = Summarize-USMTLog -LogPath $LogPath
    if ($summary) {
        Write-ColorMessage "Log: $($summary.Path)" "Info"
        Write-ColorMessage "Log lines: $($summary.Lines), errors: $($summary.Errors), warnings: $($summary.Warnings)" "Info"
        if ($summary.ErrorLines -and $summary.ErrorLines.Count -gt 0) {
            Write-ColorMessage "First error lines in the log:" "Warning"
            foreach ($line in $summary.ErrorLines) { Write-Host "  $line" -ForegroundColor Yellow }
        }
    } else {
        Write-ColorMessage "No log content found at: $LogPath" "Warning"
    }
    return $kind
}

function Get-FolderSizeGB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [math]::Round($sum / 1GB, 2)
    } catch {
        return 0
    }
}

function ConvertTo-SafeName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'user' }
    $clean = ($Text -replace '[^\w.\-]', '_')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'user' }
    return $clean
}

# USMT rejects a store on the system drive (code 27), warns about paths longer
# than 256 characters (code 12), and needs a volume that supports large files.
function Test-USMTStoreLocation {
    param([string]$StorePath)
    $ok = $true
    if ($StorePath.Length -gt 256) {
        Write-ColorMessage "WARNING: store path is $($StorePath.Length) characters (USMT code 12 limits it to 256)." "Warning"
        $ok = $false
    }
    try {
        $drive = Split-Path -Qualifier $StorePath
        if ($drive) {
            $letter = $drive.TrimEnd(':').TrimEnd('\')
            $systemLetter = ($env:SystemDrive -replace ':', '')
            if ($letter -and $letter -ieq $systemLetter) {
                Write-ColorMessage "WARNING: the store is on the system drive ($drive). USMT rejects stores on C:\ (code 27)." "Warning"
                $ok = $false
            }
            $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $letter }
            if ($vol -and $vol.FileSystemType -ne 'NTFS') {
                Write-ColorMessage "WARNING: $drive is $($vol.FileSystemType). USMT needs an NTFS volume for large stores (code 27)." "Warning"
                $ok = $false
            }
        }
    } catch {
        # Volume information is not always available; the run still proceeds.
    }
    return $ok
}

function Write-USMTManifest {
    param([string]$StorePath, [hashtable]$Info)
    try {
        $json = ConvertTo-Json -InputObject $Info -Depth 5
        Write-Utf8NoBomFile -Path (Join-Path $StorePath 'store_manifest.json') -Content $json
    } catch {
        Write-ColorMessage "Could not write store manifest: $($_.Exception.Message)" "Warning"
    }
}

function Read-USMTManifest {
    param([string]$StorePath)
    $path = Join-Path $StorePath 'store_manifest.json'
    if (!(Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

# /verify works on compressed stores only; a /nocompress (hardlink) store is not
# verifiable this way.
function Test-USMTStoreIntegrity {
    param([string]$StorePath, [string]$KeyFilePath = '')
    if (!(Test-Path -LiteralPath $USMTUtils)) {
        Write-ColorMessage "usmtutils.exe not found - store verification skipped." "Warning"
        return $null
    }
    $verifyLog = Join-Path $LogsDir 'usmtutils.log'
    $uArgs = @('/verify:summary', $StorePath, '/v:4', "/l:$verifyLog")
    if (-not [string]::IsNullOrWhiteSpace($KeyFilePath) -and (Test-Path -LiteralPath $KeyFilePath)) {
        $uArgs += @('/decrypt', "/keyfile:$KeyFilePath")
    }
    Write-ColorMessage "Verifying store with usmtutils /verify:summary..." "Info"
    try {
        & $USMTUtils @uArgs
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
        return $null
    }
    $code = $LASTEXITCODE
    Write-ColorMessage "usmtutils return code $code : $(Get-USMTCodeText $code)" "Info"
    $summary = Summarize-USMTLog -LogPath $verifyLog
    if ($summary) { Write-ColorMessage "Verify log: $($summary.Path)" "Info" }
    return $code
}

function Remove-USMTStore {
    param([string]$StorePath)
    if (!(Test-Path -LiteralPath $StorePath)) {
        Write-ColorMessage "Store not found: $StorePath" "Error"
        return $false
    }
    if (!(Confirm-Action "Delete this store? The Plakar copy (if any) is not deleted")) { return $false }
    if (Test-Path -LiteralPath $USMTUtils) {
        & $USMTUtils '/rd' $StorePath '/y'
        if ($LASTEXITCODE -eq 0) {
            Write-ColorMessage "Store removed with usmtutils /rd." "Success"
            return $true
        }
        Write-ColorMessage "usmtutils /rd failed (code $LASTEXITCODE : $(Get-USMTCodeText $LASTEXITCODE)). Trying a normal delete..." "Warning"
    }
    try {
        Remove-Item -LiteralPath $StorePath -Recurse -Force -ErrorAction Stop
        Write-ColorMessage "Store deleted." "Success"
        return $true
    } catch {
        Write-ColorMessage "ERROR: could not delete store: $($_.Exception.Message)" "Error"
        Write-ColorMessage "Locked store files need a reboot, or usmtutils /rd (USMT code 35)." "Warning"
        return $false
    }
}

function Get-USMTStoreInfo {
    param([string]$StorePath)
    try {
        if (!(Test-Path $StorePath)) {
            return @{ Exists = $false; SizeGB = 0; FileCount = 0 }
        }
        $files = Get-ChildItem $StorePath -Recurse -File -ErrorAction SilentlyContinue
        $size = ($files | Measure-Object -Property Length -Sum).Sum / 1GB
        return @{
            Exists = $true
            SizeGB = [math]::Round($size, 2)
            FileCount = $files.Count
        }
    } catch {
        return @{ Exists = $false; SizeGB = 0; FileCount = 0 }
    }
}

function Open-LogFile {
    param([string]$LogPath)
    if (Test-Path $LogPath) {
        Write-ColorMessage "Opening log file..." "Info"
        Start-Process notepad.exe -ArgumentList "$LogPath"
    } else {
        Write-ColorMessage "Log file not found: $LogPath" "Warning"
    }
}

# Where the browser actually is. Get-Command only finds it when it is on PATH, and Edge
# is not; App Paths is where the installer registers it. ${env:ProgramFiles(x86)} needs
# the braces - inside a double-quoted string, "$env:ProgramFiles(x86)" expands to
# 'C:\Program Files' plus the literal '(x86)', a path that can never exist. That is why
# the shortcut silently fell through to the default browser on 64-bit Windows, where
# Edge installs into the (x86) folder.
function Resolve-Browser {
    param([string]$ExeName, [string]$SubPath)

    $appPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName" -ErrorAction SilentlyContinue).'(default)'
    if ($appPath -and (Test-Path -LiteralPath $appPath)) { return $appPath }

    $cmd = (Get-Command $ExeName -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }

    foreach ($root in @($env:ProgramFiles, "${env:ProgramFiles(x86)}")) {
        $candidate = Join-Path (Join-Path $root $SubPath) $ExeName
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Open-PrivateUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    # Only http(s), so a file: or script: path cannot reach Start-Process.
    if ($Url -notmatch '^https?://') {
        Write-ColorMessage "Not an http(s) URL: $Url" "Warning"
        return
    }

    # Prefer Edge, then Chrome. Fall back to default browser (may not be private).
    $edge = Resolve-Browser "msedge.exe" "Microsoft\Edge\Application"
    if ($edge) {
        Write-ColorMessage "Opening $Url in Microsoft Edge (InPrivate)..." "Info"
        Start-Process -FilePath $edge -ArgumentList @("-inprivate", $Url)
        return
    }

    $chrome = Resolve-Browser "chrome.exe" "Google\Chrome\Application"
    if ($chrome) {
        Write-ColorMessage "Opening $Url in Google Chrome (Incognito)..." "Info"
        Start-Process -FilePath $chrome -ArgumentList @("--incognito", $Url)
        return
    }

    Write-ColorMessage "Edge/Chrome not found. Opening default browser (not guaranteed private)..." "Warning"
    Start-Process $Url
}

function Get-AvailableUSMTStores {
    param([string]$BasePath)

    try {
        $stores = Get-ChildItem $BasePath -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "USMT_Store_*" -or $_.Name -like "USMT_Offline_Store_*" } |
                  Sort-Object CreationTime -Descending
        return $stores
    } catch {
        return @()
    }
}

function Select-USMTStore {
    param([string]$BasePath)

    $stores = Get-AvailableUSMTStores -BasePath $BasePath

    if (-not $stores -or $stores.Count -eq 0) {
        Write-ColorMessage "No USMT stores found in $BasePath" "Warning"
        return $null
    }

    Write-ColorMessage "Available USMT Stores:" "Info"
    Write-Host ""

    for ($i = 0; $i -lt $stores.Count; $i++) {
        $store = $stores[$i]
        $storeInfo = Get-USMTStoreInfo -StorePath $store.FullName
        $sizeGB = $storeInfo.SizeGB
        $created = $store.CreationTime.ToString('yyyy-MM-dd HH:mm')

        Write-Host ("  {0}. {1}" -f ($i+1), $store.Name) -ForegroundColor Cyan
        Write-Host ("     Created: {0}, Size: {1} GB" -f $created, $sizeGB) -ForegroundColor Gray
    }

    Write-Host ""
    $choice = Read-Host "Select store number (1-$($stores.Count))"

    if ($choice -match '^[0-9]+$') {
        $index = [int]$choice - 1
        if ($index -ge 0 -and $index -lt $stores.Count) {
            return $stores[$index].FullName
        }
    }

    Write-ColorMessage "Invalid selection." "Warning"
    return $null
}

function Get-USMTStoreDetails {
    param([string]$StorePath)

    if (!(Test-Path $StorePath)) {
        Write-ColorMessage "ERROR: USMT store not found at $StorePath" "Error"
        return
    }

    Write-ColorMessage "=== USMT Store Details ===" "Info"
    Write-Host ""

    # Basic store info
    $storeInfo = Get-USMTStoreInfo -StorePath $StorePath
    $sizeGB = $storeInfo.SizeGB
    $fileCount = $storeInfo.FileCount

    Write-ColorMessage "Location: $StorePath" "Info"
    Write-ColorMessage "Size: $sizeGB GB" "Info"
    Write-ColorMessage "Files: $fileCount" "Info"

    # Options recorded at scan time. LoadState has to match them, so they belong
    # with the store instead of in the operator's memory.
    $manifest = Read-USMTManifest -StorePath $StorePath
    if ($manifest) {
        Write-Host ""
        Write-ColorMessage "Recorded at scan time:" "Info"
        Write-Host "  - Tool:     $($manifest.Tool)" -ForegroundColor Gray
        Write-Host "  - Created:  $($manifest.Created)" -ForegroundColor Gray
        if ($manifest.Users) { Write-Host "  - Users:    $($manifest.Users -join ', ')" -ForegroundColor Gray }
        Write-Host "  - Source:   $($manifest.Source)" -ForegroundColor Gray
        Write-Host "  - Compression: $(if ($manifest.NoCompress) { 'off (/nocompress)' } else { 'on' })" -ForegroundColor Gray
        Write-Host "  - Encryption:    $(if ($manifest.Encrypted) { 'yes' } else { 'no' })" -ForegroundColor Gray
        if ($manifest.KeyFile) { Write-Host "  - Keyfile:  $($manifest.KeyFile)" -ForegroundColor Gray }
        Write-Host "  - EFS mode: $($manifest.EfsMode)" -ForegroundColor Gray
        if ($manifest.UsbExclusion) { Write-Host "  - USB drive excluded from the scan: $($manifest.UsbExclusion)" -ForegroundColor Gray }
        Write-Host "  - Exit code: $($manifest.ExitCode) ($(Get-USMTCodeText ([int]$manifest.ExitCode)))" -ForegroundColor Gray
    }
    Write-Host ""

    # Try to read migration XML files for metadata
    try {
        $catalogFile = Join-Path $StorePath "USMT\USMT.MIG"
        if (Test-Path $catalogFile) {
            Write-ColorMessage "Store catalog file found" "Success"
        }

        # List key files in store
        Write-ColorMessage "Store Contents:" "Info"
        $usmtFolder = Join-Path $StorePath "USMT"
        if (Test-Path $usmtFolder) {
            $migFiles = Get-ChildItem $usmtFolder -File | Select-Object -First 10
            foreach ($file in $migFiles) {
                $fileSizeMB = [math]::Round($file.Length / 1MB, 2)
                Write-Host "  - $($file.Name) ($fileSizeMB MB)" -ForegroundColor Gray
            }

            $totalFiles = (Get-ChildItem $usmtFolder -File).Count
            if ($totalFiles -gt 10) {
                Write-Host "  ... and $($totalFiles - 10) more files" -ForegroundColor Gray
            }
        }
        Write-Host ""

        # Check for control files
        Write-ColorMessage "Migration Metadata:" "Info"

        $controlFile = Join-Path $StorePath "USMT\Config.xml"
        if (Test-Path $controlFile) {
            Write-Host "  - Configuration: Found" -ForegroundColor Green
        }

        # List backed up users based on folder structure. Older runs put USMT's
        # working directory inside the store; that is not a user folder.
        $userFolders = Get-ChildItem $StorePath -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -ne "USMT" -and $_.Name -ne "_work" }
        if ($userFolders) {
            Write-Host ""
            Write-ColorMessage "Backed Up Users/Data:" "Info"
            foreach ($folder in $userFolders) {
                $folderSizeGB = [math]::Round(((Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB), 2)
                Write-Host "  - $($folder.Name) ($folderSizeGB GB)" -ForegroundColor Cyan
            }
        }

        # Show creation date
        $storeCreated = (Get-Item $StorePath).CreationTime
        Write-Host ""
        Write-ColorMessage "Store Created: $($storeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" "Info"

    } catch {
        Write-ColorMessage "Could not read detailed metadata: $($_.Exception.Message)" "Warning"
    }

    Write-Host ""
}

# ------------------------------
# USMT user selection helpers
# ------------------------------
function Get-UserProfileNames {
    $systemProfiles = @('All Users','Default','Default User','Public','WDAGUtilityAccount')
    try {
        Get-ChildItem 'C:\Users' -Directory -ErrorAction Stop |
            Where-Object { $systemProfiles -notcontains $_.Name } |
            Select-Object -ExpandProperty Name
    } catch {
        @()
    }
}

function Select-USMTUsers {
    $names = Get-UserProfileNames
    if (-not $names -or $names.Count -eq 0) {
        Write-ColorMessage "No user profiles found under C:\\Users" "Warning"
        return @()
    }
    Write-ColorMessage "Available user profiles:" "Info"
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i+1), $names[$i])
    }
    $choice = Read-Host "Enter numbers to include (e.g. 1,3,5) or * for all"
    if ($choice -eq '*') { $selected = $names }
    else {
        $indexes = $choice -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ - 1 }
        $selected = @()
        foreach ($idx in $indexes) {
            if ($idx -ge 0 -and $idx -lt $names.Count) { $selected += $names[$idx] }
        }
    }
    if (-not $selected -or $selected.Count -eq 0) {
        Write-ColorMessage "No users selected." "Warning"
        return @()
    }
    # Return fully-qualified local accounts for USMT /ui
    return $selected | ForEach-Object { "$env:COMPUTERNAME\$_" }
}

# =============================================================
# Plakar + USMT Technician Menu – USB Version
# =============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ------------------------------
# Plakar setup
# ------------------------------
$Repo = Join-Path $ScriptDir "plakar_repo"
$PlakarExe = Join-Path $ScriptDir "plakar.exe"
$KeyFile = Join-Path $ScriptDir ".plakar_key"

# How long plakar keeps a packfile it coloured for deletion before really
# deleting it. plakar reads this from the environment (PLAKAR_GRACEPERIOD), so
# leave $GracePeriod empty to keep plakar's default of 7 days. '0' sweeps the
# already-coloured packfiles in the same run, '1h' keeps a small safety margin.
# A short period is irreversible: a packfile from an aborted or in-progress
# backup is deleted immediately, so only use it when nothing else is writing to
# the repository.
$GracePeriod = ''

# Regenerable caches and scratch files. Excluding these is the single biggest speed
# lever left on a real profile - on a typical machine Temp alone is about half the
# bytes and a third of the file count, so a backup that skips it is roughly half the
# work. plakar uses gitignore semantics: a pattern containing a slash is anchored to
# the snapshot root, so 'AppData/Local/Temp/' does NOT match. A bare name matches at
# any depth, which is what these are - verified against a probe tree.
#
# These are NOT applied automatically: the backup prompt asks first, because a
# technician sometimes wants Temp for forensics and a cache is only regenerable if
# the machine is still running.
$JunkPatterns = @(
    'Temp/',
    'Cache/',
    'INetCache/',
    'Thumbnails/',
    'Explorer/',
    'NuGet/',
    'npm-cache/',
    'pkg-npm-caches/',
    '*.tmp'
)

# Check if plakar.exe exists
if (!(Test-Path $PlakarExe)) {
    Write-ColorMessage "ERROR: plakar.exe not found at: $PlakarExe" "Error"
    Write-ColorMessage "Please ensure plakar.exe is in the same directory as this script." "Warning"
    Pause
    exit
}

# Handle keyfile setup before creating repository
$NeedsPassphrase = $false
if (!(Test-Path $KeyFile)) {
    $NeedsPassphrase = $true
} else {
    $KeyContent = Get-Content $KeyFile -Raw -ErrorAction SilentlyContinue
    if ($null -ne $KeyContent) {
        $KeyContent = $KeyContent.Trim([char]0xFEFF).Trim()
    }
    if ($KeyContent -match 'CHANGE_THIS_PASSPHRASE' -or [string]::IsNullOrWhiteSpace($KeyContent)) {
        $NeedsPassphrase = $true
        Write-ColorMessage "Placeholder passphrase detected in .plakar_key" "Warning"
    }
}

if ($NeedsPassphrase) {
    Write-ColorMessage "Setting up passphrase for Plakar repository..." "Warning"
    Write-ColorMessage "" "Info"
    Write-ColorMessage "SECURITY WARNING: Passphrase will be stored in PLAINTEXT in .plakar_key" "Warning"
    Write-ColorMessage "For maximum security, store this USB drive in a secure location." "Warning"
    Write-ColorMessage "" "Info"
    Write-ColorMessage "Enter a passphrase (or press Enter for no passphrase):" "Info"
    $Passphrase = Read-Host -AsSecureString
    $PlainPassphrase = ConvertFrom-SecureStringPlain $Passphrase

    if ($PlainPassphrase -ne "") {
        Write-Utf8NoBomFile -Path $KeyFile -Content $PlainPassphrase
        Write-ColorMessage "Passphrase saved to .plakar_key" "Success"
    } else {
        Write-ColorMessage "No passphrase set. Repository will be unencrypted." "Warning"
        if (Test-Path $KeyFile) { Remove-Item $KeyFile -Force }
    }
}

# Pass -keyfile and the path as separate argv elements (no embedded quotes).
# Existing repos may have been created from a UTF-8-BOM keyfile; do not strip
# those bytes, and rewrite the file only when a variant actually unlocks.
Resolve-PlakarKeyFile

# Ensure Plakar repo exists
if (!(Test-Path $Repo)) {
    Write-ColorMessage "Creating Plakar repository at $Repo..." "Info"
    try {
        & $PlakarExe @PlakarKeyArgs at "$Repo" create
        if ($LASTEXITCODE -ne 0) {
            Write-ColorMessage "ERROR: Failed to create Plakar repository. Exit code: $LASTEXITCODE" "Error"
            exit
        }
        Write-ColorMessage "Repository created successfully." "Success"
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
        exit
    }
}

# ------------------------------
# USMT setup (dynamic USB path detection + architecture detection)
# ------------------------------
# Detect system architecture. The ADK publishes no arm64 USMT build, so on ARM64
# Windows the x86 tools are the ones that actually run.
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
if ($Arch -eq 'ARM64') { $ArchCandidates = @('amd64', 'ARM64', 'x86') } else { $ArchCandidates = @($Arch, 'X64', 'x86') }

# Try to find USMT in script directory first, then drive root
$USMTPath = $null
$PossiblePaths = @()
foreach ($candidateArch in $ArchCandidates) {
    $PossiblePaths += (Join-Path $ScriptDir "USMT\$candidateArch")      # Architecture-specific folder
    $PossiblePaths += (Join-Path $ScriptDir "..\USMT\$candidateArch")   # Parent folder
}

# Add drive root path if on Windows
$ScriptDrive = Split-Path -Qualifier $ScriptDir
if (-not [string]::IsNullOrEmpty($ScriptDrive)) {
    foreach ($candidateArch in $ArchCandidates) {
        $PossiblePaths += (Join-Path $ScriptDrive "USMT\$candidateArch")
    }
}

# Find first valid USMT path
foreach ($Path in $PossiblePaths) {
    if (Test-Path (Join-Path $Path "scanstate.exe")) {
        $USMTPath = $Path
        Write-Host "Found USMT ($candidateArch) at: $USMTPath" -ForegroundColor Green
        break
    }
}

# Fallback to script directory if not found
if ([string]::IsNullOrEmpty($USMTPath)) {
    $USMTPath = Join-Path $ScriptDir "USMT\$Arch"
}

# Logs and USMT's working directory must stay outside the store: /l inside
# StorePath is rejected (USMT code 13), and a working directory inside the store
# is picked up by the store listing and by the Plakar backup.
$LogsDir = Join-Path $ScriptDir 'logs'
$UsmtWorkDir = Join-Path $ScriptDir 'work'
foreach ($dir in @($LogsDir, $UsmtWorkDir)) {
    if (!(Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null } catch { }
    }
}

# menu.sh rotates its logs; the PowerShell hosts must not grow logs without bound either.
# Compress anything over 10 MB and keep the newest 5 .gz files, the same limits as menu.sh.
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

$ScanState = Join-Path $USMTPath "scanstate.exe"
$LoadState = Join-Path $USMTPath "loadstate.exe"
$USMTUtils = Join-Path $USMTPath "usmtutils.exe"
$USMTStore = Join-Path $USMTPath "USMT_Store"
$ScanLog = Join-Path $USMTPath "scanstate.log"
$LoadLog = Join-Path $USMTPath "loadstate.log"
# The ADK puts the XML files next to scanstate.exe; this template also keeps them
# at the USB root. Accept either, preferring the USMT folder, so both hosts resolve
# the same files.
function Resolve-USMTXmlFile {
    param([string]$FileName)
    $inUsmt = Join-Path $USMTPath $FileName
    if (Test-Path $inUsmt) { return $inUsmt }
    $inRoot = Join-Path $ScriptDir $FileName
    if (Test-Path $inRoot) { return $inRoot }
    return $inUsmt   # not found anywhere: report the USMT location in the error
}

$MigUserXML = Resolve-USMTXmlFile "miguser.xml"
$MigAppXML = Resolve-USMTXmlFile "migapp.xml"
$MigDocsXML = Resolve-USMTXmlFile "migdocs.xml"
$MigModernXML = Resolve-USMTXmlFile "migmodern.xml"

# The XML set used by both scan and restore. migmodern.xml is optional so the
# stock ADK profiles keep working on templates that do not have it.
$DefaultXmlSet = @($MigUserXML, $MigAppXML, $MigDocsXML)
if (Test-Path -LiteralPath $MigModernXML) { $DefaultXmlSet += $MigModernXML }

# ------------------------------
# Check USMT prerequisites
# ------------------------------
function Require-USMTCheck {
    if (-not (Test-Path $ScanState) -or -not (Test-Path $LoadState)) {
        Write-ColorMessage "ERROR: USMT files not found!" "Error"
        Write-ColorMessage "Searched in: $USMTPath" "Warning"
        Write-Host ""
        Write-ColorMessage "=== How to get USMT ===" "Info"
        Write-Host "1. Download Windows ADK from:" -ForegroundColor White
        Write-Host "   https://go.microsoft.com/fwlink/?linkid=2243390" -ForegroundColor Gray
        Write-Host "2. Install and select only 'User State Migration Tool (USMT)'" -ForegroundColor White
        Write-Host "3. Copy files from installation folder to USB:" -ForegroundColor White
        Write-Host "   From: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\USMT\$Arch\" -ForegroundColor Gray
        Write-Host "   To:   $ScriptDir\USMT\$Arch\" -ForegroundColor Gray
        Write-Host ""
        Write-ColorMessage "Supported architectures: amd64 (64-bit), x86 (32-bit). ARM64 machines have no arm64 USMT build and run the x86 tools." "Warning"
        Write-ColorMessage "Detected system: $Arch (searched: $($ArchCandidates -join ', '))" "Warning"
        Pause
        return $false
    }
    if (-not (Test-Path $MigUserXML) -or -not (Test-Path $MigAppXML)) {
        Write-ColorMessage "ERROR: miguser.xml or migapp.xml not found." "Error"
        Write-ColorMessage "Looked in: $USMTPath and $ScriptDir" "Warning"
        Pause
        return $false
    }
    return $true
}

# ------------------------------
# Menu functions
# ------------------------------
function ShowMenu {
    Clear-Host

    # Get repository info
    $repoInfo = Get-RepositoryInfo
    $snapCount = $repoInfo.SnapshotCount
    $repoSize = $repoInfo.SizeGB

    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "     Plakar + USMT Technician Menu" -ForegroundColor White
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "Repository: " -NoNewline -ForegroundColor Gray
    Write-Host "$snapCount snapshots, $repoSize GB on disk" -ForegroundColor Yellow
    if ($snapCount -eq 0 -and $repoSize -gt 0) {
        Write-Host "  ($($repoInfo.LogicalGB) GB referenced - the rest is orphaned, option 8 reclaims it)" -ForegroundColor Gray
    }
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Backup user profile"
    Write-Host "2. Backup custom folder"
    Write-Host "3. Restore snapshot"
    Write-Host "4. List snapshots"
    Write-Host "5. View snapshot details"
    Write-Host "6. Start Plakar UI"
    Write-Host "7. Delete snapshot"
    Write-Host "8. Run Plakar maintenance (cleanup)"
    Write-Host "9. USMT Backup (ScanState)"
    Write-Host "10. USMT Offline Backup (ScanState)"
    Write-Host "11. USMT Restore (LoadState)"
    Write-Host "12. USMT Store Details (verify / delete)"
    Write-Host "13. Client Details (Private Browser)"
    Write-Host "14. Technician Portal (Private Browser)"
    Write-Host "15. Prune snapshots (retention policy)"
    Write-Host "16. Locate a file across snapshots"
    Write-Host "17. Exit"
    Write-Host ""
}

function PlakarBackup($Folder, $TagName, $Category = 'profile') {
    # Validate inputs
    if (!(Test-ValidPath $Folder)) { Pause; return }
    if ([string]::IsNullOrWhiteSpace($TagName)) {
        Write-ColorMessage "ERROR: Tag name cannot be empty." "Error"
        Pause
        return
    }

    # Check disk space
    Test-DiskSpace -Path $Repo | Out-Null

    $IgnoreArgs = Get-IgnoreArgs (Ask-ExcludeJunk)

    $SnapTag = "${TagName}_$(Get-Date -Format yyyyMMdd_HHmmss)"
    Write-ColorMessage "Starting backup: $SnapTag ..." "Info"

    # The metadata name is the snapshot name, so a profile backup can be found by user
    # later without reading the tag.
    Invoke-PlakarBackup -Folder $Folder -SnapTag $SnapTag -Name $TagName -Category $Category -IgnoreArgs $IgnoreArgs

    Pause
}

function PlakarMaintenance {
    Write-ColorMessage "Running Plakar maintenance (cleanup)..." "Info"
    $savedGrace = $env:PLAKAR_GRACEPERIOD
    try {
        if ($GracePeriod) {
            $env:PLAKAR_GRACEPERIOD = $GracePeriod
            Write-ColorMessage "Grace period override: $GracePeriod (coloured packfiles can be deleted in this run)" "Warning"
        }
        & $PlakarExe @PlakarKeyArgs at "$Repo" maintenance
        Invalidate-RepoInfoCache
        if ($LASTEXITCODE -eq 0) {
            Write-ColorMessage "Maintenance completed successfully." "Success"
        } else {
            Write-ColorMessage "Maintenance FAILED. Exit code: $LASTEXITCODE" "Error"
        }
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
    } finally {
        if ($GracePeriod) {
            $env:PLAKAR_GRACEPERIOD = $savedGrace
        }
    }
}

# plakar keeps every snapshot and has no retention of its own, so a technician USB
# fills up over time. prune is the policy engine: keep the last N days, cap how many
# snapshots survive per bucket, group by name so each profile gets its own allowance.
# Running prune without -apply only reports, so the plan is shown before anything is
# removed. Deleted snapshots are only truly gone after maintenance, once the grace
# period passes.
function PlakarPrune {
    Write-ColorMessage "Prune snapshots (retention policy)" "Info"
    Write-Host "Example: 30 days with a cap of 1 per day keeps one snapshot per day for a month." -ForegroundColor Gray

    $daysText = Read-Host "Days to keep (30)"
    if ([string]::IsNullOrWhiteSpace($daysText)) { $daysText = '30' }
    $capText = Read-Host "Max snapshots kept per day (1)"
    if ([string]::IsNullOrWhiteSpace($capText)) { $capText = '1' }
    $category = Read-Host "Category to apply the policy to (profile, empty for all)"

    $days = 0
    $cap = 0
    if (-not [int]::TryParse($daysText, [ref]$days)) {
        Write-ColorMessage "ERROR: days must be a number." "Error"
        Pause
        return
    }
    if (-not [int]::TryParse($capText, [ref]$cap)) {
        Write-ColorMessage "ERROR: the per-day cap must be a number." "Error"
        Pause
        return
    }
    if ($days -lt 1 -or $cap -lt 1) {
        Write-ColorMessage "ERROR: both values must be at least 1." "Error"
        Pause
        return
    }

    $argv = $script:PlakarKeyArgs + @('at', $Repo, 'prune', '-days', "$days", '-per-day', "$cap", '-group-by', 'name')
    if (-not [string]::IsNullOrWhiteSpace($category)) { $argv += @('-category', $category) }

    Write-Host ""
    Write-ColorMessage "Plan:" "Info"
    & $PlakarExe @argv 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message -ForegroundColor Red }
        else { Write-Host $_ }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-ColorMessage "Prune failed. Exit code: $LASTEXITCODE" "Error"
        Pause
        return
    }

    if (!(Confirm-Action "Apply this policy and delete the snapshots listed above?")) { Pause; return }

    $applyArgv = $argv + @('-apply')
    & $PlakarExe @applyArgv 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message -ForegroundColor Red }
        else { Write-Host $_ }
    }
    Invalidate-RepoInfoCache
    if ($LASTEXITCODE -eq 0) {
        Write-ColorMessage "Policy applied." "Success"
        Write-Host "The space is reclaimed by maintenance after the grace period, not by prune itself." -ForegroundColor Gray
    } else {
        Write-ColorMessage "Prune failed. Exit code: $LASTEXITCODE" "Error"
    }
    Pause
}

# Search every snapshot, not just the last one. Useful when you no longer know which
# backup a file came from. plakar has no size cap, so this is also how you find the
# one huge file that made a profile backup slow.
function PlakarLocate {
    Write-ColorMessage "Locate a file across snapshots" "Info"
    Write-Host "Searches all snapshots. Example: invoice.pdf" -ForegroundColor Gray
    $pattern = Read-Host "File name or pattern"
    if ([string]::IsNullOrWhiteSpace($pattern)) { Pause; return }

    $argv = $script:PlakarKeyArgs + @('at', $Repo, 'locate', $pattern)
    $hits = 0
    Write-Host ""
    & $PlakarExe @argv 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message -ForegroundColor Red }
        else { Write-Host $_; $hits++ }
    }

    Write-Host ""
    $level = if ($hits -gt 0) { "Success" } else { "Info" }
    Write-ColorMessage ("{0} match(es)." -f $hits) $level
    Write-Host "To read one: plakar at <repo> cat <snapshotID>:<path>" -ForegroundColor Gray
    Pause
}

function PlakarRestore($SnapTag, $RestoreTo) {
    # Validate inputs
    if ([string]::IsNullOrWhiteSpace($SnapTag)) {
        Write-ColorMessage "ERROR: Snapshot tag cannot be empty." "Error"
        Pause
        return
    }
    if ([string]::IsNullOrWhiteSpace($RestoreTo)) {
        Write-ColorMessage "ERROR: Restore path cannot be empty." "Error"
        Pause
        return
    }

    # Check disk space
    Test-DiskSpace -Path (Split-Path $RestoreTo -Parent) | Out-Null

    # Create restore folder if needed
    if (!(Test-Path $RestoreTo)) {
        Write-ColorMessage "Creating restore folder: $RestoreTo" "Info"
        try {
            New-Item -ItemType Directory -Path "$RestoreTo" -ErrorAction Stop | Out-Null
        } catch {
            Write-ColorMessage "ERROR: Failed to create restore folder: $($_.Exception.Message)" "Error"
            Pause
            return
        }
    }

    Write-ColorMessage "Restoring snapshot $SnapTag to $RestoreTo ..." "Info"
    try {
        # Source ACLs carry SIDs from the machine the backup was made on; skipping them
        # lets files inherit permissions from the destination and is roughly 2x faster
        # on a profile-shaped restore (measured on 20k small files).
        & $PlakarExe @PlakarKeyArgs at "$Repo" restore -tag "$SnapTag" -to "$RestoreTo" -o skip_permissions=1
        if ($LASTEXITCODE -eq 0) {
            Write-ColorMessage "Restore completed successfully." "Success"
            Write-ColorMessage "Files restored to: $RestoreTo" "Info"
        } else {
            Write-ColorMessage "Restore FAILED. Exit code: $LASTEXITCODE" "Error"
        }
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
    }
    Pause
}

function Find-OfflineWindowsDirs {
    $found = @()
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
        foreach ($d in $drives) {
            $winDir = Join-Path $d.Root "Windows"
            $cfg = Join-Path $winDir "System32\\config"
            if (Test-Path $cfg) {
                $found += $winDir
            }
        }
    } catch {
        return @()
    }
    return $found | Select-Object -Unique
}

function Test-OfflineWindowsDir {
    param([string]$WindowsDir)
    if ([string]::IsNullOrWhiteSpace($WindowsDir)) { return $false }
    if (!(Test-Path $WindowsDir)) { return $false }
    $cfg = Join-Path $WindowsDir "System32\\config"
    if (!(Test-Path $cfg)) { return $false }
    $systemHive = Join-Path $cfg "SYSTEM"
    $softwareHive = Join-Path $cfg "SOFTWARE"
    return (Test-Path $systemHive) -and (Test-Path $softwareHive)
}

# ------------------------------
# USMT run helpers
# ------------------------------
function Ensure-USMTWorkDir {
    param([string]$JobName)
    $workDir = Join-Path $UsmtWorkDir (ConvertTo-SafeName $JobName)
    if (!(Test-Path -LiteralPath $workDir)) {
        try { New-Item -ItemType Directory -Path $workDir -ErrorAction Stop | Out-Null } catch { }
    }
    # USMT needs ~250 MB of writable temp space outside the store (code 29).
    $env:USMT_WORKING_DIR = $workDir
    return $workDir
}

# /localonly only covers drives the OS reports as Removable or Network. A USB
# drive that Windows presents as Fixed media is still scanned, and that is what
# happens to this template's own drive on most machines. The only way to keep it
# out is an explicit unconditionalExclude for the drive root, generated per run
# because the letter changes with every PC.
#
# This rule affects what ScanState reads, not where it writes: USMT already
# excludes StorePath from the scan, so a store that lives on the USB drive is
# still written normally.
function Write-UsbExclusionXml {
    param([string]$WorkDir, [string]$DriveRoot)
    if ([string]::IsNullOrWhiteSpace($DriveRoot)) { return '' }
    if (-not $DriveRoot.EndsWith('\')) { $DriveRoot += '\' }
    $path = Join-Path $WorkDir 'exclude_usb.xml'
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated for this run only. The drive letter is the USB drive this tool
     runs from, which changes with every PC, so it cannot be a shipped rule. -->
<migration urlid="http://www.microsoft.com/migration/1.0/migxmlext/excludeusb">
    <component type="Documents" context="System">
        <displayName>Exclude the USB drive the tool runs from</displayName>
        <role role="Data">
            <rules>
                <unconditionalExclude>
                    <objectSet>
                        <pattern type="File">${DriveRoot}*[*]</pattern>
                    </objectSet>
                </unconditionalExclude>
            </rules>
        </role>
    </component>
</migration>
"@
    try {
        Write-Utf8NoBomFile -Path $path -Content $xml
        return $path
    } catch {
        Write-ColorMessage "Could not write the USB exclusion rule: $($_.Exception.Message)" "Warning"
        return ''
    }
}

function Ask-USMTOptions {
    param([string]$DefaultEfsMode = 'skip')
    $opts = @{
        EfsMode   = $DefaultEfsMode
        NoCompress = $false
        KeyFile   = ''
        LocalOnly = $true
        ExcludeUsb = $true
    }

    $efs = Read-Host "EFS handling (abort / skip / decryptcopy / copyraw) [default: $DefaultEfsMode]"
    if (-not [string]::IsNullOrWhiteSpace($efs)) {
        $efs = $efs.Trim().ToLower()
        if (@('abort', 'skip', 'decryptcopy', 'copyraw') -contains $efs) {
            $opts.EfsMode = $efs
        } else {
            Write-ColorMessage "Unknown EFS option '$efs'. Using $DefaultEfsMode." "Warning"
        }
    }

    if (Confirm-Action "Skip store compression (/nocompress)? Microsoft presents this as a testing option") {
        $opts.NoCompress = $true
        Write-ColorMessage "LoadState must then use the same option, and an encrypted uncompressed store must be decrypted with usmtutils /decrypt first." "Warning"
    } else {
        if (Confirm-Action "Encrypt the store? (needs a USMT keyfile)") {
            $keyPath = Read-Host "Path to USMT keyfile (press Enter to skip encryption)"
            if (-not [string]::IsNullOrWhiteSpace($keyPath)) {
                if (Test-ValidPath $keyPath) { $opts.KeyFile = $keyPath }
            }
        }
    }

    $localOnly = Read-Host "Scan local drives only (/localonly)? [Y/n]"
    $opts.LocalOnly = ($localOnly -notmatch '^[Nn]')

    $excludeUsb = Read-Host "Exclude the drive this tool runs from ($ScriptDrive) from the scan? [Y/n]"
    $opts.ExcludeUsb = ($excludeUsb -notmatch '^[Nn]')
    if ($opts.ExcludeUsb -and $opts.LocalOnly) {
        Write-ColorMessage "/localonly does not cover a USB drive that Windows reports as a fixed disk, so this run adds an explicit XML rule for $ScriptDrive." "Info"
    }

    return $opts
}

function Run-USMTScan {
    param(
        [string]$StorePath,
        [string]$StoreName,
        [string[]]$XmlFiles,
        [string[]]$Users,
        [hashtable]$Options,
        [string]$SourceLabel,
        [string]$LogPath,
        [string]$ProgressPath,
        [string]$OfflineXml,
        [string]$UsbExclusionXml = '',
        [string]$Operation = 'USMT Backup'
    )

    $xmlSet = @($XmlFiles)
    if (-not [string]::IsNullOrWhiteSpace($UsbExclusionXml)) { $xmlSet += $UsbExclusionXml }

    $scanArgs = @($StorePath)
    foreach ($xml in $xmlSet) { $scanArgs += "/i:$xml" }
    if ($Users -and $Users.Count -gt 0) {
        foreach ($u in $Users) { $scanArgs += "/ui:$u" }
    } else {
        $scanArgs += '/all'
    }
    if (-not [string]::IsNullOrWhiteSpace($OfflineXml)) { $scanArgs += "/offline:$OfflineXml" }
    if ($Options.LocalOnly) { $scanArgs += '/localonly' }
    $scanArgs += "/efs:$($Options.EfsMode)"
    $scanArgs += '/o'
    $scanArgs += '/c'
    $scanArgs += '/v:5'
    $scanArgs += "/l:$LogPath"
    if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) { $scanArgs += "/progress:$ProgressPath" }
    if ($Options.NoCompress) { $scanArgs += '/nocompress' }
    if ($Options.KeyFile) { $scanArgs += @('/encrypt', "/keyfile:$($Options.KeyFile)") }

    Write-Host ""
    Write-ColorMessage "Command: $ScanState $($scanArgs -join ' ')" "Info"
    Write-ColorMessage "This may take several minutes..." "Warning"
    Write-Host ""

    $startTime = Get-Date
    & $ScanState @scanArgs
    $code = $LASTEXITCODE
    $elapsed = (Get-Date) - $startTime
    Write-Host ""

    $kind = Report-USMTResult -Code $code -LogPath $LogPath -Operation $Operation -Minutes $elapsed.TotalMinutes

    $manifest = @{
        Tool         = 'scanstate'
        StoreName    = $StoreName
        Created      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Users        = @($Users)
        Xmls         = $xmlSet
        Source       = $SourceLabel
        EfsMode      = $Options.EfsMode
        LocalOnly    = [bool]$Options.LocalOnly
        UsbExclusion = if (-not [string]::IsNullOrWhiteSpace($UsbExclusionXml)) { Split-Path -Qualifier $UsbExclusionXml } else { '' }
        NoCompress   = [bool]$Options.NoCompress
        Encrypted    = (-not [string]::IsNullOrWhiteSpace($Options.KeyFile))
        KeyFile      = $Options.KeyFile
        ExitCode     = $code
    }
    Write-USMTManifest -StorePath $StorePath -Info $manifest

    $storeInfo = Get-USMTStoreInfo -StorePath $StorePath
    Write-Host ""
    Write-ColorMessage "Store: $StorePath" "Info"
    Write-ColorMessage "Store size: $($storeInfo.SizeGB) GB ($($storeInfo.FileCount) files)" "Info"

    if ($storeInfo.FileCount -eq 0) {
        Write-ColorMessage "The store contains no files - nothing was gathered." "Warning"
    }

    return @{ Kind = $kind; Code = $code; Manifest = $manifest; StoreInfo = $storeInfo }
}

function Offer-PlakarStoreBackup {
    param([string]$StorePath, [string]$TagName)
    if (!(Confirm-Action "Backup the USMT store to Plakar for extra safety?")) { return }
    Write-ColorMessage "Backing up USMT store to Plakar..." "Info"
    & $PlakarExe @PlakarKeyArgs at "$Repo" backup -tag "$TagName" "$StorePath"
    Invalidate-RepoInfoCache
    if ($LASTEXITCODE -eq 0) {
        Write-ColorMessage "USMT store backed up to Plakar successfully." "Success"
    } else {
        Write-ColorMessage "Failed to backup USMT store to Plakar. Exit code: $LASTEXITCODE" "Error"
    }
}

# ------------------------------
# Main Menu Loop
# ------------------------------
do {
    ShowMenu
    $Choice = Read-Host "Choose option"

    switch ($Choice) {

        "1" {
            Write-ColorMessage "Backup User Profile" "Info"
            Write-Host "Example: C:\Users\JohnDoe" -ForegroundColor Gray
            $Folder = Read-Host "Enter profile path"
            $Tag = Read-Host "Enter snapshot name (e.g., UserProfile_JohnDoe)"
            PlakarBackup $Folder $Tag
        }

        "2" {
            Write-ColorMessage "Backup Custom Folder" "Info"
            Write-Host "Example: C:\Important\Documents" -ForegroundColor Gray
            $Folder = Read-Host "Enter folder path"
            $Tag = Read-Host "Enter snapshot name (e.g., MyDocuments)"
            PlakarBackup $Folder $Tag 'custom'
        }

        "3" {
            Write-ColorMessage "Restore Snapshot" "Info"
            & $PlakarExe @PlakarKeyArgs at "$Repo" ls -tags
            Write-Host ""
            $SnapTag = Read-Host "Enter snapshot tag to restore"
            Write-Host "Example: C:\Restored" -ForegroundColor Gray
            $RestoreTo = Read-Host "Enter restore folder path"
            PlakarRestore $SnapTag $RestoreTo
        }

        "4" {
            Write-ColorMessage "Listing all snapshots..." "Info"
            & $PlakarExe @PlakarKeyArgs at "$Repo" ls -tags
            Pause
        }

        "8" {
            PlakarMaintenance
            Pause
        }

        "5" {
            Write-ColorMessage "Listing snapshots..." "Info"
            & $PlakarExe @PlakarKeyArgs at "$Repo" ls -tags
            $SnapTag = Read-Host "Enter snapshot tag to view details"
            if (![string]::IsNullOrWhiteSpace($SnapTag)) {
                Write-ColorMessage "`nSnapshot Details:" "Info"
                & $PlakarExe @PlakarKeyArgs at "$Repo" ls $SnapTag
            }
            Pause
        }

        "6" {
            Write-ColorMessage "Starting Plakar UI..." "Info"
            $uiArgs = @()
            if ($PlakarKeyArgs.Count -gt 0) { $uiArgs += $PlakarKeyArgs }
            $uiArgs += @("at", $Repo, "ui")
            Start-Process -FilePath $PlakarExe -ArgumentList $uiArgs
            Pause
        }

        "7" {
            Write-ColorMessage "Listing snapshots..." "Info"
            & $PlakarExe @PlakarKeyArgs at "$Repo" ls -tags
            $SnapTag = Read-Host "Enter tag to delete"

            if (![string]::IsNullOrWhiteSpace($SnapTag)) {
                if (Confirm-Action "Are you sure you want to DELETE snapshot '$SnapTag'?") {
                    Write-ColorMessage "Deleting snapshot..." "Warning"
                    & $PlakarExe @PlakarKeyArgs at "$Repo" rm -tag "$SnapTag" -apply
                    Invalidate-RepoInfoCache
                    if ($LASTEXITCODE -eq 0) {
                        Write-ColorMessage "Snapshot deleted successfully." "Success"
                        if (Confirm-Action "Run maintenance now to reclaim space?") {
                            PlakarMaintenance
                        }
                    } else {
                        Write-ColorMessage "Failed to delete snapshot. Exit code: $LASTEXITCODE" "Error"
                    }
                } else {
                    Write-ColorMessage "Delete operation cancelled." "Info"
                }
            } else {
                Write-ColorMessage "No tag entered. Operation cancelled." "Warning"
            }
            Pause
        }

        # USMT Backup
        "9" {
            if (-not (Require-USMTCheck)) { break }

            Write-ColorMessage "=== USMT Backup (ScanState) ===" "Info"
            Write-Host ""

            # Ask which user profiles to include
            $uiUsers = Select-USMTUsers
            if (-not $uiUsers -or $uiUsers.Count -eq 0) { Pause; break }

            # Estimate from the profiles that will actually be gathered instead of a
            # fixed 10 GB. A compressed store is usually smaller than the source, so
            # this is a floor with 2 GB of headroom.
            $profileGB = 0.0
            foreach ($u in $uiUsers) { $profileGB += Get-FolderSizeGB -Path (Join-Path 'C:\Users' (($u -split '\\')[-1])) }
            Write-ColorMessage "Profiles to gather: about $([math]::Round($profileGB, 2)) GB (the store is usually smaller)" "Info"

            if (!(Test-DiskSpace -Path $USMTPath -RequiredGB ([long]($profileGB + 2)))) {
                if (!(Confirm-Action "Low disk space detected. Continue anyway?")) {
                    Pause
                    break
                }
            }

            $opts = Ask-USMTOptions

            # Create unique store name based on users and timestamp
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $userNames = $uiUsers | ForEach-Object { ConvertTo-SafeName -Text (($_ -split '\\')[-1]) }
            $userNamesList = ($userNames | Select-Object -First 2) -join "_"
            if ($userNames.Count -gt 2) { $userNamesList += "_etc" }
            $storeName = "USMT_Store_${userNamesList}_$timestamp"
            $currentStore = Join-Path $USMTPath $storeName

            # /l must point outside StorePath (USMT code 13) and the working
            # directory must not sit inside the store, or it shows up as a "user"
            # and gets backed up to Plakar.
            $currentScanLog = Join-Path $LogsDir "scanstate_$timestamp.log"
            $progressFile = Join-Path $LogsDir "scan_progress_$timestamp.txt"
            if (!(Test-USMTStoreLocation -StorePath $currentStore)) {
                if (!(Confirm-Action "Store location looks risky. Continue anyway?")) {
                    Pause
                    break
                }
            }

            Write-ColorMessage "Store name: $storeName" "Info"
            Write-Host ""

            if (!(Test-Path $currentStore)) {
                Write-ColorMessage "Creating USMT store directory..." "Info"
                New-Item -ItemType Directory -Path $currentStore | Out-Null
            }
            $workDir = Ensure-USMTWorkDir -JobName $storeName
            $usbXml = ''
            if ($opts.ExcludeUsb) { $usbXml = Write-UsbExclusionXml -WorkDir $workDir -DriveRoot $ScriptDrive }
            if ($usbXml) { Write-ColorMessage "USB exclusion rule written for $ScriptDrive (the drive this tool runs from)" "Info" }

            $result = Run-USMTScan -StorePath $currentStore -StoreName $storeName -XmlFiles $DefaultXmlSet `
                -Users $uiUsers -Options $opts -SourceLabel 'C:\Users' `
                -LogPath $currentScanLog -ProgressPath $progressFile -UsbExclusionXml $usbXml `
                -Operation 'USMT Backup'

            if ($result.Kind -eq 'failure') {
                if (Confirm-Action "Would you like to view the log file?") {
                    Open-LogFile -LogPath $currentScanLog
                }
                Pause
                break
            }

            if (-not $opts.NoCompress -and (Confirm-Action "Verify the store now with usmtutils?")) {
                Test-USMTStoreIntegrity -StorePath $currentStore -KeyFilePath $opts.KeyFile
            }

            Offer-PlakarStoreBackup -StorePath $currentStore -TagName $storeName
            Pause
        }
        # USMT Offline Backup
        "10" {
            if (-not (Require-USMTCheck)) { break }

            Write-ColorMessage "=== USMT Offline Backup (ScanState) ===" "Info"
            Write-Host ""
            Write-ColorMessage "This captures user profiles/settings from an OFFLINE Windows installation (e.g. old disk mounted as D:\\)." "Warning"
            Write-ColorMessage "Run from WinPE or another OS when the source Windows is not booted." "Warning"
            Write-Host ""

            $candidates = Find-OfflineWindowsDirs
            if ($candidates -and $candidates.Count -gt 0) {
                Write-ColorMessage "Detected offline Windows folders:" "Info"
                for ($i = 0; $i -lt $candidates.Count; $i++) {
                    Write-Host ("  {0}. {1}" -f ($i + 1), $candidates[$i]) -ForegroundColor Cyan
                }
                Write-Host ""
            }

            Write-Host "Example: D:\\Windows" -ForegroundColor Gray
            $offlineWinDir = Read-Host "Enter OFFLINE Windows directory"

            # Guardrail: offline migrations must NOT target the currently running OS
            try {
                $currentWinDir = [System.IO.Path]::GetFullPath($env:SystemRoot)
                $inputWinDir = [System.IO.Path]::GetFullPath($offlineWinDir)
                if ($inputWinDir.TrimEnd('\\') -ieq $currentWinDir.TrimEnd('\\')) {
                    Write-ColorMessage "ERROR: You entered the CURRENT Windows folder ($currentWinDir)." "Error"
                    Write-ColorMessage "Offline USMT must be run against a Windows installation that is NOT booted (typically from WinPE)." "Warning"
                    Pause
                    break
                }
            } catch {
                # Ignore path normalization failures
            }

            if (-not (Test-OfflineWindowsDir -WindowsDir $offlineWinDir)) {
                Write-ColorMessage "ERROR: Invalid offline Windows directory: $offlineWinDir" "Error"
                Write-ColorMessage "Expected to find: <WindowsDir>\\System32\\config\\SYSTEM" "Warning"
                Pause
                break
            }

            $offlineUsersDir = Join-Path (Split-Path -Qualifier $offlineWinDir) 'Users'
            $offlineProfileGB = Get-FolderSizeGB -Path $offlineUsersDir
            Write-ColorMessage "Offline profiles ($offlineUsersDir): about $offlineProfileGB GB" "Info"

            if (!(Test-DiskSpace -Path $USMTPath -RequiredGB ([long]($offlineProfileGB + 2)))) {
                if (!(Confirm-Action "Low disk space detected. Continue anyway?")) {
                    Pause
                    break
                }
            }

            $opts = Ask-USMTOptions

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $storeName = "USMT_Offline_Store_$timestamp"
            $currentStore = Join-Path $USMTPath $storeName
            $currentScanLog = Join-Path $LogsDir "scanstate_$timestamp.log"
            $progressFile = Join-Path $LogsDir "scan_progress_$timestamp.txt"

            if (!(Test-USMTStoreLocation -StorePath $currentStore)) {
                if (!(Confirm-Action "Store location looks risky. Continue anyway?")) {
                    Pause
                    break
                }
            }

            Write-ColorMessage "Store name: $storeName" "Info"
            Write-ColorMessage "Offline Windows: $offlineWinDir" "Info"
            Write-Host ""

            if (!(Test-Path $currentStore)) {
                Write-ColorMessage "Creating USMT store directory..." "Info"
                New-Item -ItemType Directory -Path $currentStore | Out-Null
            }
            $workDir = Ensure-USMTWorkDir -JobName $storeName

            # Build Offline.xml mapping for WinPE/offline drive-letter translation.
            # This helps USMT map the source OS's typical C: layout to the currently
            # mounted offline volume. The mapping file stays outside the store so it
            # is not gathered or backed up as migration data.
            $offlineDriveRoot = Split-Path -Qualifier $offlineWinDir
            if (-not [string]::IsNullOrWhiteSpace($offlineDriveRoot) -and -not $offlineDriveRoot.EndsWith('\')) {
                $offlineDriveRoot = "$offlineDriveRoot\"
            }
            $offlineXmlPath = Join-Path $workDir "Offline.xml"
            $offlineXml = @"
<offline>
  <winDir>
    <path>$offlineWinDir</path>
  </winDir>
  <mappings>
    <path>C:\, $offlineDriveRoot</path>
  </mappings>
</offline>
"@
            Write-Utf8NoBomFile -Path $offlineXmlPath -Content $offlineXml

            $usbXml = ''
            if ($opts.ExcludeUsb) {
                $toolRoot = Split-Path -Qualifier $ScriptDir
                $srcRoot  = Split-Path -Qualifier $offlineWinDir
                if ($toolRoot -and $srcRoot -and ($toolRoot -ieq $srcRoot)) {
                    Write-ColorMessage "The offline Windows folder is on the same drive this tool runs from, so the USB exclusion rule is skipped for this run." "Warning"
                } else {
                    $usbXml = Write-UsbExclusionXml -WorkDir $workDir -DriveRoot $ScriptDrive
                }
            }

            $result = Run-USMTScan -StorePath $currentStore -StoreName $storeName -XmlFiles $DefaultXmlSet `
                -Users @() -Options $opts -SourceLabel $offlineWinDir `
                -LogPath $currentScanLog -ProgressPath $progressFile -OfflineXml $offlineXmlPath `
                -UsbExclusionXml $usbXml -Operation 'USMT Offline Backup'

            if ($result.Kind -eq 'failure') {
                if (Confirm-Action "Would you like to view the log file?") {
                    Open-LogFile -LogPath $currentScanLog
                }
                Pause
                break
            }

            if (-not $opts.NoCompress -and (Confirm-Action "Verify the store now with usmtutils?")) {
                Test-USMTStoreIntegrity -StorePath $currentStore -KeyFilePath $opts.KeyFile
            }

            Offer-PlakarStoreBackup -StorePath $currentStore -TagName $storeName
            Pause
        }
        # USMT Restore
        "11" {
            if (-not (Require-USMTCheck)) { break }

            Write-ColorMessage "=== USMT Restore (LoadState) ===" "Info"
            Write-Host ""

            # Let user select from available stores
            $selectedStore = Select-USMTStore -BasePath $USMTPath
            if (-not $selectedStore) {
                Write-ColorMessage "No store selected. Operation cancelled." "Warning"
                Pause
                break
            }

            Write-Host ""
            # Show store information
            $storeInfo = Get-USMTStoreInfo -StorePath $selectedStore
            $manifest = Read-USMTManifest -StorePath $selectedStore
            Write-ColorMessage "Selected Store Information:" "Info"
            Write-ColorMessage "Location: $selectedStore" "Info"
            $storeSizeGB = $storeInfo.SizeGB
            $storeFileCount = $storeInfo.FileCount
            Write-ColorMessage "Size: $storeSizeGB GB" "Info"
            Write-ColorMessage "Files: $storeFileCount" "Info"
            Write-Host ""

            # Validate store integrity
            if ($storeFileCount -eq 0) {
                Write-ColorMessage "ERROR: USMT store appears to be empty or corrupted!" "Error"
                Pause
                break
            }

            # LoadState has to match how the store was created. The manifest keeps
            # the XML set, compression and encryption decisions from the scan run.
            $restoreXmls = $DefaultXmlSet
            if ($manifest -and $manifest.Xmls) {
                $recorded = @($manifest.Xmls | Where-Object { Test-Path -LiteralPath $_ })
                if ($recorded.Count -gt 0) { $restoreXmls = $recorded }
            }

            $restoreArgs = @($selectedStore)
            foreach ($xml in $restoreXmls) { $restoreArgs += "/i:$xml" }

            if ($manifest -and $manifest.NoCompress) {
                $restoreArgs += '/nocompress'
                Write-ColorMessage "Store was created with /nocompress (manifest): LoadState uses the same option." "Info"
            }

            $restoreKeyFile = ''
            if ($manifest -and $manifest.Encrypted) {
                if ($manifest.KeyFile -and (Test-Path -LiteralPath $manifest.KeyFile)) {
                    $restoreKeyFile = $manifest.KeyFile
                } else {
                    Write-ColorMessage "The store is encrypted but the recorded keyfile is not available (USMT code 37)." "Warning"
                    $keyPath = Read-Host "Path to the USMT keyfile (press Enter to continue without it)"
                    if (-not [string]::IsNullOrWhiteSpace($keyPath) -and (Test-ValidPath $keyPath)) { $restoreKeyFile = $keyPath }
                }
                if ($restoreKeyFile) { $restoreArgs += @('/decrypt', "/keyfile:$restoreKeyFile") }
            }

            Write-ColorMessage "WARNING: This will restore user profiles and settings to THIS machine!" "Warning"
            Write-ColorMessage "This operation will:" "Warning"
            Write-Host "  - Restore user profiles, documents, and settings" -ForegroundColor Yellow
            Write-Host "  - May require a system reboot to complete" -ForegroundColor Yellow
            Write-Host "  - Take several minutes to complete" -ForegroundColor Yellow
            Write-Host ""

            if (!(Confirm-Action "Are you sure you want to continue with USMT restore?")) {
                Write-ColorMessage "USMT restore cancelled." "Info"
                Pause
                break
            }

            # Snapshot the profiles that are about to be overwritten. LoadState has
            # no undo, so this is the only way back.
            if (Confirm-Action "Take a Plakar snapshot of the current profiles before restoring?") {
                $snapTag = "PreRestore_$(Get-Date -Format yyyyMMdd_HHmmss)"
                $IgnoreArgs = Get-IgnoreArgs (Ask-ExcludeJunk)
                Write-ColorMessage "Backing up C:\Users as $snapTag ..." "Info"
                # "C:\\Users" in a double-quoted PowerShell string is a literal double
                # separator, which shows up in the snapshot path. One backslash is what is
                # meant here. The report counts what plakar could not read, which on a live
                # profile is the whole point: a locked file is skipped and the snapshot still
                # exits 0.
                $code = Invoke-PlakarBackup -Folder 'C:\Users' -SnapTag $snapTag -Name 'PreRestore' -Category 'pre-restore' -IgnoreArgs $IgnoreArgs
                if ($code -eq 0) {
                    Write-ColorMessage "Snapshot created: $snapTag" "Success"
                } else {
                    Write-ColorMessage "Snapshot failed (exit $code). Restore continues anyway." "Warning"
                }
            }

            # Optional user mapping: LoadState only, and only for accounts that
            # already exist on this machine.
            if (Confirm-Action "Map a restored user to a different local account (/mu)?") {
                $oldUser = Read-Host "Source user as recorded in the store (Domain_User, e.g. OLDPC_jdoe)"
                $newUser = Read-Host "Target local account (Domain_User, e.g. NEWPC_jdoe)"
                if (-not [string]::IsNullOrWhiteSpace($oldUser) -and -not [string]::IsNullOrWhiteSpace($newUser)) {
                    $restoreArgs += "/mu:${oldUser}_${newUser}"
                }
            }

            Write-Host ""
            Write-ColorMessage "Missing local accounts will be created with this password (cannot be blank)." "Warning"
            Write-ColorMessage "The password stays visible in the process command line while LoadState runs." "Warning"
            $restorePassSecure = Read-Host "Password for created local accounts" -AsSecureString
            $restorePass = ConvertFrom-SecureStringPlain $restorePassSecure
            if ([string]::IsNullOrWhiteSpace($restorePass)) {
                Write-ColorMessage "ERROR: Password cannot be blank. Restore cancelled." "Error"
                Pause
                break
            }
            $restorePassConfirmSecure = Read-Host "Confirm password" -AsSecureString
            $restorePassConfirm = ConvertFrom-SecureStringPlain $restorePassConfirmSecure
            if ($restorePass -cne $restorePassConfirm) {
                Write-ColorMessage "ERROR: Passwords do not match. Restore cancelled." "Error"
                Pause
                break
            }

            $tsRestore = Get-Date -Format yyyyMMdd_HHmmss
            $restoreLog = Join-Path $LogsDir "loadstate_$tsRestore.log"
            # Progress log, outside the store: records what /c skipped during the
            # restore, same as the scan side.
            $restoreProgress = Join-Path $LogsDir "loadstate_progress_$tsRestore.txt"
            Ensure-USMTWorkDir -JobName 'loadstate' | Out-Null
            $restoreArgs += '/c'
            $restoreArgs += '/v:5'
            $restoreArgs += "/l:$restoreLog"
            $restoreArgs += "/progress:$restoreProgress"
            $restoreArgs += "/lac:$restorePass"
            $restoreArgs += '/lae'

            Write-Host ""
            Write-ColorMessage "Starting USMT Restore..." "Info"
            Write-ColorMessage "This may take several minutes..." "Warning"
            Write-ColorMessage "Command: $LoadState $(($restoreArgs | ForEach-Object { if ($_ -match '/lac:') { '/lac:<hidden>' } else { $_ } }) -join ' ')" "Info"
            Write-Host ""

            $startTime = Get-Date
            try {
                & $LoadState @restoreArgs
                $code = $LASTEXITCODE
                $elapsed = (Get-Date) - $startTime
                Write-Host ""

                $kind = Report-USMTResult -Code $code -LogPath $restoreLog -Operation 'USMT Restore' -Minutes $elapsed.TotalMinutes

                if ($kind -eq 'failure') {
                    Write-ColorMessage "Common issues:" "Warning"
                    Write-Host "  - User accounts may not exist on this system" -ForegroundColor Yellow
                    Write-Host "  - Insufficient permissions (run as Administrator)" -ForegroundColor Yellow
                    Write-Host "  - Disk space issues" -ForegroundColor Yellow
                    Write-Host "  - Corrupted USMT store" -ForegroundColor Yellow
                    Write-Host "  - Store flags do not match the manifest (/nocompress, encryption)" -ForegroundColor Yellow
                    Write-Host ""

                    if (Confirm-Action "Would you like to view the log file?") {
                        Open-LogFile -LogPath $restoreLog
                    }
                    Pause
                    break
                }

                Write-ColorMessage "=== Post-Restore Instructions ===" "Info"
                Write-ColorMessage "1. Verify that user profiles are present" "Info"
                Write-ColorMessage "2. Check that user documents and settings were restored" "Info"
                Write-ColorMessage "3. Reboot to complete the restore process" "Warning"
                Write-ColorMessage "4. Test user logins after reboot" "Info"
                Write-Host ""

                if (Confirm-Action "Would you like to reboot now?") {
                    Restart-Computer -Force
                } else {
                    Write-ColorMessage "Reboot later and test the user logins." "Info"
                }
            } catch {
                Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
            } finally {
                $restorePass = $null
                $restorePassConfirm = $null
            }

            Pause
        }
        "12" {
            # Let user select from available stores
            $selectedStore = Select-USMTStore -BasePath $USMTPath
            if ($selectedStore) {
                Get-USMTStoreDetails -StorePath $selectedStore
                $manifest = Read-USMTManifest -StorePath $selectedStore

                # /verify only works on compressed stores.
                if (-not ($manifest -and $manifest.NoCompress)) {
                    if (Confirm-Action "Verify this store with usmtutils?") {
                        $keyFile = if ($manifest) { $manifest.KeyFile } else { '' }
                        Test-USMTStoreIntegrity -StorePath $selectedStore -KeyFilePath $keyFile
                    }
                }

                Remove-USMTStore -StorePath $selectedStore
            }
            Pause
        }
        "13" {
            Open-PrivateUrl -Url "https://prompt.nas86.eu"
            Pause
        }

        "14" {
            Open-PrivateUrl -Url "https://prompt.nas86.eu/technician/login"
            Pause
        }

        "15" {
            PlakarPrune
        }

        "16" {
            PlakarLocate
        }

        "17" { exit }

        default {
            Write-ColorMessage "Invalid option. Please choose 1-15." "Warning"
            Pause
        }
    }

    Rotate-Logs -Dir $LogsDir
} while ($true)
