# Deploy notes

The commands you actually run are in the [README](../README.md#deploying).
This is what sits behind them.

## The shape

Deploys are a **pull on the PC**, not a push from the Mac. homelab holds a
checkout of this repo at `~/PI`; a deploy is:

```
fetch origin → the branch → build on the PC → install
```

Two ways to start one:

- **In homelab's own shell** (SSH from the Mac or the phone): `cd ~/PI && git
  pull`, then `bash deploy/<script>`. This is the usual way.
- **`make <target>` on the Mac.** Each target SSHes to homelab, takes `~/PI` to
  exactly `origin/<BRANCH>`, and runs the same script. `BRANCH` is the branch
  the Mac's checkout is on, so working on `feat/pc-server` deploys
  `feat/pc-server`. `make <target> BRANCH=main` picks another.

Three consequences worth knowing:

- **The PC is never a source of truth.** `make` uses `reset --hard`, so
  anything edited directly in `~/PI` is gone at the next deploy. Edit the repo,
  push, pull.
- **Check users first.** `sudo pi-when now` says who is watching, uploading or
  using which app. If someone is on the app being touched, wait.
- **It builds on the PC.** The console and the local AI are
  images built with buildkit straight into k3s' containerd: no registry, no
  copy. The tag is the commit, because reusing a tag under
  `imagePullPolicy: IfNotPresent` leaves the old image in place and reports
  success.

`git log --oneline -1` runs as part of every `make` deploy, so the commit that
just landed is printed before the build starts.

## Bootstrapping the PC

```bash
make bootstrap NODE=homelab
```

Run once, and again only after a reinstall. It is idempotent — a second run
verifies rather than replaces. What it does, in order:

1. Generates an ed25519 key on the PC at `~/.ssh/id_PI_deploy` if absent.
2. Registers the public half as a **read-only deploy key** on the repo, via
   `gh`, from the Mac. Read-only: the PC can pull and can never push.
3. Adds a `Host PI.github` alias to the PC's SSH config so that key is used
   for this repo only.
4. Clones to `~/PI` on `BRANCH`, or resets it there if already cloned.

It reuses one SSH connection for all the remote steps, so a password is asked
for once rather than three times.

## When GitHub is unreachable from the PC

Copy the tree from the Mac and run the script from the copy:

```bash
rsync -a --delete --exclude node_modules --exclude dist --exclude .git ./ homelab:~/PI-copy/
```

```bash
ssh homelab 'bash ~/PI-copy/deploy/install-dashboard-k8s.sh ~/PI-copy/dashboard'
```

`--exclude dist` matters: the PC builds its own.

## What `tailscale serve` holds

```
https://homelab.<tailnet>.ts.net        → Traefik on :80, the console
```

`make dashboard-k8s` sets it. Every other app has its own tailnet name from the Tailscale operator:
any Service with an Ingress marked `ingressClassName: tailscale` gets one,
with a real certificate. Jellyfin is also on Funnel; see the README.

`make dashboard` (the old systemd unit) serves on 8080 and does **not** repoint
`tailscale serve` back. Returning to it means `sudo tailscale serve --bg 8080`.

## When something is wrong

On homelab:

```bash
make check                                   # from the Mac: services up, console answering
```

```bash
sudo k3s kubectl -n pi get pods
```

```bash
sudo k3s kubectl -n pi logs deploy/pi-console --tail=40
```

```bash
journalctl -u pi-metrics -n 40 --no-pager
```

A deploy that runs clean but changes nothing on screen — check which commit
the PC is on and which image the console runs. Under k3s the image tag is the
commit:

```bash
git -C ~/PI log --oneline -1
```

```bash
sudo k3s kubectl -n pi get deploy pi-console -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

If a bootstrap fails at the GitHub step, the PC's key exists but is not
registered. `gh repo deploy-key list --repo BasilSuhail/PI` shows what is
registered; re-running `make bootstrap NODE=homelab` reuses the same key.
