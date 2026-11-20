#!/usr/bin/env python3
"""Reduced macOS host for web/index.html.

Standard library only. Serves the technician page on localhost and runs the
portable plakar actions. USMT, tooling sync and private-browser shortcuts are
Windows-only; the page hides those panels when /api/info reports platform="mac".
"""
import argparse
import gzip
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import tarfile
import threading
import urllib.request
import webbrowser
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(ROOT, "plakar_repo")
KEYFILE = os.path.join(ROOT, ".plakar_key")
LOGDIR = os.path.join(ROOT, "logs")
HEALTH = os.path.join(LOGDIR, "health.json")
PAGE = os.path.join(ROOT, "web", "index.html")
JUNK = ["Temp/", "Cache/", "INetCache/", "Thumbnails/", "Explorer/",
        "NuGet/", "npm-cache/", "pkg-npm-caches/", "*.tmp"]
MAX_LINES = 5000
MAX_LOG_MB = 10
KEEP_GZ = 5
JOBS = {}


def say(msg):
    print(msg, flush=True)


def plakar():
    p = os.path.join(ROOT, "plakar")
    if os.path.isfile(p) and os.access(p, os.X_OK):
        return p
    return shutil.which("plakar")


KNOWN_GOOD = os.path.join(ROOT, "_known_good")
VER_CACHE = {}
LATEST_CACHE = {}


def vtuple(s):
    nums = re.findall(r"\d+", s or "")
    return [int(n) for n in nums] or [0]


def plakar_version(exe):
    """Version of a binary, cached per file so page polling does not re-run it."""
    if not exe:
        return ""
    try:
        key = (exe, os.path.getmtime(exe))
    except OSError:
        return ""
    if key in VER_CACHE:
        return VER_CACHE[key]
    try:
        p = subprocess.run([exe, "version"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, encoding="utf-8", errors="replace", timeout=20)
        found = re.search(r"v\d+(\.\d+)*", p.stdout or "")
        ver = found.group(0) if found else ""
    except Exception:
        ver = ""
    VER_CACHE[key] = ver
    return ver


def latest_release(refresh=False, block=True):
    """Latest release tag, cached: a failed or slow lookup must never block the page."""
    if not refresh and "tag" in LATEST_CACHE:
        return LATEST_CACHE["tag"]
    if not block:
        return LATEST_CACHE.get("tag", "")
    tag = ""
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/PlakarKorp/plakar/releases/latest",
            headers={"User-Agent": "webui_mac"})
        with urllib.request.urlopen(req, timeout=15) as r:
            tag = str(json.loads(r.read().decode("utf-8")).get("tag_name") or "")
    except Exception:
        tag = ""
    LATEST_CACHE["tag"] = tag
    return tag


def release_target():
    """(os, arch) pair for the release asset plakar_<ver>_<os>_<arch>.tar.gz."""
    osname = {"darwin": "darwin", "linux": "linux"}.get(sys.platform, "")
    arch = {"x86_64": "amd64", "amd64": "amd64", "arm64": "arm64", "aarch64": "arm64"}.get(
        platform.machine().lower(), "")
    return osname, arch


def download_plakar(job, tag):
    """Install the release build as ./plakar, verified against the release checksums.

    A binary already sitting here is kept in _known_good, the same convention
    sync_tools.ps1 uses on a drive. A plakar found in PATH is never touched: this
    copy simply takes precedence.
    """
    osname, arch = release_target()
    if not osname or not arch:
        job.add("ERROR: no plakar release for %s %s. Copy a binary into %s yourself."
                % (sys.platform, platform.machine(), ROOT))
        return 1
    if not tag:
        job.add("ERROR: could not read the latest release from GitHub.")
        return 1
    ver = tag.lstrip("v")
    asset = "plakar_%s_%s_%s.tar.gz" % (ver, osname, arch)
    base = "https://github.com/PlakarKorp/plakar/releases/download/%s/" % tag
    tmp = tempfile.mkdtemp(prefix="plakar-update-")
    try:
        path = os.path.join(tmp, asset)
        job.add("Downloading %s ..." % asset)
        try:
            with urllib.request.urlopen(base + asset, timeout=300) as r, open(path, "wb") as f:
                shutil.copyfileobj(r, f)
        except Exception as exc:
            job.add("ERROR: download failed: %s" % exc)
            return 1
        try:
            with urllib.request.urlopen(base + "plakar_%s_checksums.txt" % ver, timeout=30) as r:
                sums = r.read().decode("utf-8", errors="replace")
        except Exception as exc:
            job.add("ERROR: checksums file not fetched (%s); refusing an unverified binary." % exc)
            return 1
        want = ""
        for line in sums.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == asset:
                want = parts[0].lower()
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
        got = digest.hexdigest()
        if not want or want != got:
            job.add("ERROR: SHA-256 mismatch for %s (expected %s, got %s). Nothing was installed."
                    % (asset, want or "not listed", got))
            return 1
        job.add("SHA-256 verified.")
        try:
            with tarfile.open(path, "r:gz") as t:
                names = [m for m in t.getmembers() if m.isfile() and os.path.basename(m.name) == "plakar"]
                if not names:
                    job.add("ERROR: no plakar binary inside %s." % asset)
                    return 1
                # Write the one member by hand: no tar path handling, works on any Python 3.
                with t.extractfile(names[0]) as src, open(os.path.join(tmp, "plakar"), "wb") as dst:
                    shutil.copyfileobj(src, dst)
        except Exception as exc:
            job.add("ERROR: could not unpack %s: %s" % (asset, exc))
            return 1
        found = os.path.join(tmp, "plakar")
        here = os.path.join(ROOT, "plakar")
        if os.path.isfile(here):
            try:
                os.makedirs(KNOWN_GOOD, exist_ok=True)
                shutil.copy2(here, os.path.join(KNOWN_GOOD, "plakar"))
                job.add("Previous copy kept in " + os.path.join(KNOWN_GOOD, "plakar"))
            except OSError as exc:
                job.add("WARNING: could not keep the previous binary: %s" % exc)
        shutil.move(found, here)
        os.chmod(here, 0o755)
        if shutil.which("xattr"):
            subprocess.run(["xattr", "-d", "com.apple.quarantine", here],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        VER_CACHE.clear()
        new = plakar_version(here)
        job.add("Installed %s (%s)" % (here, new or "version unknown"))
        LATEST_CACHE["tag"] = tag
        save_health("tool", dict(at=now(), version=new or tag, path=here))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def tool_info():
    exe = plakar()
    ver = plakar_version(exe)
    # Never block a page request on GitHub: the tag arrives from the lookup started
    # at launch, and the page re-reads /api/info while it is still empty.
    latest = latest_release(block=False)
    return dict(path=exe or "", version=ver, latest=latest,
                updateAvailable=bool(exe and ver and latest and vtuple(latest) > vtuple(ver)),
                fromUsb=bool(exe and exe == os.path.join(ROOT, "plakar")))


def keyargs():
    return ["-keyfile", KEYFILE] if os.path.isfile(KEYFILE) else []


def call(args):
    """Run plakar with empty stdin: a passphrase prompt must never hang the host."""
    exe = plakar()
    if not exe:
        return "", 127
    try:
        p = subprocess.run(
            [exe] + args, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", timeout=120)
        return p.stdout, p.returncode
    except Exception as exc:
        return str(exc) + "\n", 1


def ensure_repo():
    exe = plakar()
    if not exe:
        say("ERROR: plakar not found. Copy the macOS plakar binary next to this script.")
        return False
    # No agent: every job here is a plain `plakar at <repo> <cmd>` CLI call.
    # Starting one also hangs the host - the daemon inherits call()'s stdout
    # pipe and keeps it open, so subprocess.run waits for the agent to stop
    # (or for its 120 s timeout) before the page is served. plakar 1.1.8 has
    # no `agent` subcommand at all. menu.sh keeps its own agent handling.
    os.makedirs(LOGDIR, exist_ok=True)
    if not os.path.isfile(os.path.join(REPO, "CONFIG")):
        say("Creating repository at " + REPO)
        out, code = call(keyargs() + ["at", REPO, "create"])
        say(out.strip())
        if code != 0:
            return False
    return True


def rotate_logs():
    """Same rule as menu.sh: gzip logs over 10 MB, keep the newest 5 archives."""
    if not os.path.isdir(LOGDIR):
        return
    for name in os.listdir(LOGDIR):
        p = os.path.join(LOGDIR, name)
        if not name.endswith(".log") or not os.path.isfile(p):
            continue
        if os.path.getsize(p) <= MAX_LOG_MB * 1024 * 1024:
            continue
        try:
            with open(p, "rb") as src, gzip.open(p + ".gz", "wb") as dst:
                shutil.copyfileobj(src, dst)
            os.remove(p)
        except OSError:
            pass
    gz = sorted((os.path.join(LOGDIR, n) for n in os.listdir(LOGDIR)
                 if n.endswith(".log.gz")), key=os.path.getmtime, reverse=True)
    for p in gz[KEEP_GZ:]:
        try:
            os.remove(p)
        except OSError:
            pass


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def save_health(kind, data):
    os.makedirs(LOGDIR, exist_ok=True)
    obj = {}
    if os.path.isfile(HEALTH):
        try:
            with open(HEALTH, encoding="utf-8") as f:
                obj = json.load(f)
        except Exception:
            obj = {}
    obj[kind] = data
    with open(HEALTH, "w", encoding="utf-8") as f:
        json.dump(obj, f)


def maintenance_counts(lines):
    coloured = orphaned = blobs = packs = 0
    for line in lines:
        m = re.search(r"Coloured (\d+) packfiles \((\d+) orphaned\)", line)
        if m:
            coloured, orphaned = int(m.group(1)), int(m.group(2))
        m = re.search(r"(\d+) blobs and (\d+) packfiles were removed", line)
        if m:
            blobs, packs = int(m.group(1)), int(m.group(2))
    return dict(coloured=coloured, orphaned=orphaned,
                removedBlobs=blobs, removedPackfiles=packs)


def parse_snaps(raw):
    snaps, tags = [], []
    pat = re.compile(r"^(\S+)\s+(\S+)\s+(.+?)\s+(\S+)\s+(\S+)\s+tags=(.*)$")
    for line in raw.splitlines():
        if not line.strip():
            continue
        m = pat.match(line)
        if not m:
            continue
        st = [t.strip() for t in m.group(6).split(",") if t.strip()]
        snaps.append(dict(date=m.group(1), hash=m.group(2), size=m.group(3),
                          path=m.group(5), tags=st))
        for t in st:
            if t not in tags:
                tags.append(t)
    return snaps, tags


def repo_size():
    total = 0
    for root, dirs, files in os.walk(REPO):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return round(total / 1024 ** 3, 2)


def health_info():
    h = dict(lockFileCount=0, lockStale=False, livePlakarPids=[],
             packfileCount=0, packfileMB=0, leftoverTmpPackfiles=0,
             lastMaintenance=None, lastCheck=None)
    locks = os.path.join(REPO, "locks")
    if os.path.isdir(locks):
        h["lockFileCount"] = len([f for f in os.listdir(locks)
                                  if os.path.isfile(os.path.join(locks, f))])
    try:
        out = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True,
                                      stderr=subprocess.DEVNULL)
        h["livePlakarPids"] = [int(l.split()[0]) for l in out.splitlines()
                                if "/plakar" in l]
    except Exception:
        pass
    h["lockStale"] = h["lockFileCount"] > 0 and not h["livePlakarPids"]
    packs = os.path.join(REPO, "packfiles")
    sizes = []
    tmp = 0
    if os.path.isdir(packs):
        for root, dirs, files in os.walk(packs):
            for f in files:
                tmp += 1 if f.startswith("tmp.") else 0
                try:
                    sizes.append(os.path.getsize(os.path.join(root, f)))
                except OSError:
                    pass
    h["packfileCount"] = len(sizes)
    h["packfileMB"] = round(sum(sizes) / 1024 ** 2, 2)
    h["leftoverTmpPackfiles"] = tmp
    if os.path.isfile(HEALTH):
        try:
            with open(HEALTH, encoding="utf-8") as f:
                obj = json.load(f)
            h["lastMaintenance"] = obj.get("maintenance")
            h["lastCheck"] = obj.get("check")
        except Exception:
            pass
    return h


def users():
    out = []
    base = "/Users"
    skip = {"Shared", "Guest", ".localized"}
    if os.path.isdir(base):
        for name in sorted(os.listdir(base)):
            if name in skip or name.startswith("."):
                continue
            path = os.path.join(base, name)
            if os.path.isdir(path):
                out.append(dict(name=name, path=path, full=name))
    return out


class Job:
    def __init__(self, action, label, payload):
        self.id = os.urandom(4).hex()
        self.action = action
        self.label = label
        self.payload = payload
        self.status = "running"
        self.exit_code = None
        self.started = datetime.now()
        self.lines = deque(maxlen=MAX_LINES)
        self.log = os.path.join(LOGDIR, self.id + "_" + action + ".log")
        self.lock = threading.Lock()
        JOBS[self.id] = self
        try:
            open(self.log, "w", encoding="utf-8").close()
        except OSError:
            pass

    def add(self, line):
        line = line.rstrip("\r\n")
        with self.lock:
            self.lines.append(line)
            try:
                with open(self.log, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def view(self):
        with self.lock:
            lines = list(self.lines)
            elapsed = int((datetime.now() - self.started).total_seconds())
            return dict(
                id=self.id, label=self.label, status=self.status,
                exitCode=self.exit_code,
                started=self.started.strftime("%Y-%m-%d %H:%M:%S"),
                elapsed=str(elapsed) + "s", lineCount=len(lines),
                lastLine=lines[-1] if lines else "", output=lines[-200:],
                logFile=self.log)


def stream(job, args):
    exe = plakar()
    if not exe:
        job.add("ERROR: plakar not found")
        return 127
    job.add("Command: " + " ".join([exe] + args))
    p = subprocess.Popen(
        [exe] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    for line in p.stdout:
        job.add(line)
    return p.wait()


def dispatch(job):
    action, p, ka = job.action, job.payload, keyargs()
    if action == "plakar_backup":
        folder = str(p.get("folder") or "").strip()
        if not folder or not os.path.isdir(folder):
            job.add("ERROR: folder not found: " + folder)
            return 1
        name = str(p.get("tag") or "backup").strip()
        tag = name + "_" + datetime.now().strftime("%Y%m%d_%H%M%S")
        argv = ka + ["at", REPO, "backup"]
        if p.get("excludeJunk"):
            for pat in JUNK:
                argv += ["-ignore", pat]
            job.add("Excluding junk: " + ", ".join(JUNK))
        argv += ["-name", name, "-environment", socket.gethostname(),
                 "-category", "profile", "-tag", tag, folder]
        job.add("Backing up %s as %s ..." % (folder, tag))
        code = stream(job, argv)
        skipped = [l for l in job.lines if l.lstrip().startswith("KO ")]
        if skipped:
            sf = os.path.join(LOGDIR, "skipped_" + tag + ".txt")
            try:
                with open(sf, "w", encoding="utf-8") as f:
                    f.write("\n".join(skipped) + "\n")
                job.add("SKIPPED: %d entries could not be read" % len(skipped))
                job.add("Skipped paths written to: " + sf)
            except OSError:
                pass
        return code
    if action == "plakar_restore":
        tag = str(p.get("tag") or "").strip()
        to = str(p.get("to") or "").strip()
        if not tag or not to:
            job.add("ERROR: tag and destination are required")
            return 1
        os.makedirs(to, exist_ok=True)
        return stream(job, ka + ["at", REPO, "restore", "-tag", tag,
                                 "-to", to, "-o", "skip_permissions=1"])
    if action == "plakar_list":
        return stream(job, ka + ["-quiet", "at", REPO, "ls", "-tags"])
    if action == "plakar_check":
        code = stream(job, ka + ["at", REPO, "check"])
        flagged = sum(1 for l in job.lines
                      if re.search(r"ERROR|error:|corrupt|missing|failed|flagged", l))
        save_health("check", dict(at=now(), exitCode=code, flagged=flagged))
        return code
    if action == "plakar_maintenance":
        code = stream(job, ka + ["at", REPO, "maintenance"])
        save_health("maintenance", dict(at=now(), exitCode=code,
                                        **maintenance_counts(job.lines)))
        return code
    if action == "plakar_prune":
        days = int(p.get("days") or 30)
        cap = int(p.get("perDay") or 1)
        argv = ka + ["at", REPO, "prune", "-days", str(days),
                     "-per-day", str(cap), "-group-by", "name"]
        if p.get("category"):
            argv += ["-category", str(p["category"])]
        code = stream(job, argv)
        if code == 0 and p.get("apply"):
            code = stream(job, argv + ["-apply"])
        return code
    if action == "plakar_locate":
        pat = str(p.get("pattern") or "").strip()
        if not pat:
            job.add("ERROR: pattern cannot be empty")
            return 1
        code = stream(job, ka + ["at", REPO, "locate", pat])
        hits = sum(1 for l in job.lines if re.match(r"^[0-9a-f]{8}:/", l))
        job.add("%d match(es). To read one: plakar at <repo> cat <snapshotID>:<path>" % hits)
        return code
    if action == "plakar_delete":
        tag = str(p.get("tag") or "").strip()
        if not tag:
            job.add("ERROR: tag cannot be empty")
            return 1
        code = stream(job, ka + ["at", REPO, "rm", "-tag", tag, "-apply"])
        if code == 0 and p.get("maintenance"):
            job.add("Running maintenance to reclaim space ...")
            code = stream(job, ka + ["at", REPO, "maintenance"])
            save_health("maintenance", dict(at=now(), exitCode=code,
                                            **maintenance_counts(job.lines)))
        return code
    if action == "plakar_ui":
        exe = plakar()
        if not exe:
            job.add("ERROR: plakar not found")
            return 1
        subprocess.Popen([exe] + ka + ["at", REPO, "ui"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        job.add("Plakar UI started.")
        return 0
    if action == "plakar_update":
        tag = latest_release(refresh=True)
        if not tag:
            job.add("ERROR: GitHub not reachable, nothing to compare with.")
            return 1
        here = plakar()
        job.add("Current: %s (%s) - latest release %s"
                % (here or "none", plakar_version(here) or "unknown", tag))
        if here == os.path.join(ROOT, "plakar") and plakar_version(here) == tag:
            job.add("Already the latest release. Nothing to do.")
            return 0
        return download_plakar(job, tag)
    job.add("ERROR: action '%s' is Windows-only in this template." % action)
    return 1


def run_job(job):
    try:
        code = dispatch(job)
    except Exception as exc:
        job.add("ERROR: " + str(exc))
        code = 1
    job.exit_code = code
    job.status = "completed" if code == 0 else ("partial" if code == 3 else "failed")
    rotate_logs()


def info():
    raw_info, code = call(keyargs() + ["-quiet", "at", REPO, "info"])
    raw_ls, _ = call(keyargs() + ["-quiet", "at", REPO, "ls", "-tags"])
    count, logical = 0, 0.0
    m = re.search(r"Snapshots:\s+(\d+)", raw_info)
    if m:
        count = int(m.group(1))
    m = re.search(r"Logical size:.*\((\d+) bytes\)", raw_info)
    if m:
        logical = round(int(m.group(1)) / 1024 ** 3, 2)
    snaps, tags = parse_snaps(raw_ls)
    key_status = ("ok (keyfile present)" if os.path.isfile(KEYFILE)
                  else "no passphrase (unencrypted)")
    return dict(
        repo=REPO, usbDrive=os.path.splitdrive(ROOT)[0] or "/",
        usmtPath="Windows only", scanstateFound=False,
        keyStatus=key_status, isAdmin=False, platform="mac",
        junkPatterns=JUNK,
        repoInfo=dict(snapshotCount=count, sizeGB=repo_size(),
                      logicalGB=logical, keyOk=(code == 0),
                      raw=raw_ls.strip(), tags=tags, snapshots=snaps),
        health=health_info(), stores=[], users=users(), tooling=None,
        tool=tool_info(),
        jobs=[j.view() for j in JOBS.values()])


class Handler(BaseHTTPRequestHandler):
    def reply(self, obj, status=200, ctype="application/json; charset=utf-8"):
        data = obj if isinstance(obj, bytes) else json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        try:
            if path in ("/", "/index.html"):
                with open(PAGE, "rb") as f:
                    self.reply(f.read(), ctype="text/html; charset=utf-8")
            elif path == "/api/info":
                self.reply(info())
            elif path == "/api/jobs":
                self.reply([j.view() for j in JOBS.values()])
            else:
                self.reply(dict(error="not found"), 404)
        except Exception as exc:
            self.reply(dict(error=str(exc)), 500)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            if self.path == "/api/run":
                action = str(body.get("action") or "")
                job = Job(action, body.get("label") or action, body)
                threading.Thread(target=run_job, args=(job,), daemon=True).start()
                self.reply(dict(id=job.id, status="running"))
            elif self.path == "/api/key":
                pw = str(body.get("passphrase") or "")
                if not pw:
                    if os.path.isfile(KEYFILE):
                        os.remove(KEYFILE)
                    self.reply(dict(message="Keyfile removed."))
                else:
                    with open(KEYFILE, "w", encoding="utf-8") as f:
                        f.write(pw + "\n")
                    _, code = call(keyargs() + ["-quiet", "at", REPO, "info"])
                    self.reply(dict(message=(
                        "Saved; repository unlocks." if code == 0 else
                        "Saved, but the passphrase did not unlock this repository.")))
            else:
                self.reply(dict(error="not found"), 404)
        except Exception as exc:
            self.reply(dict(error=str(exc)), 500)

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description="Reduced macOS web host for the technician page")
    ap.add_argument("-p", "--port", type=int, default=8118)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    if not plakar():
        say("WARNING: plakar not found; copy the macOS binary next to this script.")
    threading.Thread(target=latest_release, kwargs=dict(refresh=True), daemon=True).start()
    t = tool_info()
    if t["path"]:
        say("plakar %s at %s%s" % (t["version"] or "unknown", t["path"],
                                   "" if t["fromUsb"] else " (from PATH; a release build here would take precedence)"))
    if not ensure_repo():
        say("WARNING: repository is not ready; the page will still load.")
    url = "http://127.0.0.1:%d/" % args.port
    if not args.no_browser:
        try:
            subprocess.run(["open", "-na", "Google Chrome", "--args", "--incognito", url],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            try:
                webbrowser.open(url)
            except Exception:
                pass
    say("Serving %s on %s (Ctrl+C to stop)" % (PAGE, url))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        say("Stopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
