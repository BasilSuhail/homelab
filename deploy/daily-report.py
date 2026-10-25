#!/usr/bin/env python3
"""The morning report: what went wrong on the PC in the last 24 hours.

Reads what the system already records and posts one short Discord message.
Nothing is posted when there is nothing to say. Rules, not guesses: every line
in the message comes from a log entry, a counter or a reading.

  failed services, crashed or restarted apps, apps not running
  disk errors, disks filling up, hot drives or CPU, fan fail-safes
  a reboot during the day
  error messages that were not there the day before
  family devices reaching the apps through a slow relay (pi-paths)
  Jellyfin: failed logins, new devices, public access switched off (jellyfin-guard)
  trouble pi-when caught and saved to a file while nobody was watching
  on Mondays, the to-do list in /etc/pi-report/todo.txt

Config: /etc/pi-report/env (DISCORD_WEBHOOK=...). State, for spotting new
errors: /var/lib/pi-report/state.json. Stdlib only; changes nothing.

  --dry     print the message instead of posting it
  --always  post even when there is nothing to report
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

CONF_DIR = os.environ.get("REPORT_CONF", "/etc/pi-report")
STATE = os.environ.get("REPORT_STATE", "/var/lib/pi-report/state.json")
HWMON = "/sys/class/hwmon"
KUBECTL = ["k3s", "kubectl"]
DAY = 24 * 3600

DISK_FULL_PCT = 90
DRIVE_HOT_C = 50
CPU_HOT_C = 85
# Filesystems worth watching; the rest are memory, containers and the kernel's.
REAL_FS = {"ext4", "xfs", "btrfs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk"}
# Kernel lines that mean a disk or filesystem is in trouble, new or not.
DISK_TROUBLE = re.compile(r"I/O error|EXT4-fs error|Buffer I/O|critical medium error|failed command: (READ|WRITE)|"
                          r"Remounting filesystem read-only|blk_update_request", re.I)
# What makes an app's log line an error.
POD_ERROR = re.compile(r"\b(ERR|ERROR|FATAL|CRIT|CRITICAL|PANIC|panic|Exception|Traceback)\b")
# Error lines that are normal. Nextcloud saves a file's record by trying an
# insert and updating when the row already exists; Postgres still logs the
# refused insert. Nextcloud Office does this hourly for its cached discovery.
POD_NORMAL = re.compile(r'unique constraint "(oc_filecache_extended_pkey|fs_storage_path_hash)"')


def sh(args, timeout=60):
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


def signature(text):
    """An error message with its changing parts (times, numbers, ids) removed,
    so the same error on two days counts as the same error."""
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    text = re.sub(r"^\S*\d{2}:\d{2}:\d{2}\S*\s*", "", text)
    text = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<id>", text, flags=re.I)
    text = re.sub(r"\b[0-9a-f]{12,}\b", "<id>", text, flags=re.I)
    text = re.sub(r"\d+", "N", text)
    return re.sub(r"\s+", " ", text).strip()[:140]


def ago(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%a %H:%M")


# ---- checks: each returns a list of lines for the message ----

def failed_units():
    out = sh(["systemctl", "--failed", "--plain", "--no-legend", "--no-pager"])
    return ["Failed service: %s" % line.split()[0] for line in out.splitlines() if line.split()]


def pods():
    raw = sh(KUBECTL + ["get", "pods", "-A", "-o", "json"])
    if not raw:
        return ["Could not ask k3s about the apps"]
    lines = []
    now = time.time()
    up = float((read("/proc/uptime") or "0").split()[0])
    boot = now - up if up else 0
    for p in json.loads(raw)["items"]:
        name = p["metadata"]["name"]
        phase = p["status"].get("phase")
        if phase == "Succeeded":
            continue
        app = re.sub(r"-[a-z0-9]{8,10}-[a-z0-9]{5}$|-[a-z0-9]{5}$|-\d+$", "", name)
        if phase != "Running":
            lines.append("App not running: %s (%s)" % (app, phase))
            continue
        for c in p["status"].get("containerStatuses") or []:
            term = (c.get("lastState") or {}).get("terminated") or {}
            end = term.get("finishedAt")
            if end:
                t = datetime.datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp()
                # Everything stops when the PC restarts; reboot() says that once.
                if now - t < DAY and not abs(t - boot) < 600:
                    lines.append("App restarted: %s at %s (%s, %d restarts in all)" % (
                        app, ago(t), term.get("reason") or "exit %s" % term.get("exitCode"), c.get("restartCount", 0)))
            if not c.get("ready") and not term:
                lines.append("App not ready: %s" % app)
    return sorted(set(lines))


def kernel():
    out = sh(["journalctl", "-k", "--since", "-24h", "--no-pager", "-o", "cat"])
    lines = []
    # "Out of memory" for the whole PC, "Memory cgroup out of memory" for one
    # app over its own limit.
    oom = [l for l in out.splitlines() if re.search(r"out of memory: Killed process", l, re.I)]
    for l in oom[-3:]:
        m = re.search(r"\(([^)]+)\)", l)
        lines.append("Out of memory: the kernel killed %s%s" % (
            m.group(1) if m else "a process", " (over its app's memory limit)" if "cgroup" in l else ""))
    trouble = [l for l in out.splitlines() if DISK_TROUBLE.search(l)]
    if trouble:
        lines.append("Disk errors: %d kernel lines, last: %s" % (len(trouble), trouble[-1].strip()[:120]))
    return lines


def disks():
    lines, seen = [], set()
    for row in (read("/proc/mounts") or "").splitlines():
        dev, mnt, fs = row.split()[:3]
        if fs not in REAL_FS or dev in seen:
            continue
        seen.add(dev)
        mnt = mnt.replace("\\040", " ")
        try:
            st = os.statvfs(mnt)
        except OSError:
            continue
        if not st.f_blocks:
            continue
        pct = 100 * (1 - st.f_bavail / st.f_blocks)
        if pct >= DISK_FULL_PCT:
            lines.append("Disk %s is %.0f%% full (%.0f GB left)" % (mnt, pct, st.f_bavail * st.f_frsize / 1e9))
    return lines


def temps():
    lines = []
    try:
        chips = sorted(os.listdir(HWMON))
    except OSError:
        chips = []
    for c in chips:
        name = read(os.path.join(HWMON, c, "name"))
        raw = read(os.path.join(HWMON, c, "temp1_input"))
        if not raw:
            continue
        t = int(raw) / 1000
        if name == "drivetemp" and t >= DRIVE_HOT_C:
            model = read(os.path.join(HWMON, c, "device", "model")) or c
            lines.append("Drive hot: %s at %.0f°C" % (model, t))
        if name in ("k10temp", "coretemp") and t >= CPU_HOT_C:
            lines.append("CPU hot: %.0f°C right now" % t)
    out = sh(["journalctl", "-u", "pi-fans", "--since", "-24h", "--no-pager", "-o", "cat"])
    safe = [l for l in out.splitlines() if l.startswith("fail-safe")]
    if safe:
        lines.append("Fan control gave the fans back to the BIOS %d× (last: %s)" % (len(safe), safe[-1][11:80]))
    return lines


def reboot():
    up = float((read("/proc/uptime") or "0").split()[0])
    if 0 < up < DAY:
        return ["The PC restarted at %s (every app restarted with it)" % ago(time.time() - up)]
    return []


def errors():
    """Every error signature seen today, by source."""
    seen = {}
    out = sh(["journalctl", "-p", "err", "--since", "-24h", "--no-pager", "-o", "json"])
    for line in out.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        src = e.get("SYSLOG_IDENTIFIER") or e.get("_SYSTEMD_UNIT") or "system"
        msg = e.get("MESSAGE")
        if isinstance(msg, str) and msg:
            key = "%s: %s" % (src, signature(msg))
            seen[key] = seen.get(key, 0) + 1
    raw = sh(KUBECTL + ["get", "pods", "-A", "-o", "json"])
    for p in (json.loads(raw)["items"] if raw else []):
        if p["status"].get("phase") != "Running":
            continue
        ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
        app = re.sub(r"-[a-z0-9]{8,10}-[a-z0-9]{5}$|-[a-z0-9]{5}$|-\d+$", "", name)
        for c in p["spec"]["containers"]:
            logs = sh(KUBECTL + ["-n", ns, "logs", name, "-c", c["name"], "--since=24h"], timeout=120)
            for l in logs.splitlines():
                # Stack-trace lines repeat the error above them.
                if l.startswith((" ", "\t")) or not POD_ERROR.search(l) or POD_NORMAL.search(l):
                    continue
                key = "%s: %s" % (app, signature(l))
                seen[key] = seen.get(key, 0) + 1
    return seen


def new_errors(today, state):
    if "errors" not in state:
        return [], True
    known = set(state["errors"])
    fresh = sorted(((n, k) for k, n in today.items() if k not in known), reverse=True)
    lines = ["%s (×%d)" % (k[:160], n) for n, k in fresh[:8]]
    if len(fresh) > 8:
        lines.append("and %d more new ones" % (len(fresh) - 8))
    return lines, False


PATH_LINE = re.compile(r"^(\S+)\s+(.+?) / (\S+)\s+(RELAY \S+|peer relay \S+|direct, at home \S+|direct \S+)"
                       r"\s+to them\s+([\d.]+) Mbit/s\s+from them\s+([\d.]+) Mbit/s")


def relays():
    """Minutes each device spent on a relay while using an app, from pi-paths."""
    out = sh(["journalctl", "-u", "pi-paths", "--since", "-24h", "--no-pager", "-o", "json"])
    use = {}
    for line in out.splitlines():
        try:
            e = json.loads(line)
            m = PATH_LINE.match(e.get("MESSAGE") or "")
        except (ValueError, TypeError):
            continue
        if not m:
            continue
        app, who, host, path, to_them, from_them = m.groups()
        minute = int(e["__REALTIME_TIMESTAMP"]) // 60_000_000
        d = use.setdefault((who, host), {"relay": set(), "direct": set(), "where": set(), "apps": set(), "peak": 0.0})
        relay = path.startswith("RELAY")
        d["relay" if relay else "direct"].add(minute)
        if relay:
            d["where"].add(path.split()[1])
            d["apps"].add(app)
            d["peak"] = max(d["peak"], float(to_them), float(from_them))
    lines = []
    for (who, host), d in sorted(use.items()):
        if d["relay"]:
            lines.append("%s (%s): %d min through relay %s on %s, at most %.1f Mbit/s; %d min direct" % (
                who, host, len(d["relay"]), "/".join(sorted(d["where"])), ", ".join(sorted(d["apps"])),
                d["peak"], len(d["direct"])))
    return lines


GUARD = "/usr/local/lib/pi/jellyfin-guard"


def jellyfin_logins():
    """Failed logins, new devices and Funnel shut-offs, from jellyfin-guard."""
    if not os.access(GUARD, os.X_OK):
        return []
    return [l for l in sh([GUARD, "--summary"]).splitlines() if l.strip()]


WHEN = "/usr/local/lib/pi/pi-when"


def incidents():
    """Trouble pi-when saved in the last day, one line each with its file."""
    if not os.access(WHEN, os.X_OK):
        return []
    lines = [l for l in sh([WHEN, "--summary"]).splitlines() if l.strip()]
    return lines + ["Read: sudo pi-when incidents, then cat the file"] if lines else []


def todo():
    if datetime.date.today().weekday() != 0:
        return []
    text = read(os.path.join(CONF_DIR, "todo.txt")) or ""
    return [l.strip().lstrip("-• ").strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]


# ---- message ----

def message(sections):
    host = os.uname().nodename
    out = ["**%s — morning report, %s**" % (host, datetime.date.today().strftime("%a %d %b"))]
    for title, lines in sections:
        if lines:
            out.append("")
            out.append("**%s**" % title)
            out += ["• " + l for l in lines]
    return "\n".join(out)


def post(text, webhook):
    # Discord takes 2000 characters per message.
    chunks, cur = [], ""
    for line in text.splitlines():
        if len(cur) + len(line) + 1 > 1900:
            chunks.append(cur)
            cur = ""
        cur += line + "\n"
    chunks.append(cur)
    for c in chunks:
        req = urllib.request.Request(webhook, data=json.dumps({"content": c}).encode(),
                                     headers={"Content-Type": "application/json", "User-Agent": "pi-report"})
        urllib.request.urlopen(req, timeout=20).read()
        time.sleep(1)


def webhook():
    for line in (read(os.path.join(CONF_DIR, "env")) or "").splitlines():
        if line.startswith("DISCORD_WEBHOOK="):
            return line.split("=", 1)[1].strip().strip('"')
    return None


def main():
    dry, always = "--dry" in sys.argv, "--always" in sys.argv
    try:
        with open(STATE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}

    today = errors()
    fresh, first = new_errors(today, state)
    problems = failed_units() + pods() + kernel() + disks() + temps() + reboot()
    sections = [
        ("Problems", problems),
        ("New errors (not seen the day before)", fresh),
        ("Slow connections", relays()),
        ("Jellyfin logins", jellyfin_logins()),
        ("Trouble caught (saved in /var/lib/pi-when/incidents)", incidents()),
    ]
    sections.append(("To do (Mondays)", todo()))
    found = any(lines for _, lines in sections)
    if first:
        sections.append(("Note", ["First run: today's errors are the baseline; new ones are reported from tomorrow"]))

    text = message(sections)
    if not found and not always:
        print("nothing to report")
    elif dry:
        print(text)
    else:
        hook = webhook()
        if not hook:
            print("no DISCORD_WEBHOOK in %s/env" % CONF_DIR, file=sys.stderr)
            sys.exit(1)
        post(text, hook)
        print("posted:\n" + text)

    if not dry:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        # Yesterday's and today's errors both count as known, so an error that
        # skips a day is not announced as new when it returns.
        known = {k: 1 for k in list(state.get("errors", {}))[-3000:]}
        known.update(today)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"errors": known, "at": int(time.time())}, f)
        os.replace(tmp, STATE)


if __name__ == "__main__":
    main()
