# Web (HTML) version of the technician menu

**Can a plain HTML page do this?** No. A browser page cannot run `plakar.exe`,
`scanstate.exe` or `loadstate.exe`, cannot elevate to Administrator, cannot read
`C:\Users`, cannot touch offline registry hives, and cannot reboot. So the HTML
page is only the *view*; a local host process still does the work.

This is the hybrid: `webserver.ps1` serves `web/index.html` on
`http://localhost:8765` and executes the tools on the machine.

## Run it

Double-click `webui.bat`, or in an elevated PowerShell:

```powershell
.\webserver.ps1                # http://localhost:8765
.\webserver.ps1 -Port 8080     # different port
.\webserver.ps1 -NoBrowser     # do not auto-open a private browser window
```

It self-elevates the same way `menu.ps1` does, then opens Edge InPrivate
(or Chrome Incognito) on the page. Press Ctrl+C in the PowerShell window to stop.

## What the page covers

| menu.ps1 option | page |
|---|---|
| 1 / 2 backup | Backup panel (profile chips + folder + tag) |
| 3 restore | Restore panel (tag dropdown + destination) |
| 4 / 5 list snapshots | Snapshot list + raw output |
| 6 Plakar UI | button — Plakar's own browser UI |
| 7 delete | Delete button (with confirm) |
| 8 maintenance | Maintenance button |
| 9 USMT ScanState | user chips + Run |
| 10 USMT offline ScanState | offline Windows folder + Run |
| 11 USMT LoadState | store dropdown + password + Run |
| 12 store details | Store details button + store table |
| 13 / 14 private browser | shortcut buttons |
| — | Tooling panel (per-drive check + sync) |

Actions the page can send to `POST /api/run`:
`plakar_backup`, `plakar_restore`, `plakar_list`, `plakar_check`,
`plakar_maintenance`, `plakar_prune`, `plakar_locate`, `plakar_delete`, `plakar_ui`,
`usmt_scan`, `usmt_offline`, `usmt_restore`, `usmt_check`, `store_details`,
`open_private_url`, `tool_update_check`, `tool_sync`.

## USMT flags on the page

The ScanState panel exposes the switches that used to be hardcoded:

| field | switch | note |
|---|---|---|
| EFS-encrypted files | `/efs:<mode>` | default `skip`; `abort` (the USMT default) ends the run on the first encrypted file |
| Local drives only | `/localonly` | on by default — covers only drives the OS reports as Removable or Network |
| Exclude the drive the tool runs from | generated `exclude_usb.xml` | on by default — the USB drive is reported as Fixed, so `/localonly` does not cover it; the rule is written per run because the letter changes per PC, and the store can still be written to that drive |
| No compression | `/nocompress` | testing only; LoadState must use the same setting, so the choice is recorded in `store_manifest.json` |
| Keyfile | `/encrypt /keyfile:` | leave empty for an unencrypted store |

LoadState adds:

- `userMap` — optional `/mu:OldDomain_OldUser:NewDomain_NewUser` (LoadState only);
- `Verify store (usmtutils)` — runs `usmtutils /verify:summary` on the selected
  store. Works on compressed stores only, so a `/nocompress` store reports it as
  not verifiable.

The store table gained a **Flags / users** column built from the manifest: users,
source, tool, `nocompress`, `encrypted`, EFS mode, and the exit code of the scan
that created the store.

## Tooling panel

`tool_update_check` (read-only) asks GitHub for the latest plakar release, compares it
with the tool in the template root, and reports for every drive: the tool on that drive,
the version that wrote its repository, whether the tooling differs, and which files the
drive edited itself. `tool_sync` runs `sync_tools.ps1` on the host with the flags the
panel sets (dry run, binaries, key, force, restore, check first). The panel keeps the
same rules as the command line, because the same script does the work: data folders are
never copied, a file the drive edited itself is skipped unless -Force, a tool older than
the version that wrote that drive's repository is refused, and the previous copy is kept
in `_known_good\`. It needs no elevation — it only copies files — and the check needs
network only when it is asked for.

The last check result is kept as `tooling` in `/api/info`, so the table shows it until a
new check runs. `sync_tools.ps1` answers as one JSON object when called with `-Json`,
which is what the host reads; the raw JSON stays in the job log.

## Statuses

A job ends as `completed`, `partial`, `failed`, `stopped`, or `gone`. USMT return
code 3 (`WOULD_HAVE_FAILED`, objects skipped because of `/c`) is reported as
`partial` and shown with a warning badge: the store is usable, but some objects were
skipped. Both hosts also echo the exact command line they ran, with `/lac:<password>`
masked in the echo only — the password is still visible in the process command line,
so a keyfile is the safer choice.

USMT jobs are serialised through a named mutex (`PlakarUSB-USMT-Gate`): the run-space
pool allows four jobs at a time, but only one ScanState/LoadState/usmtutils may run at
once, so a second USMT job waits up to 120 s and then fails with code 29.

Logs go to `logs\<jobid>_<action>.log` and USMT scratch space to `work\`; both stay
outside the store, because a log or working directory inside StorePath is rejected by
ScanState (return code 13).

Everything runs as a background job; the Activity panel shows live output and the
exit code. Each job also writes its own log file in `logs/`
(`<jobid>_<action>.log`), and the path is shown in the job card.

### How the Activity panel stays live during a busy USMT run

The panel polls `/api/jobs` every second, so the lines have to be produced as they
happen:

- `RunTool` reads stdout and stderr line by line with `ReadLineAsync` instead of
  reading to EOF. Reading to EOF is what made a busy ScanState look empty: nothing
  appeared until the tool exited.
- ScanState and LoadState are given `/progress:<file>` in `logs\`, and `RunTool`
  tails that file plus the `/l:` log every 250 ms, adding each newly written line to
  the job. USMT writes those files in the OEM code page, so the tail decodes with the
  OEM encoding (UTF-8 and UTF-16 BOMs are detected per file), and only complete lines
  are forwarded. The progress file path is shown in the job card.
- If nothing new arrives for 30 s the job prints `STILL RUNNING: <tool> is working`,
  so a slow phase (one large file, a locked profile, a retry) is not mistaken for a
  hang.
- The in-memory view is capped at 5000 lines per job; the job log file still keeps
  everything. `/api/jobs` returns the last 200 lines and the panel shows the last 80.

`menu.ps1` does not need a tail: it runs the tools in the foreground and their own
console output is already visible.

## Notes

- Snapshot count and logical size come from `plakar info`; the snapshot table is
  parsed from `plakar ls -tags` (`date  hash  size  duration  path  tags=...`).
  Clicking a row in the snapshot table selects that tag in the Restore panel.
- Tags with commas are split into separate tags in the dropdown.
- Job output is read as UTF-8, so plakar's `OK ✓` and accented filenames are not
  mangled in the Activity panel or in the log files.
- Maintenance needs the exclusive repository lock. If a Plakar UI window, a mount,
  or a `plakar` process left over from an earlier run is holding it, Maintenance
  fails with exit 1 and the Activity panel prints a hint naming the cause. Close
  that process and run Maintenance again — deleting a snapshot works, but the space
  is only reclaimed once Maintenance succeeds.
- The hint tells the two cases apart: a live plakar process holding the lock (PID
  shown, and never the process the job itself started), or a stale lock file left by
  a plakar that died mid-run, which can be deleted after copying it aside.
- Maintenance does not free space straight away: it *colours* packfiles and removes
  them on a later run after a 7-day grace period. Data still referenced by plakar's
  internal state records counts as in use, so a repository can show a large Storage
  size with `Snapshots: 0` until those records age out.

## What stays the same

- `.plakar_key` handling (encoding variants are tested against the repository; the
  Passphrase panel saves and test-unlocks).
- Offline guard: refuses the currently booted Windows folder.
- `USMT_WORKING_DIR` is set to `work\` for every USMT job (the usual fix for return
  code 29), and it stays outside the store.
- LoadState still needs a non-blank password for created accounts. The page does not
  reboot by itself; it prints a reminder. `menu.ps1` reboots only after you confirm.
- Before LoadState, `menu.ps1` takes a Plakar snapshot of `C:\Users`
  (`PreRestore_<timestamp>`) so a wrong restore can be undone.

## macOS (reduced host)

`webui.sh` starts `webui_mac.py`, a Python 3 standard-library host bound to
`http://127.0.0.1:8765`. It serves the same `web/index.html`; the page detects
`platform: "mac"` from `/api/info` and hides the tooling, USMT and shortcut panels.
Backup, restore, list, check, maintenance, prune, locate, delete and Plakar's own UI
use the same `plakar` binary and CLI as `menu.sh`. Each job logs to
`logs/<jobid>_<action>.log`, KO paths go to `logs/skipped_<tag>.txt`, and logs rotate
at 10 MB with 5 archives kept — the same rules as the other two hosts.

```bash
./webui.sh                 # opens Chrome Incognito, or the default browser
./webui.sh -p 8080         # different port
./webui.sh --no-browser    # only start the listener
```

Python 3 is the only extra requirement, and the macOS Command Line Tools that Git
needs already provide it. Nothing is installed and the listener binds to `127.0.0.1`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on the target PC — unavoidable, because
  USMT and elevation are native operations.
- `webserver.ps1` and `web/index.html` must stay together on the USB.
- Nothing is installed; the listener binds only to `localhost`.
