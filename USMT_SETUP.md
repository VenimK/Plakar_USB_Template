# USMT Setup Guide

## Quick Start

The tool detects the architecture of the machine it runs on and picks the matching
USMT binaries (`amd64`, then `ARM64`, then `x86`).

## Getting USMT Files

### Step 1: Download Windows ADK

Download the Windows Assessment and Deployment Kit (ADK):

- **Direct link**: https://go.microsoft.com/fwlink/?linkid=2243390
- **Alternative**: Search for "Windows ADK" on Microsoft's website

Take the ADK build that matches the Windows build you are scanning from (the USMT
component is versioned per Windows release, and a store written by a newer USMT
cannot always be read by an older LoadState).

### Step 2: Install the USMT component only

1. Run the ADK installer
2. **UNCHECK** all components except:
   - ✅ **User State Migration Tool (USMT)**
3. Complete the installation

### Step 3: Copy USMT files to the USB

**64-bit (most common):**

```
From: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\USMT\amd64\
To:   [USB_DRIVE]\USMT\amd64\
```

**32-bit (legacy):**

```
From: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\USMT\x86\
To:   [USB_DRIVE]\USMT\x86\
```

**Pro tip:** copy both architectures to support every machine:

```
[USB_DRIVE]\
├── menu.ps1
├── plakar.exe
├── logs\                  # per-job logs, kept outside the store
├── work\                  # USMT working dir, kept outside the store
├── migmodern.xml          # optional modern rules (see below)
└── USMT\
    ├── amd64\
    │   ├── scanstate.exe
    │   ├── loadstate.exe
    │   ├── usmtutils.exe
    │   ├── miguser.xml
    │   ├── migapp.xml
    │   ├── migdocs.xml
    │   └── migmodern.xml
    └── x86\
        ├── scanstate.exe
        ├── loadstate.exe
        ├── usmtutils.exe
        ├── miguser.xml
        ├── migapp.xml
        ├── migdocs.xml
        └── migmodern.xml
```

## Supported architectures

- ✅ **AMD64 / x86_64** — most modern systems
- ✅ **x86** — legacy 32-bit systems
- ⚠️ **ARM64** — USMT has no ARM64 binaries; on ARM64 Windows the x86 tools run
  through emulation. `menu.ps1` and `webserver.ps1` look for `amd64`, then
  `ARM64`, then `x86`, and fall back to the x86 folder on ARM64.

## Store placement, logs, and the working directory

- The store volume must be **NTFS**. A FAT32/exFAT store volume fails with return
  code 27, and FAT32 cannot hold the single files over 4 GB that a compressed store
  can produce.
- `-v` / `-l` / `-progress` files cannot live inside the store path (return code
  13). Both hosts write them to `logs\`, and the USMT working directory to `work\`,
  so nothing inside the store is ever touched by the tool itself.
- ScanState and LoadState are run with `/progress:<file>` in `logs\`. The Web UI
  tails that file and the `/l:` log while the tool is running, so the Activity panel
  shows live activity during a long scan instead of only the final summary; if a run
  goes quiet for 30 s it prints a `STILL RUNNING` line so a slow phase (a large file,
  a locked profile) is not mistaken for a hang. `menu.ps1` prints the tool's own
  console output directly, so it does not need the tail.
- `/localonly` is on by default: it stops ScanState from walking drives the OS reports
  as Removable or Network. It does **not** cover a USB drive that Windows presents as
  Fixed media, and that is how this tool's own drive is reported here, so both hosts also
  generate a per-run `exclude_usb.xml` in the USMT working directory holding an
  `<unconditionalExclude>` for that drive's root. The letter changes with every PC, so the
  rule is generated at run time instead of shipped as a static XML, and the excluded drive
  is recorded in `store_manifest.json`. The rule changes only what ScanState reads: USMT
  already excludes StorePath from the scan, so a store written on the USB drive is still
  written normally. The offline scan skips the rule when the offline Windows folder is on
  the same drive the tool runs from.
- OneDrive Files On-Demand placeholders are enumerated as files. Materialise them
  first, or exclude the OneDrive tree in `migmodern.xml`, otherwise the store fills
  with placeholder metadata instead of content.

## migmodern.xml (optional, additive)

`MigModern.xml` is shipped alongside the stock ADK XMLs and is loaded automatically
when present:

- a catch-all rule for every file inside each user profile — the stock `MigUser.xml`
  only knows shell folders and a fixed list of document extensions;
- an `<unconditionalExclude>` block that drops cache-only trees (browser caches,
  Windows shell/history/search spool, temp, crash dumps, package caches), so the
  store stays small without losing settings.

It is additive: the stock XMLs are unchanged. Delete the file to get the original
behaviour back. Note that `<unconditionalExclude>` applies to every XML loaded in
the same run, including `MigUser.xml` and `MigApp.xml`.

## Run from WinPE (offline scan)

Offline scanning works best from WinPE, where the source Windows installation is
not running. Boot WinPE from ADK (`setuppe.bat` or the ADK environment), mount the
USB, and run:

```
scanstate X:\store /i:miguser.xml /i:migmodern.xml /offline:C:\Windows /mapping:C:,X: /v:4 /l:X:\logs\scan.log
```

In `menu.ps1` / `webserver.ps1` the same thing is option 10 / `usmt_offline`: the
offline Windows folder is the source, and the store stays on the USB. LoadState
cannot run inside WinPE — run it on the booted destination system, then reboot.

## Exit codes

Both hosts report the raw USMT code plus the text below. Code 3 is treated as a
partial success (job status `partial`), not a failure.

| Code | Meaning |
|---|---|
| 0 | SUCCESS |
| 1 | HELP — wrong syntax |
| 2 | CANCELED (EFS abort, or Ctrl+C) |
| 3 | WOULD_HAVE_FAILED — objects were skipped because of `/c`; partial success |
| 11 | INVALID_PARAMETERS |
| 12 | Path too long (the hosts report this before running) |
| 13 | INIT_LOGFILE_FAILED — log file inside the store path |
| 26 | INVALID_MAP |
| 27 | INVALID_STORE_LOCATION — store on the system drive, or not on NTFS |
| 28 | INVALID_XML |
| 29 | INVALID_WORKING_DIR — also returned when the USMT gate is busy |
| 34 | INVALID_RIGHTS |
| 36 | INVALID_PLATFORM |
| 42 | INVALID_STORE |
| 61 | NON_FATAL_STOP |
| 72 | FATAL_STOP |

## Option flags worth knowing

- `/efs:abort|skip|decryptcopy|copyraw` — the default is `abort`, which ends the run
  with code 2 on the first EFS-encrypted file. Both hosts default to `skip` so a
  single encrypted file does not stop the whole scan.
- `/nocompress` (`/n`) is for testing only: the store is a hard-link mirror, it must
  be decrypted with `usmtutils /decrypt` before LoadState, and LoadState must be
  given the same option. It cannot be combined with `/encrypt` or `/hardlink`.
  Both hosts record the choice in `store_manifest.json` so LoadState matches it.
- `/encrypt /keyfile:` — the key file path is recorded in the manifest; LoadState
  then uses `/decrypt /keyfile:` automatically. A password given on the command line
  (`/lac:`) stays visible in the process command line, so prefer a key file.
- `/mu:OldDomain_OldUserName:NewDomain_NewUserName` and `/md:` are LoadState-only.
- `/uel` is not valid for offline scans, and `/all` conflicts with `/ui`.
- `usmtutils` is used for store work: `/rd <store> /y` to delete, and
  `/verify:summary <store> /v:4 /l:<log>` to check integrity. `/verify` only works on
  compressed stores, not on a `/nocompress` hard-link mirror.

## Store manifest

Each scan writes `store_manifest.json` inside the store: tool, store name, created
time, users, XML set, source, compression, encryption, key file, EFS mode, and exit
code. `Get-USMTStoreDetails` / `store_details` prints it, and LoadState reads it so
that a store scanned with `/nocompress` or `/encrypt` is restored with the matching
flags.

## Troubleshooting

### "USMT files not found" error

1. Ensure files are in the correct architecture folder (`amd64` or `x86`)
2. Check that `scanstate.exe` and `loadstate.exe` are present
3. Verify XML files (`miguser.xml`, `migapp.xml`, `migdocs.xml`, `migmodern.xml`)
   are included — the hosts look them up by lowercase name
4. `usmtutils.exe` is needed for the verify and delete options

### Architecture detection

- 64-bit Windows → `USMT\amd64\`
- 32-bit Windows → `USMT\x86\`
- ARM64 Windows → `USMT\ARM64\` if present, otherwise the x86 tools

### Multiple locations supported

The hosts search in this order:

1. `[ScriptDir]\USMT\[arch]\`
2. `[ScriptDir]\USMT\X64\` (legacy compatibility)
3. `[DriveLetter]:\USMT\[arch]\`

XML files are accepted in the USMT folder or in the template root, preferring the
USMT folder.

## File size reference

Each architecture folder is approximately:

- **amd64**: 25–30 MB
- **x86**: 20–25 MB
- **both**: 50–55 MB total

## Legal note

USMT is part of the Windows Assessment and Deployment Kit (ADK) and is provided by
Microsoft. Ensure you comply with Microsoft's licensing terms when using USMT.
