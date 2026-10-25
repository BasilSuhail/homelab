# Deploys. Each target is one command that takes the PC to whatever is on
# BRANCH — it pulls, builds, and installs itself. `make` lists them.
#
# First time on a node:  make bootstrap NODE=homelab
# Every time after:      make dashboard-k8s

# homelab, the PC that replaced both boards, by default. Name another node to
# reach it: NODE=..., AGENT_NODES="a b", STORAGE_NODES="a b".
NODE ?= homelab
DASH_NODE ?= homelab
AGENT_NODES ?= homelab
# Boards with disks worth exposing. Kept separate from AGENT_NODES because a
# node can run an agent without holding anything you want to browse.
STORAGE_NODES ?= homelab
REPO_DIR ?= homelab
DASH_URL ?= https://homelab.<tailnet>.ts.net

# The branch the node deploys: the one this Mac's checkout is on, so the work
# on feat/pc-server deploys from there and not from an older main.
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -vx HEAD || echo main)

# Take the node's checkout to exactly origin/$(BRANCH). Deterministic on
# purpose: what is on the node afterwards is what is on that branch, anything
# edited on the node included. Edit the repo, not the node.
# Fails with a usable sentence rather than a git fatal when the board has no
# checkout yet — that is the one-time bootstrap, and it is easy to skip.
SYNC = { [ -d ~/$(REPO_DIR)/.git ] || { echo "no checkout on this board — run: make bootstrap NODE=<node>" >&2; exit 2; }; } \
 && git -C ~/$(REPO_DIR) fetch --quiet origin \
 && git -C ~/$(REPO_DIR) checkout --quiet -B $(BRANCH) origin/$(BRANCH) \
 && git -C ~/$(REPO_DIR) reset --hard --quiet origin/$(BRANCH) \
 && git -C ~/$(REPO_DIR) log --oneline -1

# One board failing used to abandon the rest of the loop, so a problem on the
# first node silently became a problem on every node. Each board gets its turn
# and the failures are reported together at the end.
define on_storage_nodes
	failed=""; \
	for node in $(STORAGE_NODES); do \
		echo "==> $$node"; \
		ssh $$node '$(SYNC) && bash ~/$(REPO_DIR)/$(1)' || failed="$$failed $$node"; \
	done; \
	if [ -n "$$failed" ]; then echo; echo "Failed on:$$failed" >&2; exit 1; fi
endef

.PHONY: help dashboard dashboard-k8s uptime vault vault-backup cloud pool media photos torrent torrent-on torrent-off archivebox agents deploy check logs bootstrap archive automount browse wifi samba mounts sata quiet hw-watchdog fans gpu paths report direct guard when bot watchdog ai gitea

help:
	@echo "make dashboard-k8s   dashboard/ or deploy/ changed — this is what runs"
	@echo "make dashboard       the old systemd unit, kept as the way back. Not both."
	@echo "make uptime          Uptime Kuma on its own tailnet name, asks for an OAuth client once"
	@echo "make vault           Vaultwarden on its own tailnet name, needs make uptime first"
	@echo "make vault-backup    daily 12:00 vault backup: SSD, then HDD2"
	@echo "make pool            join the data disks into one folder (mergerfs), /srv/pool"
	@echo "make cloud           Nextcloud: family files with per-person limits, needs make pool"
	@echo "make media           Jellyfin and Kiwix, and moves all four apps' data onto the 6TB"
	@echo "make photos          Immich on its own tailnet name. The phone backs up to it"
	@echo "make torrent         qBittorrent behind AirVPN, installed stopped. Asks for the keys once"
	@echo "                     VPN_COUNTRIES=\"Netherlands\" picks where the tunnel comes out"
	@echo "make torrent-on      Start it without the console. make torrent-off stops it"
	@echo "make archivebox      ArchiveBox on its own tailnet name. Asks for an admin login once"
	@echo "make gitea           Gitea (Git) on its own tailnet name. Asks for the admin once; backups: sudo gitea-backup"
	@echo "make agents          agent/ changed — AGENT_NODES (homelab)"
	@echo "make deploy          dashboard-k8s and agents together"
	@echo "make check           services up, dashboard answering"
	@echo "make logs            last 40 lines from the dashboard, systemd or k3s"
	@echo "make archive               create '/1) Archive' on STORAGE_NODES (homelab), once"
	@echo "make automount             plugged-in drives mount themselves, once"
	@echo "make browse                rebuild /srv/browse on STORAGE_NODES (homelab)"
	@echo "make wifi                  stop the wifi radio sleeping between packets, STORAGE_NODES"
	@echo "make samba NODE=homelab      share that board's disks over SMB, asks for a password"
	@echo "make mounts                Mac only, once: shares mount while Tailscale is up"
	@echo "make watchdog                  Pi-era Jellyfin breaker, locks users out: not installed on homelab"
	@echo "make quiet                     midnight–6 AM: maintenance to daytime (IMMICH_QUIET=1 pauses Immich)"
	@echo "make hw-watchdog               the board reboots itself if it hangs (SP5100 on the PC)"
	@echo "make fans                      fans by temperature instead of the BIOS floor (needs it87)"
	@echo "make gpu                       NVIDIA card into k3s; Jellyfin transcodes on it"
	@echo "make ai                        local AI (llama.cpp + Qwen3.5-4B) on the GPU, issue #200"
	@echo "make paths                     watcher: does each family device reach the apps direct or by relay"
	@echo "make report                    08:00 Discord report of what went wrong, silent on a quiet day"
	@echo "make direct                    app proxies stop looking like a strict NAT, so family devices can go direct"
	@echo "make guard                     Jellyfin's public access off, with a Discord post, when strangers try to log in"
	@echo "make sata NODE=pi2       report the PCIe port and the SATA HAT. Changes nothing."
	@echo "make bootstrap NODE=homelab  once per node: deploy key + checkout"
	@echo
	@echo "Tailscale has to be up. Each target asks for the board's password once."

dashboard:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-dashboard.sh ~/$(REPO_DIR)/dashboard'

# -t because the first run asks for a Tailscale API key: a pod has no
# tailscaled socket, so node discovery has to use the API.
dashboard-k8s:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-dashboard-k8s.sh ~/$(REPO_DIR)/dashboard'

# -t because the first run asks for a Tailscale OAuth client, which the
# operator needs before it can put a Service on the tailnet under its own name.
uptime:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-uptime-kuma.sh'

# Needs the Tailscale operator, which `make uptime` installs. No prompts of its
# own: registration opens for the first account and is closed by hand after.
vault:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-vaultwarden.sh'

# Override the HDD copy's disk:  make vault-backup BACKUP_MOUNT=/srv/other
vault-backup:
	ssh $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(BACKUP_MOUNT),BACKUP_MOUNT="$(BACKUP_MOUNT)" ,)bash ~/$(REPO_DIR)/deploy/install-vault-backup.sh'

# Joins the data disks into one folder. Add a disk later:
#   make pool POOL_BRANCHES=/srv/hdd2:/srv/hdd3
pool:
	ssh -t $(DASH_NODE) '$(SYNC) && $(if $(POOL_BRANCHES),POOL_BRANCHES="$(POOL_BRANCHES)" ,)bash ~/$(REPO_DIR)/deploy/setup-pool.sh'

# Nextcloud on the pool. Override where things land:
#   make cloud POOL_DIR=/srv/pool APPS_DIR=/somewhere/else
cloud:
	ssh $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(POOL_DIR),POOL_DIR="$(POOL_DIR)" ,)bash ~/$(REPO_DIR)/deploy/install-nextcloud.sh'

# Jellyfin and Kiwix, plus the storage move for Vaultwarden and Uptime Kuma.
# Override where things land:  make media DATA_DIR=/somewhere/else
# Kiwix's .zim files on another disk:  make media WIKI_DIR=/srv/hdd2
media:
	ssh $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(DATA_DIR),DATA_DIR="$(DATA_DIR)" ,)$(if $(WIKI_DIR),WIKI_DIR="$(WIKI_DIR)" ,)bash ~/$(REPO_DIR)/deploy/install-media.sh'

# Immich: the photo library, and what the phone backs up to. Four containers
# and a Postgres of its own, so it wants the operator like the rest.
# Override where things land:  make photos DATA_DIR=/somewhere/else
photos:
	ssh $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(DATA_DIR),DATA_DIR="$(DATA_DIR)" ,)bash ~/$(REPO_DIR)/deploy/install-immich.sh'

# Interactive: asks for the admin password on the first run.
archivebox:
	ssh -t $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(DATA_DIR),DATA_DIR="$(DATA_DIR)" ,)bash ~/$(REPO_DIR)/deploy/install-archivebox.sh'

# Interactive: asks for the admin's username and email on the first run.
gitea:
	ssh -t $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(DATA_DIR),DATA_DIR="$(DATA_DIR)" ,)bash ~/$(REPO_DIR)/deploy/install-gitea.sh'

# Interactive: asks for the WireGuard keys on the first run.
torrent:
	ssh -t $(DASH_NODE) '$(SYNC) && $(if $(APPS_DIR),APPS_DIR="$(APPS_DIR)" ,)$(if $(DATA_DIR),DATA_DIR="$(DATA_DIR)" ,)$(if $(VPN_COUNTRIES),VPN_COUNTRIES="$(VPN_COUNTRIES)" ,)bash ~/$(REPO_DIR)/deploy/install-torrent.sh'

# The same switch the console's button throws, from here instead. Kept so the
# button is optional: delete the RoleBinding in k8s/qbittorrent.yaml and the
# console loses its only cluster write while these two still work.
torrent-on:
	@ssh $(DASH_NODE) 'sudo k3s kubectl -n pi scale deployment/qbittorrent --replicas=1'
torrent-off:
	@ssh $(DASH_NODE) 'sudo k3s kubectl -n pi scale deployment/qbittorrent --replicas=0'

agents:
	@for node in $(AGENT_NODES); do \
		echo "==> $$node"; \
		ssh $$node '$(SYNC) && bash ~/$(REPO_DIR)/agent/install.sh' || exit 1; \
	done

# The k3s dashboard, not the systemd one. `deploy` used to chain `dashboard`,
# which installs the systemd unit — so the everyday convenience target quietly
# installed the way back and left the board holding both, which is the one
# thing the README says not to do. It now runs whatever is actually live.
deploy: dashboard-k8s agents

# The dashboard is asked about separately from the agents. It runs either as a
# systemd unit or as a Deployment depending on which target was last used, and
# neither target records which — so the board is asked rather than assumed.
check:
	@for node in $(AGENT_NODES); do echo "$$node:"; ssh $$node 'systemctl is-active glances pi-metrics' || true; done
	@ssh $(DASH_NODE) 'bash ~/$(REPO_DIR)/deploy/dashboard-status.sh status' \
	  || echo "dashboard: could not ask $(DASH_NODE) — is its checkout current?"
	@curl -s -o /dev/null -w 'dashboard url: %{http_code}\n' $(DASH_URL)/api/nodes
	@echo "Want: two active on each board, the dashboard installed one way not two, 200 from the URL."

logs:
	@ssh $(DASH_NODE) 'bash ~/$(REPO_DIR)/deploy/dashboard-status.sh logs'

archive:
	@$(call on_storage_nodes,deploy/setup-archive.sh)

automount:
	@$(call on_storage_nodes,deploy/setup-automount.sh)

browse:
	@$(call on_storage_nodes,deploy/setup-browse.sh)

# Both boards, because both are on wlan0 and both serve something.
wifi:
	@$(call on_storage_nodes,deploy/tune-wifi.sh)

# Interactive: smbpasswd prompts on the board, so this one wants a terminal
# and cannot be looped silently. One node at a time, on purpose.
samba:
	ssh -t $(NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-samba.sh'

# Runs on the Mac and touches only the Mac: mount points, a keychain entry per
# board, and an agent that keeps the mounts in step with the tailnet.
mounts:
	STORAGE_NODES="$(STORAGE_NODES)" bash deploy/install-share-mounts.sh

# Interactive: asks for the Jellyfin API key on the first run.
watchdog:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-watchdog.sh'

quiet:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-quiet-hours.sh'

hw-watchdog:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/setup-hw-watchdog.sh'

# The NVIDIA card for containers, and Jellyfin transcoding on it.
gpu:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/setup-gpu.sh'

# The PC's fans by temperature instead of the BIOS floor. Needs the it87 driver.
fans:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-fan-curve.sh'

# Every minute, how each family device in use reaches the apps: direct or relay.
paths:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-tailnet-paths.sh'

# What went wrong in the last 24 hours, to Discord at 08:00. Reuses Uptime Kuma's webhook.
report:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-daily-report.sh'

# Pod UDP keeps its source port, so the app proxies can get direct paths.
direct:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-easy-nat.sh'

# Funnel off and a Discord post when strangers try Jellyfin's login. Needs make report.
guard:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-jellyfin-guard.sh'

# The PC every minute for 14 days, and "sudo pi-when 12:15 nextcloud" to look back.
when:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-pi-when.sh'

bot:
	ssh -t $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-pi-bot.sh'

# The local AI on the GPU (issue #200). The first run compiles llama.cpp.
ai:
	ssh $(DASH_NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/install-ai.sh'

bootstrap:
	BRANCH=$(BRANCH) bash deploy/bootstrap-node.sh $(NODE)

# Read-only. It prints the config.txt line to add rather than adding it, since
# a wrong line there stops the board booting and there is no monitor on it.
sata:
	ssh $(NODE) '$(SYNC) && bash ~/$(REPO_DIR)/deploy/check-sata-hat.sh'
