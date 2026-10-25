#!/usr/bin/env python3
"""Asks the local AI (k8s/ai.yaml, issue #200) about the PC.

The model gets a fixed list of read-only checks it may call: who is using the
PC, the apps and their logs, the drives and the mirror, temperatures, fans,
the GPU, Uptime Kuma and saved incidents. Each check is a fixed command; the
only thing the model chooses is which one, plus an app or disk name that must
be one of the real ones. It never gets a shell and cannot change anything.

pi-bot uses this for its AI channel. From SSH, as root:

  sudo /usr/local/lib/pi/pi-ask "is everything ok?"

pi-bot runs as its own user, not root. The model and the Discord side stay in
that user; only three fixed things go through sudo, to this same file, which
checks them again as root (see deploy/install-pi-bot.sh for the sudoers rule):

  pi-ask --check NAME ARGS_JSON    one check, validated here
  pi-ask --apps                    the app names a check may be given
  pi-ask --ai-url                  where the local AI listens
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

PI_WHEN = os.environ.get("PI_WHEN", "/usr/local/lib/pi/pi-when")
KUMA_LIST = os.environ.get("KUMA_LIST", "/usr/local/lib/pi/kuma-list")
AI_URL = os.environ.get("AI_URL", "")
# Each check's output is cut to this: the model reads about 100 tokens a
# second, so a long log costs the person half a minute of waiting.
OUT_CHARS = 3000
MAX_ROUNDS = 5

SYSTEM = """You are the assistant for homelab, a home server: a Debian PC running k3s with
family apps (Jellyfin, Immich, Nextcloud, Vaultwarden, Kiwix, ArchiveBox, Gitea,
Uptime Kuma), two SSDs in a RAID1 mirror (Samsung 250GB main, T-Force 512GB backup) and
three hard drives. You answer the admin in a Discord channel.

Use the checks to look before answering anything about the PC's state; never
guess numbers. Say what you saw and what it means, in short plain sentences.
You can only read. You cannot change anything, and you never tell the admin to
run commands that change, delete, repair or restart things: say what you found
and that a person should decide the fix. If the checks do not show the answer,
say so. Keep replies under 15 lines."""


SELF = os.path.realpath(__file__)
ROOT = os.geteuid() == 0


def via_root(*args):
    """The bot's way to a check that needs root: this file again, under sudo,
    for one of the fixed requests at the bottom."""
    return run(["sudo", "-n", SELF, *args])


def run(argv, timeout=60):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        text = (out.stdout + (("\n" + out.stderr) if out.returncode and out.stderr else "")).strip()
    except subprocess.TimeoutExpired:
        text = "(timed out)"
    except OSError as err:
        text = "(could not run: %s)" % err
    return text or "(no output)"


def kube(*args):
    return ["k3s", "kubectl", *args]


def apps():
    if not ROOT:
        try:
            return json.loads(via_root("--apps"))
        except ValueError:
            return []
    out = run(kube("-n", "pi", "get", "deploy", "-o", "jsonpath={.items[*].metadata.name}"), 20)
    return sorted(out.split()) if not out.startswith("(") else []


def disks():
    try:
        return sorted(d for d in os.listdir("/sys/block") if re.fullmatch(r"sd[a-z]+|nvme\d+n\d+", d))
    except OSError:
        return []


def kernel_disk_lines():
    text = run(["journalctl", "-k", "--since", "-48h", "--no-pager", "-o", "short"])
    keep = re.compile(r"ata\d|\bsd[a-z]\b|md\d|I/O error|EXT4|nvme|link (up|down)|reset", re.I)
    return "\n".join(l for l in text.splitlines() if keep.search(l))[-OUT_CHARS:] or "(no disk messages in 48h)"


def fans_temps():
    try:
        with open("/run/pi-fans.json") as f:
            state = json.load(f)
        fans = ", ".join("%s %s%%%s" % (v["label"], round((v.get("duty") or 0) * 100 / 255),
                                       " (manual)" if v.get("manual") else "")
                         for v in state.get("fans", {}).values())
        temps = ", ".join("%s %s°C" % (k, v) for k, v in state.get("temps", {}).items() if v is not None)
        text = "Fans: %s\nTemperatures: %s" % (fans, temps)
    except (OSError, ValueError):
        text = "(fan controller state not available)"
    drives = run(["sh", "-c", "for h in /sys/class/hwmon/hwmon*; do [ \"$(cat $h/name)\" = drivetemp ] && "
                              "echo \"$(ls $h/device/block) $(($(cat $h/temp1_input)/1000))°C\"; done"])
    return text + "\nDrive temperatures: " + drives.replace("\n", ", ")


# name: (description, argument (name, list of allowed values) or None, function)
CHECKS = {
    "overview": ("One-page status: apps running, who is using what, temperatures, trouble in the last day.",
                 None, lambda _: run([PI_WHEN, "status"])),
    "who_is_using": ("Who is using which app right now and how.",
                     None, lambda _: run([PI_WHEN, "now"])),
    "apps": ("Every app's pod: running or not, restarts, age.",
             None, lambda _: run(kube("-n", "pi", "get", "pods", "-o", "wide"))),
    "app_log": ("The last lines of one app's log.",
                ("app", apps), lambda a: run(kube("-n", "pi", "logs", "deploy/" + a, "--tail=80", "--since=12h"))),
    "recent_errors": ("Error-level messages from the whole system in the last 24 hours.",
                      None, lambda _: run(["journalctl", "-p", "err", "--since", "-24h", "-n", "60", "--no-pager", "-o", "short"])),
    "mirror": ("The SSD mirror (RAID1): healthy, degraded or rebuilding.",
               None, lambda _: run(["sh", "-c", "cat /proc/mdstat; for m in /dev/md12[67]; do mdadm --detail $m | tail -5; done"])),
    "drives": ("Every drive: size, model, where it is mounted, how full.",
               None, lambda _: run(["sh", "-c", "lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS; echo; df -h -x tmpfs -x devtmpfs -x overlay -x squashfs"])),
    "disk_health": ("SMART health and error counters of one drive.",
                    ("disk", disks), lambda d: run(["smartctl", "-H", "-A", "/dev/" + d])),
    "disk_kernel_messages": ("Kernel messages about drives and SATA links in the last 48 hours: drop-outs, resets, I/O errors.",
                             None, lambda _: kernel_disk_lines()),
    "temperatures_fans": ("CPU, GPU and drive temperatures, and each fan's speed.",
                          None, lambda _: fans_temps()),
    "gpu": ("The graphics card: load, memory, temperature, and what is using it.",
            None, lambda _: run(["sh", "-c", "nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,fan.speed,"
                                             "utilization.encoder,utilization.decoder --format=csv; "
                                             "nvidia-smi --query-compute-apps=process_name,used_memory --format=csv"])),
    "load": ("CPU load, memory, and the busiest processes.",
             None, lambda _: run(["sh", "-c", "uptime; free -h; ps -eo comm,%cpu,%mem --sort=-%cpu | head -12"])),
    "uptime_kuma": ("Every Uptime Kuma monitor and whether it is up.",
                    None, lambda _: run(["python3", KUMA_LIST])),
    "incidents": ("Trouble the PC saved recently (list of incident files).",
                  None, lambda _: run([PI_WHEN, "incidents"])),
}


def tools():
    out = []
    for name, (desc, arg, _) in CHECKS.items():
        params = {"type": "object", "properties": {}, "required": []}
        if arg:
            params["properties"][arg[0]] = {"type": "string", "enum": arg[1]()}
            params["required"] = [arg[0]]
        out.append({"type": "function", "function": {"name": name, "description": desc, "parameters": params}})
    return out


def call_check(name, raw_args):
    if not ROOT:
        return via_root("--check", name, raw_args or "{}")
    if name not in CHECKS:
        return "(no such check: %s)" % name
    _, arg, fn = CHECKS[name]
    value = None
    if arg:
        try:
            value = (json.loads(raw_args or "{}") or {}).get(arg[0])
        except ValueError:
            value = None
        # The list is read again here, so a name the model invented never
        # reaches a command line.
        if value not in arg[1]():
            return "(%s must be one of: %s)" % (arg[0], ", ".join(arg[1]()))
    text = fn(value)
    return text if len(text) <= OUT_CHARS else "(cut to the last part)\n" + text[-OUT_CHARS:]


def ai_url():
    if AI_URL:
        return AI_URL
    if not ROOT:
        url = via_root("--ai-url")
        if not url.startswith("http://"):
            raise RuntimeError(url)
        return url
    ip = run(kube("-n", "pi", "get", "svc", "ai", "-o", "jsonpath={.spec.clusterIP}"), 20)
    if not re.fullmatch(r"[\d.]+", ip):
        raise RuntimeError("the AI is not installed (no ai Service); run deploy/install-ai.sh")
    return "http://%s:8080" % ip


def chat(messages, think):
    body = {"messages": messages, "tools": tools(), "max_tokens": 1500 if think else 700,
            "chat_template_kwargs": {"enable_thinking": think}}
    req = urllib.request.Request(ai_url() + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    # Long: the first question after ten idle minutes loads the model again.
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)["choices"][0]["message"]


def ask(question, history=(), on_check=None):
    """The answer to `question`, given earlier (user, assistant) turns.
    `on_check(name)` is called before each check, for a progress note."""
    think = question.lower().startswith("think ")
    messages = [{"role": "system", "content": SYSTEM}]
    for q, a in history:
        messages += [{"role": "user", "content": q}, {"role": "assistant", "content": a}]
    messages.append({"role": "user", "content": question[6:] if think else question})
    try:
        for _ in range(MAX_ROUNDS):
            msg = chat(messages, think)
            calls = msg.get("tool_calls") or []
            if not calls:
                return (msg.get("content") or "").strip() or "(no answer)"
            messages.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": calls})
            for c in calls:
                name = c.get("function", {}).get("name", "")
                if on_check:
                    on_check(name)
                messages.append({"role": "tool", "tool_call_id": c.get("id", ""),
                                 "content": call_check(name, c.get("function", {}).get("arguments"))})
        # Out of rounds: one last answer from what it has, with no more checks.
        messages.append({"role": "user", "content": "Answer now from what you have seen."})
        body_msg = chat(messages, False)
        return (body_msg.get("content") or "").strip() or "(no answer)"
    except (urllib.error.URLError, OSError, RuntimeError, ValueError, KeyError) as err:
        return "The AI did not answer: %s" % err


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    # The requests pi-bot makes through sudo. Root only: as anyone else they
    # would only loop back into sudo.
    if ROOT and sys.argv[1] == "--check" and len(sys.argv) == 4:
        print(call_check(sys.argv[2], sys.argv[3]))
        sys.exit()
    if ROOT and sys.argv[1:] == ["--apps"]:
        print(json.dumps(apps()))
        sys.exit()
    if ROOT and sys.argv[1:] == ["--ai-url"]:
        try:
            print(ai_url())
        except RuntimeError as err:
            print(err)
        sys.exit()
    print(ask(" ".join(sys.argv[1:]), on_check=lambda n: print("  checking: %s" % n, file=sys.stderr)))
