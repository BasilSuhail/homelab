#!/usr/bin/env python3
"""What was happening on the PC at one moment, for "it stuttered at 1h10" or
"my upload stopped at 23 GB at 12:15".

Two halves. Every minute `pi-when record` writes one line of readings to
/var/lib/pi-when/<day>.jsonl on the OS drive, kept for 14 days: CPU, memory,
the GPU and its video engines, how busy each drive was, Wi-Fi speed and
signal, pings to the router and the internet, temperatures, fans, and every
app's restart count. The lookup puts everything around a moment on one page:

  sudo pi-when 12:15 nextcloud
  sudo pi-when "yesterday 21:40" jellyfin --who <name>
  sudo pi-when "sat 12:15" --minutes 20

  who was using the app, how (direct or relay) and how fast   (pi-paths)
  what stands out: busy drives, Wi-Fi or internet drops, restarts, memory kills
  the PC minute by minute
  the app's own log: Jellyfin's playback and transcode lines (with the film
  position, and whether transcoding kept up), Nextcloud's errors and upload
  requests minute by minute, or any other app's error lines
  kernel warnings and Wi-Fi messages

Nobody has to be watching: every minute the recorder also checks for
trouble (a restart, a memory kill, a disk error, Wi-Fi or internet lost, a
drive flat out for 3 minutes, the PC missing readings, a family device on a
slow relay, Jellyfin errors, Nextcloud requests failing). When it finds some it
waits 10 minutes, then saves this page, before and after, to
/var/lib/pi-when/incidents/<day>_<time>.txt (kept 60 days). Trouble in those
10 minutes goes in the same file; the same trouble repeating is noted at most
once every 30 minutes.

  sudo pi-when incidents   what was saved, newest last
  sudo pi-when status      right now, in a few lines: what the Discord bot
                           answers to "status" (deploy/pi-bot.py)
  sudo pi-when content     writes /run/pi-status/status.json for the
                           dashboard's Status tab (pi-status.timer, 30 s)

Any time `date -d` understands works; a bare HH:MM later than now means
yesterday. Jellyfin keeps its own log for 3 days and an app's console log
lasts until its second restart, so ask within a few days. Stdlib only;
changes nothing.
"""

import argparse
import datetime
import glob
import json
import os
import re
import shlex
import shutil
import socket
import sqlite3
import struct
import subprocess
import sys
import time
import urllib.request

DIR = os.environ.get("WHEN_DIR", "/var/lib/pi-when")
STATE = os.environ.get("WHEN_STATE", "/run/pi-when.json")
KEEP_DAYS = 14
KUBECTL = ["k3s", "kubectl"]
NS = "pi"
DAY = 24 * 3600
MOUNTS = {"/": "os", "/srv/ssd": "ssd", "/srv/storage": "hdd1", "/srv/hdd2": "hdd2"}
INTERNET = "1.1.1.1"
INCIDENTS = os.path.join(DIR, "incidents")
OPEN = os.path.join(INCIDENTS, "open.json")
KEEP_INCIDENT_DAYS = 60
SETTLE = 600       # wait this long after trouble starts, to capture the "after"
MERGE = 1800       # trouble this soon after the first goes in the same file
FANS_STATE = "/run/pi-fans.json"
# The same words the morning report treats as an error.
POD_ERROR = re.compile(r"\b(ERR|ERROR|FATAL|CRIT|CRITICAL|PANIC|panic|Exception|Traceback)\b")
DISK_TROUBLE = re.compile(r"I/O error|EXT4-fs error|Buffer I/O|critical medium error|failed command: (READ|WRITE)|"
                          r"Remounting filesystem read-only|blk_update_request", re.I)
WIFI = re.compile(r"disconnect|deauth|associat|state change|beacon|roam|CTRL-EVENT", re.I)
OOM = re.compile(r"Out of memory|oom-kill|Killed process", re.I)
LINES = 60


def sh(args, timeout=30):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


# ---------------------------------------------------------------- recording

def drive_names():
    """{'sda': 'hdd1', ...}: each whole disk named after what it holds."""
    names = {}
    for line in (read("/proc/mounts") or "").splitlines():
        dev, mnt = line.split()[:2]
        if mnt not in MOUNTS or not dev.startswith("/dev/"):
            continue
        part = os.path.basename(os.path.realpath(dev))
        parent = os.path.basename(os.path.dirname(os.path.realpath("/sys/class/block/" + part)))
        names[part if parent == "block" else parent] = MOUNTS[mnt]
    return names


def cpu_ticks():
    v = [int(x) for x in (read("/proc/stat") or "cpu 0").splitlines()[0].split()[1:]]
    return sum(v[:8]), (v[3] + v[4]) if len(v) > 4 else 0


def disk_counters(names):
    out = {}
    for line in (read("/proc/diskstats") or "").splitlines():
        f = line.split()
        if len(f) > 12 and f[2] in names:
            out[names[f[2]]] = [int(f[5]), int(f[9]), int(f[12])]  # sectors read, written, ms busy
    return out


def route():
    """(interface, gateway) of the default route."""
    for line in (read("/proc/net/route") or "").splitlines()[1:]:
        f = line.split()
        if len(f) > 2 and f[1] == "00000000":
            return f[0], socket.inet_ntoa(struct.pack("<L", int(f[2], 16)))
    return None, None


def net_counters(iface):
    for line in (read("/proc/net/dev") or "").splitlines():
        if line.strip().startswith(iface + ":"):
            f = line.split(":", 1)[1].split()
            return [int(f[0]), int(f[8])]
    return None


def wifi_signal(iface):
    for line in (read("/proc/net/wireless") or "").splitlines()[2:]:
        f = line.split()
        if f and f[0].rstrip(":") == iface:
            return float(f[3].rstrip("."))
    return None


def pings(targets):
    """{name: [replies out of 3, average ms]} for each target, pinged together."""
    procs = {k: subprocess.Popen(["ping", "-n", "-q", "-c", "3", "-i", "0.2", "-W", "1", t],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
             for k, t in targets.items() if t}
    out = {}
    for k, p in procs.items():
        try:
            text = p.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            p.kill()
            text = ""
        got = re.search(r"(\d+) received", text)
        avg = re.search(r"= [\d.]+/([\d.]+)/", text)
        out[k] = [int(got.group(1)) if got else 0, round(float(avg.group(1)), 1) if avg else None]
    return out


def hwmon_temps(names):
    temps = {}
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        kind = read(h + "/name")
        raw = read(h + "/temp1_input")
        if raw is None:
            continue
        if kind in ("k10temp", "coretemp"):
            temps["cpu"] = round(int(raw) / 1000)
        elif kind == "drivetemp":
            blocks = glob.glob(h + "/device/block/*")
            block = os.path.basename(blocks[0]) if blocks else None
            if block in names:
                temps[names[block]] = round(int(raw) / 1000)
    return temps


def gpu():
    smi = shutil.which("nvidia-smi")
    if not smi:
        return None

    def query(fields):
        out = sh([smi, "--query-gpu=" + fields, "--format=csv,noheader,nounits"], 10).splitlines()
        return [int(float(x)) if re.fullmatch(r"\s*[\d.]+\s*", x) else None for x in out[0].split(",")] if out else []

    core = query("utilization.gpu,temperature.gpu")
    if len(core) < 2:
        return None
    codec = query("utilization.encoder,utilization.decoder") + [None, None]
    return {"use": core[0], "c": core[1], "enc": codec[0], "dec": codec[1]}


def mem():
    info = {}
    for line in (read("/proc/meminfo") or "").splitlines():
        k, v = line.split(":", 1)
        info[k] = int(v.split()[0]) * 1024
    total = info.get("MemTotal") or 1
    return round(100 * (total - info.get("MemAvailable", 0)) / total), \
        round((info.get("SwapTotal", 0) - info.get("SwapFree", 0)) / 2 ** 20)


def fans():
    try:
        with open(FANS_STATE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        return {}
    return {v.get("label", k): v.get("duty") for k, v in state.get("fans", {}).items()}


def pods():
    """{'namespace/pod': [restarts, ready]}"""
    try:
        data = json.loads(sh(KUBECTL + ["get", "pods", "-A", "-o", "json"], 20) or "{}")
    except ValueError:
        return {}
    out = {}
    for p in data.get("items", []):
        if p["status"].get("phase") in ("Succeeded", "Failed"):
            continue
        cs = p["status"].get("containerStatuses") or []
        out["%s/%s" % (p["metadata"]["namespace"], p["metadata"]["name"])] = [
            sum(c.get("restartCount", 0) for c in cs), int(bool(cs) and all(c.get("ready") for c in cs))]
    return out


def record():
    now = time.time()
    names = drive_names()
    iface, gateway = route()
    try:
        with open(STATE) as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = {}
    total, idle = cpu_ticks()
    disks = disk_counters(names)
    net = net_counters(iface) if iface else None
    cur = {"t": now, "cpu": [total, idle], "disk": disks, "net": net, "if": iface}
    used, swap = mem()
    row = {"t": int(now), "load": float((read("/proc/loadavg") or "0").split()[0]), "mem": used, "swap": swap,
           "gpu": gpu(), "temp": hwmon_temps(names), "fans": fans(), "pods": pods(),
           "ping": pings({"router": gateway, "internet": INTERNET}),
           "wifi": {"if": iface, "sig": wifi_signal(iface) if iface else None}}
    dt = now - prev.get("t", 0)
    if 0 < dt < 600:
        dtot, didle = total - prev["cpu"][0], idle - prev["cpu"][1]
        row["cpu"] = round(100 * (dtot - didle) / dtot) if dtot > 0 else None
        row["disk"] = {}
        for name, (r, w, busy) in disks.items():
            old = prev.get("disk", {}).get(name)
            if old:
                row["disk"][name] = [min(100, round((busy - old[2]) / dt / 10)),
                                     round((r - old[0]) * 512 / dt / 1e6, 1), round((w - old[1]) * 512 / dt / 1e6, 1)]
        if net and prev.get("net") and prev.get("if") == iface:
            row["wifi"]["down"] = round((net[0] - prev["net"][0]) * 8 / dt / 1e6, 1)
            row["wifi"]["up"] = round((net[1] - prev["net"][1]) * 8 / dt / 1e6, 1)
    os.makedirs(DIR, exist_ok=True)
    with open(os.path.join(DIR, time.strftime("%Y-%m-%d.jsonl", time.localtime(now))), "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")
    with open(STATE + ".tmp", "w") as f:
        json.dump(cur, f)
    os.replace(STATE + ".tmp", STATE)
    cutoff = time.strftime("%Y-%m-%d", time.localtime(now - KEEP_DAYS * DAY))
    for old in glob.glob(os.path.join(DIR, "*.jsonl")):
        if os.path.basename(old)[:10] < cutoff:
            os.remove(old)
    try:
        watch(now)
    except Exception as err:  # the readings matter more than the incident file
        print("trouble check failed: %s" % err, flush=True)


# ---------------------------------------------------------------- the lookup

def hm(ts):
    return time.strftime("%H:%M", time.localtime(ts))


def clock(ms):
    s = int(ms) // 1000
    return "%d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60)


def parse_when(text):
    out = sh(["date", "-d", text, "+%s"])
    if not out.strip():
        sys.exit("can't read the time %r; try 12:15, \"yesterday 12:15\" or \"2026-10-10 12:15\"" % text)
    ts = int(out)
    if ts > time.time() + 60 and re.fullmatch(r"\s*\d{1,2}:\d{2}\s*", text):
        ts -= DAY
    return ts


def days(start, end):
    d, out = datetime.date.fromtimestamp(start), []
    while d <= datetime.date.fromtimestamp(end):
        out.append(d)
        d += datetime.timedelta(days=1)
    return out


def rows(start, end):
    out = []
    for d in days(start - 120, end):
        try:
            with open(os.path.join(DIR, d.isoformat() + ".jsonl")) as f:
                out += [json.loads(l) for l in f if l.strip()]
        except (OSError, ValueError):
            pass
    return [r for r in out if start - 120 <= r["t"] <= end]


def journal(args, start, end):
    out = []
    for line in sh(["journalctl", "--no-pager", "-o", "json", "--since", "@%d" % start, "--until", "@%d" % end]
                   + args, 60).splitlines():
        try:
            e = json.loads(line)
            msg = e.get("MESSAGE")
            if isinstance(msg, list):
                msg = bytes(msg).decode(errors="replace")
            out.append((int(e["__REALTIME_TIMESTAMP"]) / 1e6, msg or ""))
        except (ValueError, KeyError, TypeError):
            pass
    return out


def section(title, lines, empty):
    print("\n== " + title)
    if not lines:
        print("  " + empty)
    for line in lines[:LINES]:
        print("  " + line)
    if len(lines) > LINES:
        print("  ... %d more" % (len(lines) - LINES))


def who_used(app, who, start, end):
    lines = []
    for ts, msg in journal(["_SYSTEMD_UNIT=pi-paths.service"], start, end):
        if app and msg.split()[:1] != [app]:
            continue
        if who and who.lower() not in msg.lower():
            continue
        lines.append("%s  %s" % (hm(ts), re.sub(r"\s{2,}", "  ", msg)))
    return lines


def pod_changes(data, app):
    out = []
    for a, b in zip(data, data[1:]):
        pa, pb = a.get("pods", {}), b.get("pods", {})
        for name, (restarts, ready) in sorted(pb.items()):
            short = name.split("/", 1)[1]
            if app and app not in short:
                continue
            if name in pa:
                if restarts > pa[name][0]:
                    out.append((b["t"], "%s restarted (crash or killed)" % short))
                elif pa[name][1] and not ready:
                    out.append((b["t"], "%s stopped answering its health check" % short))
                elif ready and not pa[name][1]:
                    out.append((b["t"], "%s ready again" % short))
            elif pa:
                out.append((b["t"], "%s started (new pod)" % short))
        for name in sorted(set(pa) - set(pb)):
            if not app or app in name:
                out.append((b["t"], "%s went away" % name.split("/", 1)[1]))
    return out


def stands_out(data, app):
    notes = []
    for a, b in zip(data, data[1:]):
        if b["t"] - a["t"] > 100:
            notes.append((a["t"] + 60, "no readings until %s: the PC was too busy, or off" % hm(b["t"])))
    for r in data:
        t = r["t"]
        if (r.get("cpu") or 0) >= 90:
            notes.append((t, "CPU flat out (%d%%)" % r["cpu"]))
        if r.get("mem", 0) >= 92:
            notes.append((t, "memory nearly full (%d%%, swap %d MB)" % (r["mem"], r.get("swap", 0))))
        for name, (busy, rd, wr) in (r.get("disk") or {}).items():
            if busy >= 90:
                notes.append((t, "%s drive busy %d%% (reading %.0f MB/s, writing %.0f MB/s)" % (name, busy, rd, wr)))
        g = r.get("gpu") or {}
        for k, label in (("enc", "video encoder"), ("dec", "video decoder"), ("use", "GPU")):
            if (g.get(k) or 0) >= 90:
                notes.append((t, "%s flat out (%d%%)" % (label, g[k])))
        p = r.get("ping", {})
        router, net = p.get("router") or [3, None], p.get("internet") or [3, None]
        if router[0] < 3:
            notes.append((t, "Wi-Fi: lost %d of 3 pings to the router" % (3 - router[0])))
        elif (router[1] or 0) > 50:
            notes.append((t, "Wi-Fi slow: router ping %.0f ms" % router[1]))
        if net[0] == 0 and router[0] > 0:
            notes.append((t, "internet down (router fine)"))
        elif net[0] < 3 and router[0] == 3:
            notes.append((t, "internet: lost %d of 3 pings" % (3 - net[0])))
        sig = (r.get("wifi") or {}).get("sig")
        if sig is not None and sig < -75:
            notes.append((t, "Wi-Fi signal weak (%d dBm)" % sig))
        for name, c in (r.get("temp") or {}).items():
            if (name == "cpu" and c >= 85) or (name != "cpu" and c >= 50):
                notes.append((t, "%s hot (%d°)" % (name, c)))
    return notes + pod_changes(data, app)


def table(data, start):
    order = list(MOUNTS.values())
    disks = sorted({d for r in data for d in (r.get("disk") or {})}, key=lambda d: order.index(d) if d in order else 9)
    widths = [5, 5, 5, 5, 5, 5] + [6] * len(disks) + [7, 6, 5, 9, 9, 5, 5]
    fmt = lambda cells: "".join(str(c).rjust(w) for c, w in zip(cells, widths))
    lines = [fmt(["time", "cpu", "ram", "gpu", "enc", "dec"] + disks + ["down", "up", "sig", "router", "internet",
                                                                      "cpu°", "hdd°"]),
             " " * 30 + "drive busy".center(6 * len(disks)) + "Wi-Fi Mbit/s".center(13) + " dBm" + "ping".center(18)]
    pct = lambda v: "%d%%" % v if isinstance(v, (int, float)) else "-"
    ping = lambda x: ("%.0fms" % x[1] if x[0] == 3 else "%d/3 lost" % (3 - x[0])) if x else "-"
    for r in data:
        if r["t"] < start - 60:
            continue
        g, w, p, temp = r.get("gpu") or {}, r.get("wifi") or {}, r.get("ping") or {}, r.get("temp") or {}
        hdd = [c for n, c in temp.items() if n.startswith("hdd")]
        lines.append(fmt([hm(r["t"]), pct(r.get("cpu")), pct(r.get("mem")), pct(g.get("use")), pct(g.get("enc")),
                          pct(g.get("dec"))] + [pct((r.get("disk") or {}).get(d, [None])[0]) for d in disks]
                         + [w.get("down", "-"), w.get("up", "-"), int(w["sig"]) if w.get("sig") is not None else "-",
                            ping(p.get("router")), ping(p.get("internet")), temp.get("cpu", "-"),
                            max(hdd) if hdd else "-"]))
    return lines


def exec_app(app, script, container=None):
    return sh(KUBECTL + ["-n", NS, "exec", "deploy/" + app] + (["-c", container] if container else [])
              + ["--", "sh", "-c", script], 60)


JF_LINE = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ ([+-]\d\d:\d\d)\] \[(\w+)\] \[\d+\] ([\w.]+): (.*)")
JF_KEEP = re.compile(r"Playback|playing|transcod|FFmpeg|ffmpeg|stream|throttl|session|Authentication", re.I)


def jellyfin_log(who, start, end, tail=None):
    files = " ".join("/data/log/log_%s.log" % d.strftime("%Y%m%d") for d in days(start, end))
    reader = "tail -q -n %d" % tail if tail else "cat"
    lines = []
    for line in exec_app("jellyfin", "%s %s 2>/dev/null" % (reader, files)).splitlines():
        m = JF_LINE.match(line)
        if not m:
            continue
        ts = datetime.datetime.fromisoformat(m.group(1).replace(" ", "T") + m.group(2)).timestamp()
        level, msg = m.group(3), m.group(5)
        if not start <= ts <= end:
            continue
        if level == "INF" and not JF_KEEP.search(msg):
            continue
        if who and level == "INF" and who.lower() not in msg.lower():
            continue
        msg = re.sub(r"Stopped at (\d+) ms", lambda s: "Stopped at %s into the film" % clock(s.group(1)), msg)
        lines.append("%s  [%s] %s" % (hm(ts), level, msg[:220]))
    return lines


def jellyfin_transcodes(start, end):
    """The transcodes that were running in the window: the film, error lines,
    and how fast ffmpeg went (below 1x it can't keep up and the video stops to buffer)."""
    script = ("for f in $(find /data/log -name 'FFmpeg*.log' -newermt @%d 2>/dev/null); do "
              "echo \"### $f\"; head -c 4000 \"$f\" | grep -o -m1 'file:\"[^\"]*\"'; "
              "grep -i -m5 -E 'error|invalid|corrupt|non-monoton' \"$f\"; "
              "tr '\\r' '\\n' < \"$f\" | grep -o 'speed=[ 0-9.]*x' | tail -n 600; done" % start)
    out, cur = [], None
    for line in exec_app("jellyfin", script).splitlines() + ["### end"]:
        if line.startswith("### "):
            if cur:
                speeds, slow = cur["speeds"], [s for s in cur["speeds"] if s < 1.0]
                if not speeds:
                    verdict = "no speed readings"
                elif slow:
                    verdict = "slowest %.2fx, %d of %d readings under 1x: transcoding could NOT keep up" % (
                        min(speeds), len(slow), len(speeds))
                else:
                    verdict = "slowest %.2fx: kept up" % min(speeds)
                out.append("started %s: %s  %s" % (cur["began"], cur["film"], verdict))
                out += ["    " + e[:200] for e in cur["errors"]]
            name = line[4:]
            stamp = re.search(r"(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)-(\d\d)", name)
            began = time.mktime(time.strptime(" ".join(stamp.groups()), "%Y-%m-%d %H %M %S")) if stamp else 0
            cur = None if name == "end" or began > end else {
                "began": hm(began) if began else "?", "film": os.path.basename(name), "errors": [], "speeds": []}
        elif cur:
            if line.startswith('file:"'):
                cur["film"] = os.path.basename(line[6:-1])
            elif line.startswith("speed="):
                try:
                    cur["speeds"].append(float(line[6:-1]))
                except ValueError:
                    pass
            else:
                cur["errors"].append(line.strip())
    return out


def nextcloud_log(who, start, end):
    """Warnings and errors from Nextcloud's own log (nextcloud.log, JSON lines)."""
    dates = {d.isoformat() for d in days(start - DAY, end + DAY)}
    script = "grep -h -E '%s' /var/www/html/data/nextcloud.log 2>/dev/null | tail -n 5000" % "|".join(sorted(dates))
    levels = ["debug", "info", "warn", "ERROR", "FATAL"]
    lines = []
    for line in exec_app("nextcloud", script, "nextcloud").splitlines():
        try:
            e = json.loads(line)
            ts = datetime.datetime.fromisoformat(e["time"]).timestamp()
        except (ValueError, KeyError, TypeError):
            continue
        if not start <= ts <= end or int(e.get("level", 0)) < 2:
            continue
        if who and who.lower() not in str(e.get("user", "")).lower():
            continue
        lines.append("%s  [%s] %s %s: %s  (%s %s)" % (
            hm(ts), levels[min(int(e.get("level", 0)), 4)], e.get("app", ""), e.get("user", "-"),
            str(e.get("message", ""))[:200], e.get("method", ""), str(e.get("url", ""))[:80]))
    return lines


ACCESS = re.compile(r'"(\w+) (\S+) HTTP/[\d.]+" (\d{3}) ')


def nextcloud_requests(who, start, end):
    """Nextcloud's web requests minute by minute, from its console log: how many
    pieces of an upload arrived, and every request that failed."""
    since = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    text = ""
    for prev in (["--previous"], []):
        text += sh(KUBECTL + ["-n", NS, "logs", "deploy/nextcloud", "-c", "nextcloud", "--timestamps",
                              "--since-time=" + since] + prev, 60)
    per_min, errors = {}, []
    for line in text.splitlines():
        stamp, _, rest = line.partition(" ")
        m = ACCESS.search(rest)
        if not m:
            continue
        try:
            ts = datetime.datetime.fromisoformat(stamp[:19] + "+00:00").timestamp()
        except ValueError:
            continue
        method, path, status = m.group(1), m.group(2), int(m.group(3))
        if not start <= ts <= end or path.startswith("/status.php"):
            continue
        if who and ("/%s/" % who.lower()) not in path.lower():
            continue
        minute = per_min.setdefault(hm(ts), [0, 0, 0])
        minute[0] += 1
        if method in ("PUT", "MOVE") and "/remote.php/dav/" in path:
            minute[1] += 1
        if status >= 400:
            minute[2] += 1
            errors.append("%s  %s %s  -> %d" % (hm(ts), method, path[:110], status))
    lines = ["%s  %4d requests  %4d upload pieces  %3d failed" % (k, *v) for k, v in sorted(per_min.items())]
    if errors:
        lines += ["", "failed requests:"] + errors
    return lines


def app_errors(app, start, end):
    since = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = []
    for prev in (["--previous"], []):
        for line in sh(KUBECTL + ["-n", NS, "logs", "deploy/" + app, "--all-containers", "--timestamps",
                                  "--since-time=" + since] + prev, 60).splitlines():
            stamp, _, rest = line.partition(" ")
            try:
                ts = datetime.datetime.fromisoformat(stamp[:19] + "+00:00").timestamp()
            except ValueError:
                continue
            if start <= ts <= end and POD_ERROR.search(rest):
                lines.append("%s  %s" % (hm(ts), rest[:220]))
    return lines


def lookup(args):
    at = parse_when(args.time)
    start, end = at - args.minutes * 60, at + args.minutes * 60
    app = (args.app or "").lower()
    print("%s, %s to %s%s%s" % (time.strftime("%a %d %b %H:%M", time.localtime(at)), hm(start), hm(end),
                                ", " + app if app else "", ", " + args.who if args.who else ""))
    data = rows(start, end)

    # The per-minute paths below only see tailnet peers. A sharee's phone on a
    # Tailscale share streamed for minutes without showing there, while
    # Jellyfin's own sessions had it. For "now", which is what is checked
    # before a restart, ask the apps too.
    if abs(at - time.time()) < 120:
        section("Using an app right now", [a for a in active_now() if not app or app in a.lower()],
                "nobody")

    section("Who was using %s (each minute: path and speed)" % (app or "the apps"), who_used(app, args.who, start, end),
            "nobody over Tailscale in this window (Funnel viewers show in the app's log below)")

    notes = sorted(stands_out(data, app))
    for ts, msg in journal(["-k"], start, end):
        if OOM.search(msg):
            notes.append((ts, "memory kill: " + msg[:160]))
        elif DISK_TROUBLE.search(msg):
            notes.append((ts, "disk error: " + msg[:160]))
    section("What stands out", ["%s  %s" % (hm(t), m) for t, m in sorted(notes)],
            "nothing: no busy drives, drops, restarts or memory kills" if data else
            "no readings for this time (recording started later, or older than %d days)" % KEEP_DAYS)
    section("The PC, minute by minute", table(data, start) if data else [], "no readings")

    if app == "jellyfin":
        section("Jellyfin's log (playback, transcoding, warnings, errors)", jellyfin_log(args.who, start, end),
                "nothing (Jellyfin keeps its log 3 days)")
        section("Transcodes running then", jellyfin_transcodes(start, end),
                "none: the film played as is (direct play), or the log is gone")
    elif app == "nextcloud":
        section("Nextcloud's requests, minute by minute", nextcloud_requests(args.who, start, end),
                "none (the console log is gone after two restarts)")
        section("Nextcloud's log (warnings and errors)", nextcloud_log(args.who, start, end), "nothing")
    elif app:
        section("%s's error lines" % app, app_errors(app, start, end), "none")

    wifi = [(t, m) for t, m in journal(["-u", "NetworkManager", "-u", "wpa_supplicant"], start, end) if WIFI.search(m)]
    kern = journal(["-k", "-p", "warning"], start, end)
    section("Wi-Fi and kernel messages", ["%s  %s" % (hm(t), m[:200]) for t, m in sorted(wifi + kern)], "none")


# ---------------------------------------------------------------- trouble, unattended

def trouble(now):
    """[(app or '', reason)] for what went wrong in the last minute."""
    data = rows(now - 240, now)
    out = []
    if not data:
        return out
    last = data[-1]["t"]
    for ts, msg in stands_out(data[-2:], ""):
        # Busy drives, a single lost ping, a slow ping or a weak signal on their
        # own are everyday Wi-Fi and disk life, not trouble.
        if ts < last - 60 or re.search(r"drive busy|ready again|started \(new pod\)|went away|lost 1 of 3|"
                                       r"Wi-Fi slow|signal weak", msg):
            continue
        app = next((a for a in ("jellyfin", "nextcloud", "immich") if a in msg), "")
        out.append((app, msg))
    # A drive flat out for a few minutes, not a moment.
    recent = [r.get("disk") or {} for r in data[-3:]]
    if len(recent) == 3:
        for name in recent[-1]:
            if all(d.get(name, [0])[0] >= 90 for d in recent):
                out.append(("", "%s drive flat out for 3 minutes" % name))
    for ts, msg in journal(["-k"], now - 70, now):
        if OOM.search(msg):
            out.append(("", "memory kill: " + msg[:120]))
        elif DISK_TROUBLE.search(msg):
            out.append(("", "disk error: " + msg[:120]))
    for ts, msg in journal(["_SYSTEMD_UNIT=pi-paths.service"], now - 70, now):
        if " RELAY " in msg:
            f = msg.split()
            out.append((f[0], "%s: %s on a slow relay" % (f[0], " ".join(f[1:4]))))
    if any(n.split("/", 1)[1].startswith("jellyfin") for n in data[-1].get("pods", {})):
        errs = [l for l in jellyfin_log(None, now - 70, now, tail=400) if "[ERR]" in l or "[FTL]" in l]
        if errs:
            out.append(("jellyfin", "Jellyfin logged %d error(s): %s" % (len(errs), errs[-1][13:130])))
    if any(n.split("/", 1)[1].startswith("nextcloud") for n in data[-1].get("pods", {})):
        bad = [l for l in nextcloud_requests(None, now - 70, now) if "->" in l]
        failed = [l for l in bad if re.search(r"-> 5\d\d", l) or
                  (re.search(r" (PUT|MOVE|MKCOL) ", l) and not re.search(r"-> (401|404)", l))]
        if failed:
            out.append(("nextcloud", "Nextcloud: %d failed request(s), last %s" % (len(failed), failed[-1][7:120])))
    return out


def watch(now):
    """Notes trouble, and SETTLE seconds after it began saves the page to a file.
    The same trouble again (a relay every minute, say) is noted at most once per MERGE."""
    os.makedirs(INCIDENTS, exist_ok=True)
    try:
        with open(OPEN) as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    inc, seen = st.get("open"), {k: v for k, v in st.get("seen", {}).items() if now - v < MERGE}
    for app, reason in trouble(now):
        key = re.sub(r"\d+", "N", reason)
        if key in seen:
            continue
        seen[key] = now
        inc = inc or {"t": now, "reasons": [], "apps": []}
        inc["reasons"].append("%s  %s" % (hm(now), reason))
        if app and app not in inc["apps"]:
            inc["apps"].append(app)
    if inc and now - inc["t"] >= SETTLE:
        save(inc, now)
        inc = None
    with open(OPEN + ".tmp", "w") as f:
        json.dump({"open": inc, "seen": seen}, f)
    os.replace(OPEN + ".tmp", OPEN)
    cutoff = time.strftime("%Y-%m-%d", time.localtime(now - KEEP_INCIDENT_DAYS * DAY))
    for old in glob.glob(os.path.join(INCIDENTS, "*.txt")):
        if os.path.basename(old)[:10] < cutoff:
            os.remove(old)


def save(inc, now):
    import contextlib
    import io
    path = os.path.join(INCIDENTS, time.strftime("%Y-%m-%d_%H%M.txt", time.localtime(inc["t"])))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        print("Trouble on %s, %s\n" % (socket.gethostname(), time.strftime("%a %d %b %Y %H:%M", time.localtime(inc["t"]))))
        print("What set it off:")
        for r in inc["reasons"]:
            print("  " + r)
        apps = inc["apps"] or [None]
        for app in apps:
            print("\n" + "=" * 100)
            minutes = int((now - inc["t"]) / 60) + 5
            lookup(argparse.Namespace(time="@%d" % (inc["t"] + (now - inc["t"]) // 2), app=app, who=None,
                                      minutes=max(15, minutes)))
    with open(path, "w") as f:
        f.write(buf.getvalue())
    print("saved " + path, flush=True)


def incidents():
    files = sorted(glob.glob(os.path.join(INCIDENTS, "*.txt")))
    if not files:
        print("nothing saved yet")
    for path in files:
        with open(path) as f:
            head = f.read(3000).split("What set it off:\n", 1)[-1].split("\n\n", 1)[0]
        print(path)
        print(head + "\n")
    try:
        with open(OPEN) as f:
            inc = json.load(f).get("open")
    except (OSError, ValueError):
        inc = None
    if inc:
        print("going on now (its file is saved at %s):" % hm(inc["t"] + SETTLE))
        print("\n".join("  " + r for r in inc["reasons"]))


def summary(hours=24):
    """One line per incident in the last day, for the morning report."""
    cutoff = time.time() - hours * 3600
    out = []
    for path in sorted(glob.glob(os.path.join(INCIDENTS, "*.txt"))):
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path) as f:
            reasons = f.read(3000).split("What set it off:\n", 1)[-1].split("\n\n", 1)[0].splitlines()
        first = reasons[0].strip() if reasons else "?"
        more = " (+%d more)" % (len(reasons) - 1) if len(reasons) > 1 else ""
        out.append("%s%s  -> %s" % (first, more, os.path.basename(path)))
    return out


# ---------------------------------------------------------------- right now

BOT_ENV = "/etc/pi-bot/env"
# Each app and the pods it is made of; the first is the app itself.
APPS = [
    ("Jellyfin", ["jellyfin"]),
    ("Nextcloud", ["nextcloud", "nextcloud-postgres", "nextcloud-redis"]),
    ("Immich", ["immich-server", "immich-machine-learning", "immich-postgres", "immich-redis"]),
    ("Vaultwarden", ["vaultwarden"]),
    ("Kiwix", ["kiwix"]),
    ("ArchiveBox", ["archivebox"]),
    ("Gitea", ["gitea"]),
    ("Uptime Kuma", ["uptime-kuma"]),
    ("Torrent", ["qbittorrent"]),
    ("Dashboard", ["pi-console"]),
]
# pi-paths names an app by its tailnet machine.
TAILNET_APPS = {"jellyfin": "Jellyfin", "cloud": "Nextcloud", "photos": "Immich", "vault": "Vaultwarden",
                "kiwix": "Kiwix", "archivebox": "ArchiveBox", "git": "Gitea", "uptime": "Uptime Kuma", "torrent": "Torrent",
                "pi-console": "Dashboard"}
PATHS_LINE = re.compile(r"^(\S+)\s+(.+?) / (.+?)\s+((?:direct|peer relay|RELAY).*?)\s+"
                        r"to them\s+([\d.]+) Mbit/s\s+from them\s+([\d.]+) Mbit/s")
DRIVE_LABELS = {"os": "SSD1", "ssd": "SSD2", "hdd1": "HDD1", "hdd2": "HDD2"}


def env_value(name):
    if os.environ.get(name):
        return os.environ[name]
    for line in (read(BOT_ENV) or "").splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"') or None
    return None


def mbit(x):
    return "%.1f" % x if x < 10 else "%.0f" % x


def apps_now():
    """(running, off, down), or None when k3s did not answer. Off is an app
    scaled to 0 on purpose (make torrent-off), which is not trouble."""
    scaled = {}
    for line in sh(KUBECTL + ["-n", NS, "get", "deploy", "-o",
                              r'jsonpath={range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}'], 20).splitlines():
        name, _, replicas = line.partition("=")
        scaled[name] = replicas
    live = {}
    for name, (_, ready) in pods().items():
        ns, pod = name.split("/", 1)
        if ns == NS:
            base = re.sub(r"-[a-z0-9]{5,10}-[a-z0-9]{5}$", "", pod)
            live[base] = max(live.get(base, 0), ready)
    if not live:
        return None
    running, off, down = [], [], []
    for app, parts in APPS:
        if scaled.get(parts[0]) == "0":
            off.append(app)
            continue
        gone = [p for p in parts if p not in live]
        stuck = [p for p in parts if live.get(p) == 0]
        if not gone and not stuck:
            running.append(app)
        elif parts[0] in gone:
            down.append("%s (not running)" % app)
        elif parts[0] in stuck:
            down.append("%s (starting, or stuck)" % app)
        else:
            down.append("%s (part of it is down: %s)" % (app, ", ".join(gone + stuck)))
    return running, off, down


def jellyfin_sessions():
    """What Jellyfin itself says is playing, Funnel viewers included, as
    {app, who, what, device}; None without an API key."""
    key = env_value("JELLYFIN_API_KEY")
    ip = jellyfin_ip()
    if not key or not ip:
        return None
    sessions = jellyfin_get(ip, key, "/Sessions?activeWithinSeconds=300")
    if sessions is None:
        return None
    out = []
    for s in sessions:
        item = s.get("NowPlayingItem")
        if not item:
            continue
        play = s.get("PlayState") or {}
        title = item.get("Name") or "?"
        if item.get("SeriesName"):
            title = "%s S%02dE%02d" % (item["SeriesName"], item.get("ParentIndexNumber") or 0,
                                       item.get("IndexNumber") or 0)
        total = item.get("RunTimeTicks") or 0
        at = " at %s of %s" % (clock((play.get("PositionTicks") or 0) // 10000), clock(total // 10000)) if total else ""
        how = {"Transcode": "converted on the fly", "DirectStream": "direct stream",
               "DirectPlay": "direct play"}.get(play.get("PlayMethod"), "playing")
        out.append({"app": "Jellyfin", "who": s.get("UserName") or "?",
                    "what": '"%s"%s%s, %s' % (title, at, ", paused" if play.get("IsPaused") else "", how),
                    "device": s.get("DeviceName") or "?"})
    return out


def svc_ip(name):
    return sh(KUBECTL + ["-n", NS, "get", "svc", name, "-o", "jsonpath={.spec.clusterIP}"], 10).strip()


def jellyfin_ip():
    return svc_ip("jellyfin")


def jellyfin_get(ip, key, path, timeout=8):
    req = urllib.request.Request("http://%s%s" % (ip, path),
                                 headers={"Authorization": 'MediaBrowser Token="%s"' % key})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except (OSError, ValueError):
        return None


# The live-view browser (noVNC on :6080, showing the virtual screen :99) and the
# job bot run in their own container as this user (k8s/applypilot.yaml); before
# that, as the owner, whose Claude sessions can still drive a browser of their own.
BROWSER_USERS = ("applypilot", "homelab")
LIVEVIEW_PORT = 6080
# A live-view tab left open streams forever, so an open connection is not
# someone watching. Someone is, while the screen has had a click or a key
# from it this recently. The job bot drives Chrome directly, not through the
# screen, so it never counts as a click.
LIVEVIEW_IDLE = 600
# The virtual screen's idle time, from X itself (MIT-SCREEN-SAVER), inside the
# job bot's container: it has python3 and libXss, not xprintidle.
X_IDLE = r"""
import ctypes
x = ctypes.cdll.LoadLibrary("libX11.so.6"); s = ctypes.cdll.LoadLibrary("libXss.so.1")
class I(ctypes.Structure):
    _fields_ = [("w", ctypes.c_ulong), ("s", ctypes.c_int), ("k", ctypes.c_int),
                ("t", ctypes.c_ulong), ("idle", ctypes.c_ulong), ("m", ctypes.c_ulong)]
x.XOpenDisplay.restype = ctypes.c_void_p
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]; x.XDefaultRootWindow.restype = ctypes.c_ulong
s.XScreenSaverAllocInfo.restype = ctypes.POINTER(I)
s.XScreenSaverQueryInfo.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(I)]
d = x.XOpenDisplay(b":99"); i = s.XScreenSaverAllocInfo()
if d and s.XScreenSaverQueryInfo(d, x.XDefaultRootWindow(d), i):
    print(i.contents.idle // 1000)
"""


def liveview_idle():
    """Seconds since the live view's screen last had a click or a key; None
    if the container could not say."""
    out = sh(KUBECTL + ["-n", "applypilot", "exec", "deploy/applypilot", "--", "python3", "-c", X_IDLE], 10).strip()
    return int(out) if out.isdigit() else None


def cmdlines(user):
    """Every process of one user, as its command line."""
    try:
        uid = int(sh(["id", "-u", user], 5).strip())
    except ValueError:
        return []
    out = []
    for d in glob.glob("/proc/[0-9]*"):
        try:
            if os.stat(d).st_uid != uid:
                continue
            with open(d + "/cmdline", "rb") as f:
                out.append(f.read().replace(b"\0", b" ").decode("utf-8", "replace"))
        except OSError:
            continue
    return out


def browser_uses():
    """Who is on the live-view browser: the job bot, a Claude agent session,
    and each device with the live view open, as {app: "Browser", ...}."""
    users = [env_value("BROWSER_USER")] if env_value("BROWSER_USER") else BROWSER_USERS
    procs = [c for user in users for c in cmdlines(user)]
    out = []
    # round.pid holds a pid of the container's own, which means nothing out
    # here; the round's script is visible either way.
    if any("scripts/round.sh" in c for c in procs):
        applying = any("--remote-debugging-port" in c and "chrome-workers" in c for c in procs)
        out.append({"app": "Browser", "who": "Apply bot",
                    "what": "applying to jobs" if applying else "finding and writing, browser free",
                    "device": "this PC"})
    # A Claude session driving a browser of its own on the live screen: a remote-controlled
    # Chrome that is neither the bot's (chrome-workers) nor the home window. An idle Claude
    # session left open does not count.
    if not out and any("chrom" in c and "--remote-debugging" in c and "chrome-workers" not in c
                       and "liveview-browser" not in c and "--type=" not in c for c in procs):
        out.append({"app": "Browser", "who": "Claude agent", "what": "using the browser", "device": "this PC"})
    peers = {}
    try:
        st = json.loads(sh(["tailscale", "status", "--json"], 10) or "{}")
        for peer in list((st.get("Peer") or {}).values()) + [st.get("Self") or {}]:
            for ip in peer.get("TailscaleIPs") or []:
                peers[ip] = peer.get("HostName") or "?"
    except ValueError:
        pass
    seen = set()
    idle = None
    # Served on the host: the viewer's own connection. From the container: the
    # PC's `tailscale serve` connecting to it, one per viewer, the viewer unknown.
    flt = "( sport = :%d or dport = :%d )" % (LIVEVIEW_PORT, LIVEVIEW_PORT)
    for line in sh(["ss", "-Htn", "state", "established", flt], 5).splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local, ip = parts[-2], parts[-1].rsplit(":", 1)[0].strip("[]")
        if local.endswith(":%d" % LIVEVIEW_PORT):
            device = peers.get(ip, ip)
        else:
            device = "a tailnet device"
        if device in seen:
            continue
        seen.add(device)
        if idle is None:
            idle = liveview_idle()
        # Unknown counts as watching, as before this check existed.
        if idle is None or idle < LIVEVIEW_IDLE:
            out.append({"app": "Browser", "who": "User", "what": "watching the live view", "device": device})
    return out


def active_list():
    """Who is using what, as {app, who, what, device}: Jellyfin's own
    sessions, then pi-paths' last run (90 s) for everything else, then the
    live-view browser."""
    watching = jellyfin_sessions()
    out = list(watching or [])
    out += browser_uses()
    now = time.time()
    seen = {}
    for _, msg in journal(["_SYSTEMD_UNIT=pi-paths.service"], now - 90, now):
        m = PATHS_LINE.match(msg)
        if m:
            seen[m.group(1, 2, 3)] = m
    for (app, who, device), m in seen.items():
        if app == "jellyfin" and watching is not None:
            continue
        to_them, from_them = float(m.group(5)), float(m.group(6))
        what = ("uploading %s Mbit/s" % mbit(from_them) if from_them > to_them
                else "%s %s Mbit/s" % ("watching," if app == "jellyfin" else "downloading", mbit(to_them)))
        if m.group(4).startswith("RELAY"):
            what += ", on a slow relay"
        out.append({"app": TAILNET_APPS.get(app, app), "who": who, "what": what, "device": device})
    return out


def active_now():
    """active_list() as the bot's bullet lines."""
    return ["• %s on %s: %s (%s)" % (a["who"], a["app"], a["what"], a["device"]) for a in active_list()]


def status():
    """A few plain lines on right now, for the Discord bot: sudo pi-when status."""
    out = ["**PC, %s**" % time.strftime("%H:%M")]

    apps = apps_now()
    if apps is None:
        out.append("Apps: k3s did not answer, so I can't tell.")
    else:
        running, off, down = apps
        out.append("Running: " + (", ".join(running) if running else "nothing"))
        if off:
            out.append("Off: " + ", ".join(off))
        if down:
            out.append("Down: " + "; ".join(down))

    active = active_now()
    out.append("Active now:" if active else "Nobody is using anything right now.")
    out += active

    data = rows(time.time() - 180, time.time())
    if not data:
        out.append("PC: no readings in the last 3 minutes (sudo systemctl status pi-when.timer)")
    else:
        r = data[-1]
        t = r.get("temp") or {}
        pc = []
        if r.get("cpu") is not None:
            pc.append("CPU %d%%" % r["cpu"])
        if "cpu" in t:
            pc.append("%d°" % t["cpu"])
        drives = [v for k, v in t.items() if k != "cpu"]
        if drives:
            pc.append("drives up to %d°" % max(drives))
        out.append("PC: " + ", ".join(pc))
        busy = ["%s %s" % (DRIVE_LABELS.get(n, n), "writing %.0f MB/s" % w if w > rd else "reading %.0f MB/s" % rd)
                for n, (b, rd, w) in sorted((r.get("disk") or {}).items()) if b >= 20]
        if busy:
            out.append("Busy drives: " + ", ".join(busy))
        g = r.get("gpu") or {}
        if (g.get("enc") or 0) > 0 or (g.get("dec") or 0) > 0:
            out.append("Graphics card: converting video")
        fans_on = [k for k, v in (r.get("fans") or {}).items() if v and k != "CPU"]
        if fans_on:
            out.append("Fans on: " + ", ".join(fans_on))

    saved = summary()
    try:
        with open(OPEN) as f:
            going = (json.load(f).get("open") or {}).get("reasons") or []
    except (OSError, ValueError):
        going = []
    if going:
        out.append("Trouble going on now: " + going[0])
    if saved:
        out.append("Trouble in the last 24 hours: %d saved, newest: %s" % (len(saved), saved[-1].split("  -> ")[0]))
    elif not going:
        out.append("Trouble in the last 24 hours: none")
    print("\n".join(out))


STATUS_FILE = "/run/pi-status/status.json"
# Who used which app and when, for the Status tab's Users row. On the OS drive,
# not /run, so a reboot does not empty it.
ACTIVITY_FILE = os.path.join(DIR, "activity.json")
ACTIVITY_GAP = 600          # quiet this long and the next use is a new line
ACTIVITY_KEEP = 2 * DAY
ACTIVITY_MAX = 300
RATE = re.compile(r",? [\d.]+ Mbit/s")
# Adding up every film's size is one large request; the total moves when a
# film is added, not every 30 seconds.
LIBRARY_EVERY = 600
# Gitea's repos are folders, owner/name.git, so they are counted on disk and
# need no token. Backups are the ones `sudo gitea-backup` made by hand.
GITEA_REPOS = "/srv/hdd2/Gitea/repositories"
GITEA_BACKUPS = "/srv/hdd2/Backups/Gitea"
# Each app's settings and database, on the SSD.
APPS_DIR = "/1) Archive/Apps"
VAULT_DB = APPS_DIR + "/Vaultwarden/data/db.sqlite3"
GITEA_DB = APPS_DIR + "/Gitea/data/gitea.db"
PEOPLE_FILE = "/etc/pi-bot/people.json"
OCC = KUBECTL + ["-n", NS, "exec", "deploy/nextcloud", "-c", "nextcloud", "--",
                 "su", "-s", "/bin/sh", "www-data", "-c"]


def nextcloud_users():
    """[{name, bytes}] biggest first, from occ: no key or token needed, since
    root on the PC can already run occ inside the pod. None if it fails."""
    try:
        listed = json.loads(sh(OCC + ["php /var/www/html/occ user:list --output=json"], 60) or "null")
    except ValueError:
        return None
    if not isinstance(listed, dict):
        return None
    users = []
    for uid, name in listed.items():
        try:
            info = json.loads(sh(OCC + ["php /var/www/html/occ user:info --output=json %s" % shlex.quote(uid)], 60))
        except ValueError:
            continue
        info = info or {}
        used = (info.get("storage") or {}).get("used")
        users.append({"name": name if isinstance(name, str) else uid, "bytes": used if isinstance(used, int) else 0,
                      "admin": "admin" in (info.get("groups") or []), "disabled": info.get("enabled") is False,
                      "lastSeen": iso_seconds(info.get("last_seen"))})
    return sorted(users, key=lambda u: -u["bytes"])


def iso_seconds(text):
    """Unix seconds from an ISO date, or None. Never-seen dates (1970) are None too."""
    try:
        at = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00")[:25])
    except ValueError:
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=datetime.timezone.utc)
    at = int(at.timestamp())
    return at if at > DAY else None


def sqlite_rows(path, query):
    """Rows from an app's live SQLite, opened read-only. None if it cannot be read."""
    try:
        with sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5) as db:
            return db.execute(query).fetchall()
    except sqlite3.Error:
        return None


def people(accts):
    """accounts() regrouped by person: [{name, apps: {app: {admin, disabled,
    lastSeen}}}], most apps first. Names match when they agree ignoring case
    and punctuation ("a@b" and "A.b"); PEOPLE_FILE, a JSON {"name in an app":
    "person"}, joins the ones that do not (a tailnet's full name)."""
    try:
        with open(PEOPLE_FILE) as f:
            alias = {str(k).lower(): str(v) for k, v in json.load(f).items()}
    except (OSError, ValueError, AttributeError):
        alias = {}
    squash = lambda n: re.sub(r"[^a-z0-9]", "", n.lower()) or n.lower()
    out = {}
    for app, users in accts.items():
        for u in users:
            name = alias.get(u["name"].lower(), u["name"])
            person = out.setdefault(squash(name), {"name": name, "apps": {}})
            person["apps"][app] = {k: u[k] for k in ("admin", "disabled", "lastSeen")}
    return sorted(out.values(), key=lambda p: (-len(p["apps"]), p["name"].lower()))


def accounts(nextcloud):
    """Every account in every app that has them, as {app: [{name, admin,
    disabled, lastSeen}]}; an app that could not be read is left out rather
    than shown as empty. Tailnet is who can reach the apps that are not on
    the internet. Read-only throughout: APIs, occ (passed in, it is slow) and
    the apps' SQLite files."""
    out = {}
    key, ip = env_value("JELLYFIN_API_KEY"), jellyfin_ip()
    users = jellyfin_get(ip, key, "/Users") if key and ip else None
    if users is not None:
        out["Jellyfin"] = [{"name": u.get("Name") or "?", "admin": bool((u.get("Policy") or {}).get("IsAdministrator")),
                            "disabled": bool((u.get("Policy") or {}).get("IsDisabled")),
                            "lastSeen": iso_seconds(u.get("LastActivityDate"))} for u in users]
    if nextcloud is not None:
        out["Nextcloud"] = [{"name": u["name"], "admin": u.get("admin", False), "disabled": u.get("disabled", False),
                             "lastSeen": u.get("lastSeen")} for u in nextcloud]
    key, ip = env_value("IMMICH_API_KEY"), svc_ip("immich")
    if key and ip:
        req = urllib.request.Request("http://%s/api/server/statistics" % ip, headers={"x-api-key": key})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                out["Immich"] = [{"name": u.get("userName") or "?", "admin": False, "disabled": False, "lastSeen": None}
                                 for u in json.load(r).get("usageByUser") or []]
        except (OSError, ValueError):
            pass
    rows = sqlite_rows(VAULT_DB, "select coalesce(nullif(name, ''), email), enabled from users")
    if rows is not None:
        out["Vaultwarden"] = [{"name": n, "admin": False, "disabled": not on, "lastSeen": None} for n, on in rows]
    # type 0 is a person; 1 is an organisation.
    rows = sqlite_rows(GITEA_DB, "select name, is_admin, is_active, prohibit_login, last_login_unix from user where type = 0")
    if rows is not None:
        out["Gitea"] = [{"name": n, "admin": bool(a), "disabled": not on or bool(no), "lastSeen": seen or None}
                        for n, a, on, no, seen in rows]
    try:
        st = json.loads(sh(["tailscale", "status", "--json"], 10) or "null")
    except ValueError:
        st = None
    if st:
        # A user with only tagged devices is the cluster's own, not a person.
        people = {p.get("UserID") for p in list((st.get("Peer") or {}).values()) + [st.get("Self") or {}]
                  if not p.get("Tags")}
        out["Tailnet"] = [{"name": u.get("DisplayName") or u.get("LoginName") or "?", "admin": False, "disabled": False,
                           "lastSeen": None} for uid, u in (st.get("User") or {}).items() if int(uid) in people]
    return out


def tree_bytes(top):
    total = 0
    for root, _, files in os.walk(top):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def gitea_status(prev):
    """{repos, bytes, lastBackup}, or None before Gitea is installed. The size
    walks every repo, so it is redone every LIBRARY_EVERY like Nextcloud's."""
    if not os.path.isdir(GITEA_REPOS):
        return None
    last = prev.get("gitea") or {}
    if last.get("at") and time.time() - last["at"] < LIBRARY_EVERY:
        out = dict(last)
    else:
        repos = [r for r in glob.glob(os.path.join(glob.escape(GITEA_REPOS), "*", "*.git"))
                 if not r.endswith(".wiki.git")]
        out = {"repos": len(repos), "bytes": tree_bytes(GITEA_REPOS), "at": int(time.time())}
    # Read every time: it is one listing, and a backup should show at once.
    stamps = [os.path.getmtime(b) for b in glob.glob(os.path.join(GITEA_BACKUPS, "gitea-*.tar.gz"))]
    out["lastBackup"] = int(max(stamps)) if stamps else None
    return out


def use_what(what):
    """What a use was, for the log: a film's title without its position, or
    an action without its speed."""
    if what.startswith('"'):
        return what[:what.index('"', 1) + 1] if '"' in what[1:] else what
    return RATE.sub("", what).strip()


def fold(log, use, at):
    """One sighting of a use into the log: stretches its open line, or starts one."""
    what = use_what(use["what"])
    key = (use["app"], use["who"], use["device"], what)
    same = [e for e in log if (e["app"], e["who"], e["device"], e["what"]) == key and at - e["end"] <= ACTIVITY_GAP]
    if same:
        same[-1]["end"] = max(same[-1]["end"], at)
    else:
        log.append({"app": use["app"], "who": use["who"], "what": what, "device": use["device"],
                    "start": at, "end": at})


def tailnet_backfill(now):
    """The last ACTIVITY_KEEP of pi-paths' journal as log lines, for a log that
    starts empty. Jellyfin is left out: its own activity log covers it."""
    log = []
    for at, msg in journal(["_SYSTEMD_UNIT=pi-paths.service"], now - ACTIVITY_KEEP, now):
        m = PATHS_LINE.match(msg)
        if not m or m.group(1) == "jellyfin":
            continue
        to_them, from_them = float(m.group(5)), float(m.group(6))
        fold(log, {"app": TAILNET_APPS.get(m.group(1), m.group(1)), "who": m.group(2), "device": m.group(3),
                   "what": "uploading" if from_them > to_them else "downloading"}, int(at))
    return log


def jellyfin_history(now, active):
    """Jellyfin's own activity log for the last ACTIVITY_KEEP as log lines:
    each film from "is playing" to "has finished playing", each visit from
    "is online" to "has disconnected". Exact times, Funnel viewers included.
    None without a key or an answer. Something still playing ends now."""
    key, ip = env_value("JELLYFIN_API_KEY"), jellyfin_ip()
    if not key or not ip:
        return None
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - ACTIVITY_KEEP))
    got = jellyfin_get(ip, key, "/System/ActivityLog/Entries?limit=1000&minDate=" + since, 15)
    users = jellyfin_get(ip, key, "/Users")
    if got is None or users is None:
        return None
    names = {u.get("Id"): u.get("Name") for u in users}
    kinds = {"VideoPlayback": (" is playing ", True), "VideoPlaybackStopped": (" has finished playing ", False),
             "SessionStarted": (" is online from ", True), "SessionEnded": (" has disconnected from ", False)}
    watching = {(a["who"], use_what(a["what"])) for a in active if a["app"] == "Jellyfin"}
    log, open_ = [], {}
    for e in sorted(got.get("Items") or [], key=lambda e: e.get("Date") or ""):
        who = names.get(e.get("UserId"))
        kind = kinds.get(e.get("Type"))
        name = e.get("Name") or ""
        if not who or not kind or not name.startswith(who + kind[0]):
            continue
        rest = name[len(who + kind[0]):]
        if e["Type"].startswith("Video"):
            title, _, device = rest.rpartition(" on ")
            what = '"%s"' % title
        else:
            what, device = "browsing", rest
        device = device.replace("+", " ")
        try:
            at = int(datetime.datetime.fromisoformat(e["Date"][:19]).replace(tzinfo=datetime.timezone.utc).timestamp())
        except ValueError:
            continue
        k = (who, what, device)
        if kind[1]:
            if k not in open_:
                open_[k] = {"app": "Jellyfin", "who": who, "what": what, "device": device, "start": at, "end": at}
                log.append(open_[k])
        elif k in open_:
            open_.pop(k)["end"] = at
    for (who, what, _), line in open_.items():
        if (who, what) in watching:
            line["end"] = now
    return log


def activity(active, now):
    """Who used which app and when, newest last, as {app, who, what, device,
    start, end}. Jellyfin comes whole from its own activity log each time;
    everything else is active_list() folded in every 30 seconds, filled from
    pi-paths' journal the first time. A use quiet for ACTIVITY_GAP starts a
    new line, and a film title is part of the line, so two films are two."""
    try:
        with open(ACTIVITY_FILE) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        saved = None
    # A bare list is the first version of this file, which had no backfill.
    if not isinstance(saved, dict):
        saved = {"uses": tailnet_backfill(now)}
    log = [e for e in saved["uses"] if e["app"] != "Jellyfin"]
    for a in active:
        if a["app"] != "Jellyfin":
            fold(log, a, now)
    jf = jellyfin_history(now, active)
    if jf is None:
        jf = [e for e in saved["uses"] if e["app"] == "Jellyfin"]
    log = sorted((e for e in log + jf if now - e["end"] < ACTIVITY_KEEP), key=lambda e: e["start"])[-ACTIVITY_MAX:]
    os.makedirs(DIR, exist_ok=True)
    tmp = ACTIVITY_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"uses": log}, f)
    os.replace(tmp, ACTIVITY_FILE)
    return log


def content():
    """The dashboard's Status tab, written to STATUS_FILE: who is using which
    app (the same as the bot's), and what Jellyfin, Immich, Nextcloud, Kiwix
    and Gitea hold. Run every
    30 seconds by pi-status.timer; the dashboard pod reads the file."""
    try:
        with open(STATUS_FILE) as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = {}
    out = {"ts": int(time.time()), "active": active_list(), "jellyfin": None, "immich": None,
           "nextcloud": None, "kiwix": None, "gitea": None}
    out["users"] = activity(out["active"], out["ts"])

    key, ip = env_value("JELLYFIN_API_KEY"), jellyfin_ip()
    counts = jellyfin_get(ip, key, "/Items/Counts") if key and ip else None
    if counts:
        last = prev.get("jellyfin") or {}
        size, at = last.get("bytes"), last.get("bytesAt") or 0
        if size is None or time.time() - at > LIBRARY_EVERY:
            items = jellyfin_get(ip, key, "/Items?IncludeItemTypes=Movie,Episode&Recursive=true"
                                 "&Fields=MediaSources&EnableImages=false&EnableUserData=false", 60)
            if items is not None:
                size = sum(((i.get("MediaSources") or [{}])[0].get("Size") or 0) for i in items.get("Items") or [])
                at = int(time.time())
        out["jellyfin"] = {"films": counts.get("MovieCount") or 0, "series": counts.get("SeriesCount") or 0,
                           "episodes": counts.get("EpisodeCount") or 0, "bytes": size, "bytesAt": at}

    # Space and counts per user. The key needs only Immich's
    # "server.statistics" permission (Account Settings > API Keys).
    key, ip = env_value("IMMICH_API_KEY"), svc_ip("immich")
    if key and ip:
        req = urllib.request.Request("http://%s/api/server/statistics" % ip, headers={"x-api-key": key})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                st = json.load(r)
            users = [{"name": u.get("userName") or "?", "photos": u.get("photos") or 0,
                      "videos": u.get("videos") or 0, "bytes": u.get("usage") or 0}
                     for u in st.get("usageByUser") or []]
            out["immich"] = {"photos": st.get("photos") or 0, "videos": st.get("videos") or 0,
                             "bytes": st.get("usage") or 0,
                             "users": sorted(users, key=lambda u: -u["bytes"])}
        except (OSError, ValueError):
            pass

    # occ starts PHP once per call, so this is asked every LIBRARY_EVERY too.
    last = prev.get("nextcloud") or {}
    if last.get("at") and time.time() - last["at"] < LIBRARY_EVERY:
        out["nextcloud"] = last
    else:
        users = nextcloud_users()
        if users is not None:
            out["nextcloud"] = {"bytes": sum(u["bytes"] for u in users), "users": users, "at": int(time.time())}
        elif last:
            out["nextcloud"] = last

    # The same files show up under more than one /srv name: /srv/pool is a
    # pool over the drives, which reports its own inode numbers, so a book is
    # one name and size however many paths reach it.
    books = {}
    for path in glob.glob("/srv/*/Kiwix/*.zim"):
        size = os.path.getsize(path)
        books[(os.path.basename(path), size)] = size
    if books:
        out["kiwix"] = {"books": len(books), "bytes": sum(books.values())}

    out["gitea"] = gitea_status(prev)
    accts = accounts((out["nextcloud"] or {}).get("users"))
    out["accounts"] = {"apps": {app: len(users) for app, users in accts.items()}, "people": people(accts)}

    os.makedirs(os.path.dirname(STATUS_FILE), mode=0o755, exist_ok=True)
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATUS_FILE)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("record", "incidents", "--summary", "status", "content"):
        if os.geteuid() != 0:
            sys.exit("run with sudo")
        return {"record": record, "incidents": incidents, "status": status, "content": content,
                "--summary": lambda: print("\n".join(summary()))}[sys.argv[1]]()
    p = argparse.ArgumentParser(prog="pi-when", description="What was happening on the PC around a moment.")
    p.add_argument("time", help='12:15, "yesterday 12:15", "sat 21:40", "2026-10-10 12:15"')
    p.add_argument("app", nargs="?", help="jellyfin, nextcloud, immich, ... (optional)")
    p.add_argument("--who", help="only this user's lines (Tailscale or app user name)")
    p.add_argument("--minutes", type=int, default=10, help="how far either side to look (default 10)")
    args = p.parse_args()
    if os.geteuid() != 0:
        sys.exit("run with sudo")
    lookup(args)


if __name__ == "__main__":
    main()
