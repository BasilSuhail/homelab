#!/usr/bin/env bash
# A Claude Code session on the PC, reachable from claude.ai/code and the
# Claude app (Remote Control), started at boot and again if it exits.
#
#   bash deploy/install-claude-session.sh      (as the owner, not root)
#
# It starts in ~/Workspace, which links to the repos in home, and may also
# read home itself, the SSD archive and every hard drive. Not home directly:
# Claude does not save trust for a home folder, so every boot would stop at
# its "trust this folder?" question. It runs as the owner, in the default
# permission mode: every edit and command still asks first in the chat.
# Stop it with: systemctl --user stop claude-session
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "run as the owner, without sudo" >&2; exit 1; }
CLAUDE="$HOME/.local/bin/claude"
[ -x "$CLAUDE" ] || { echo "no $CLAUDE: install Claude Code and log in first" >&2; exit 1; }

echo "==> ~/Workspace"
WORKSPACE="$HOME/Workspace"
mkdir -p "$WORKSPACE"
for repo in homelab; do
  [ -e "$HOME/$repo" ] && ln -sfn "$HOME/$repo" "$WORKSPACE/$repo"
done
ls "$WORKSPACE" | sed 's/^/  /'

echo "==> What the session may read, besides ~/Workspace"
# Merged into the user settings, keeping what is there. A copy of the old
# file goes next to it.
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] && cp -p "$SETTINGS" "$SETTINGS.pre-claude-session"
python3 - "$SETTINGS" <<'MERGE'
import json, os, sys
path = sys.argv[1]
want = [os.path.expanduser("~"), "/1) Archive", "/srv/storage", "/srv/hdd2", "/srv/hdd1", "/srv/pool"]
data = json.load(open(path)) if os.path.exists(path) else {}
dirs = data.setdefault("permissions", {}).setdefault("additionalDirectories", [])
dirs += [d for d in want if d not in dirs and os.path.isdir(d)]
json.dump(data, open(path, "w"), indent=2)
print("  " + ", ".join(dirs))
MERGE

echo "==> Service"
UNIT="$HOME/.config/systemd/user/claude-session.service"
mkdir -p "$(dirname "$UNIT")"
cat >"$UNIT" <<'UNIT'
[Unit]
Description=Claude Code session on the PC (Remote Control, claude.ai/code)

[Service]
# tmux gives it the terminal it expects and lets the owner look in:
# tmux attach -t claude
Type=forking
WorkingDirectory=%h/Workspace
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/tmux new-session -d -s claude -c %h/Workspace "claude remote-control --name homelab --spawn=same-dir"
ExecStop=/usr/bin/tmux kill-session -t claude
# Also after a clean exit, and while the network is not up yet at boot.
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
UNIT

# A session started by hand under the same name would hold the tmux name.
tmux has-session -t claude 2>/dev/null && tmux kill-session -t claude
systemctl --user daemon-reload
systemctl --user enable --now claude-session.service
sleep 10
tmux capture-pane -p -t claude | grep -v '^$' | tail -6
echo
echo "First run only: if it asks to trust ~/Workspace, answer it once with"
echo "  tmux attach -t claude    (y, Enter, then Ctrl-b d to leave it running)"
