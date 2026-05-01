# Remote User Setup

How to onboard a remote user — someone who works from their own laptop and
connects to the workstation for the GPU stack and the opencode agent. Zed
runs locally on the laptop; opencode runs on the workstation; edit-predictions
hit the workstation's `llama-coder` over LAN/WireGuard.

This is a superset of `docs/second-user-setup.md`. For a user who sits at the
workstation (or SSHes in and runs Zed on the workstation itself), follow that
doc instead.

## Overview

End state:

- A dedicated user account on the workstation, with polkit grants to start/stop
  llama services.
- The user's laptop on the home WireGuard VPN.
- Zed installed on the laptop, running against an isolated profile.
- Edit-predictions in laptop-Zed pointed at `http://<workstation-ip>:11438/v1/completions`.
- The opencode ACP agent running on the workstation, launched by Zed via SSH.
- The laptop's `$HOME` reverse-mounted onto the workstation at
  `/mnt/<user>-laptop` over SSHFS. A `~/Projects` symlink on the workstation
  makes laptop-side paths resolve transparently.
- A one-click desktop launcher on the laptop that wakes the workstation
  (WoL), starts the llama services, and opens Zed.

## Architecture

```
  ┌────────────── laptop ──────────────┐         ┌──────────── workstation ────────────┐
  │                                    │         │                                     │
  │  Zed (isolated profile)            │  WG/    │  llama-primary  :11434             │
  │   ├─ edit-predictions ─────────────┼─ LAN ──▶│  llama-secondary:11435             │
  │   │                                │         │  llama-embed    :11437             │
  │   └─ agent_servers.opencode ───────┼─ ssh ──▶│  llama-coder    :11438 (0.0.0.0)   │
  │       (~/bin/opencode-remote-      │         │                                     │
  │        session)                    │         │  opencode-patched (ACP over stdio)  │
  │                                    │         │                                     │
  │  ~/Projects/foo/  ◀─── sshfs ──────┼────────▶│  /mnt/<user>-laptop/Projects/foo/   │
  │  (laptop-side paths)               │         │  ~/Projects → /mnt/<user>-laptop/   │
  │                                    │         │              Projects (symlink)     │
  └────────────────────────────────────┘         └─────────────────────────────────────┘
```

The SSHFS mount is initiated by the workstation against the laptop (reverse
mount). The laptop must be reachable from the workstation; the WireGuard
tunnel guarantees this even when the home router enables WiFi AP client
isolation.

## Prerequisites

- Workstation already installed per `docs/install.md` (system pieces in place:
  llama.cpp, models, systemd units, polkit rule, opencode-patched, llama-shutdown).
- WireGuard server reachable on the home network. The remote user has a peer
  config that gives them an IP on the WG subnet.
- Workstation reachable from the laptop on at least one of: LAN IP,
  WireGuard IP. Both must be reachable in the reverse direction too (this
  is the gotcha — most home-router LANs block this, WG bypasses it).
- The remote user has SSH access to the workstation (or you do, on their
  behalf, for Phase A).

## Phase A — Workstation onboarding

Run as an admin with sudo on the workstation. Replace `<user>` throughout.

### A1. Create the user account

```
sudo adduser <user>
```

### A2. Add the user to the polkit allowed list

Edit `/etc/polkit-1/rules.d/10-llama-services.rules` and extend the username
condition (or `allowedUsers` array, depending on the deployed rule):

```js
if (subject.user === "<admin>" || subject.user === "<user>") {
    return polkit.Result.YES;
}
```

polkit picks up rule changes without a reload. See `docs/repo-issues.md` for
the planned fix that templates this from `system.env`.

### A3. Run the onboarding script

`scripts/onboard-user.sh` automates the user-space pieces (clone, env files,
AGENTS.md symlink, Library copy + `uv sync`, Zed isolated profile). Run it as
root from the source-of-truth clone:

```
cd ~/Documents/Repos/2gpu-local-ai-workstation
sudo ./scripts/onboard-user.sh <user>
```

It is idempotent. See the script's header comment for the exact list of
steps and `docs/second-user-setup.md` for the same steps spelled out by hand.

### A4. Replace AGENTS.md symlink with a copy

opencode does not follow the symlink for global agent rules. Replace the
symlink that `onboard-user.sh` created with a copy:

```
sudo -u <user> rm /home/<user>/.config/opencode/AGENTS.md
sudo -u <user> cp /home/<user>/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md \
                  /home/<user>/.config/opencode/AGENTS.md
```

Re-copy after upstream changes to the canonical `configs/opencode/AGENTS.md`.

### A5. Verify the Library venv is built

`onboard-user.sh` runs `uv sync`, but a half-built `.venv/bin/` from a prior
attempt can cause `permission denied` at MCP startup. Confirm:

```
sudo -u <user> bash -c '
  cd /home/<user>/Documents/Repos/2gpu-local-ai-workstation/Library
  ls -la .venv/bin/python
  /home/<user>/.local/bin/uv run --project . library --help
'
```

If `.venv/bin/python` is missing or the `--help` invocation fails, blow it
away and re-sync:

```
sudo -u <user> bash -c '
  cd /home/<user>/Documents/Repos/2gpu-local-ai-workstation/Library
  rm -rf .venv
  /home/<user>/.local/bin/uv sync
'
```

### A6. Create the SSHFS mountpoint

The mountpoint must exist with the user's ownership. The
`opencode-remote-session` script does NOT `sudo mkdir` — it would fail when
Zed launches it without a TTY.

```
sudo mkdir -p /mnt/<user>-laptop
sudo chown <user>:<user> /mnt/<user>-laptop
```

### A7. Create the `~/Projects` symlink

So that laptop paths like `/home/<user>/Projects/foo` resolve on the
workstation side under `/mnt/<user>-laptop/Projects/foo`:

```
sudo -u <user> ln -sfn /mnt/<user>-laptop/Projects /home/<user>/Projects
```

The target may not exist yet (the SSHFS mount is created lazily by
`opencode-remote-session`). That is fine; the symlink resolves once the
mount is up.

### A8. Generate the workstation-side SSH key for the user

This key is used for the SSHFS reverse-mount (workstation → laptop):

```
sudo -u <user> ssh-keygen -t ed25519 -f /home/<user>/.ssh/id_ed25519 -N ''
sudo -u <user> cat /home/<user>/.ssh/id_ed25519.pub
```

Save the printed public key. It goes into the laptop's
`~/.ssh/authorized_keys` in Phase B.

### A9. Confirm `llama-coder` listens on `0.0.0.0`

Edit-predictions from the laptop hit `:11438` over the network, so the
service must not bind to `127.0.0.1`. The drop-in lives at:

```
/etc/systemd/system/llama-coder.service.d/listen-lan.conf
```

It must contain a fully-expanded `ExecStart=` (env-var expansion in drop-ins
is finicky; use literal paths) ending with `--host 0.0.0.0 --port 11438`.
After any change:

```
sudo systemctl daemon-reload
sudo systemctl restart llama-coder.service
ss -lntp | grep 11438   # confirm 0.0.0.0:11438 not 127.0.0.1:11438
```

### A10. Confirm iptables rules and route

The workstation has `INPUT DROP` policy. Port 11438 needs ACCEPT from the
LAN and WireGuard subnets. Persisted via NetworkManager dispatcher at:

```
/etc/NetworkManager/dispatcher.d/10-workstation-net
```

That script also adds a route to the WG subnet via the Proxmox host. After
any change, trigger a dispatcher re-run (e.g. `nmcli con up <name>`) or
reboot. Confirm with:

```
sudo iptables -S INPUT | grep 11438
ip route get <wg-laptop-ip>
```

### A11. Add the laptop's SSH public key to the workstation user

You will receive this from the user in Phase B. Add it to:

```
/home/<user>/.ssh/authorized_keys
```

(mode 600, owned by `<user>:<user>`). This grants laptop → workstation SSH
for `2gpu-remote-launch` and `opencode-remote-session`.

## Phase B — Laptop setup

Run as the remote user on their laptop. No sudo required for the bin scripts
themselves; sudo is needed for installing system packages.

### B1. Install dependencies

```
sudo apt-get install wakeonlan sshfs yad libnotify-bin wireguard openssh-client
```

Install Zed locally (`~/.local/bin/zed` is the default the launcher script
expects).

### B2. Configure WireGuard

Obtain the peer config from the admin and import it into the laptop's
WireGuard client (NetworkManager, `wg-quick`, or the GUI tool of your
choice). Verify the tunnel is up before proceeding:

```
ip -4 addr show wg0   # must show an inet on the WG subnet
ping -c1 <workstation-wg-or-lan-ip>
```

The `opencode-remote-session` script reads the laptop's WG IP from `wg0` and
hands it to the workstation as the SSHFS source — if `wg0` is missing, the
script aborts with a clear error.

### B3. Generate the laptop SSH key and exchange keys

```
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
cat ~/.ssh/id_ed25519.pub
```

Send that public key to the admin to install in step A11.

Add the workstation user's public key (from step A8) to your laptop's
`~/.ssh/authorized_keys`:

```
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys
# paste the workstation pubkey, then Ctrl+D
chmod 600 ~/.ssh/authorized_keys
```

### B4. Add the workstation host key to known_hosts

```
ssh-keyscan -H <workstation-ip> >> ~/.ssh/known_hosts
```

Verify SSH works without prompting:

```
ssh <user>@<workstation-ip> 'hostname'
```

### B5. Install the laptop-side scripts

Place `2gpu-remote-launch` and `opencode-remote-session` in `~/bin/` and make
them executable. Place `setup-laptop.sh` somewhere convenient and run it; it
creates the Zed isolated profile and the `.desktop` entry.

> TODO: these scripts do not yet live in the repo. They currently sit at
> `/tmp/2gpu-remote-launch`, `/tmp/opencode-remote-session`, and
> `/tmp/setup-laptop.sh` on the workstation. They should move to
> `scripts/laptop/` in the umbrella repo so future remote users can fetch
> them via the user's clone. See `docs/repo-issues.md`.

Both scripts hardcode `WORKSTATION_HOST`, `WORKSTATION_USER`, and (for
`2gpu-remote-launch`) `WORKSTATION_MAC` and `WORKSTATION_BROADCAST`. Edit
them for the new user before installing.

```
mkdir -p ~/bin
mv ~/Downloads/2gpu-remote-launch ~/bin/
mv ~/Downloads/opencode-remote-session ~/bin/
chmod +x ~/bin/2gpu-remote-launch ~/bin/opencode-remote-session
```

### B6. Run setup-laptop.sh

```
bash setup-laptop.sh
```

What it does:

- Adds `~/bin` to `PATH` in `~/.bashrc` or `~/.zshrc`.
- Writes `~/.local/share/zed-2gpu-remote/config/settings.json`. The
  `edit_predictions` block points at `http://<workstation-ip>:11438/v1/completions`.
  The `agent_servers.opencode.command` points at `~/bin/opencode-remote-session`.
- Writes `~/.local/share/applications/zed-2gpu-remote.desktop` so the
  launcher appears in the application menu.

If you edit the workstation IP later, update both the `.desktop` Exec line's
embedded host and the `edit_predictions.api_url` in
`~/.local/share/zed-2gpu-remote/config/settings.json`.

### B7. First launch

Click the "Zed (2GPU Remote)" entry, or run from a terminal:

```
~/bin/2gpu-remote-launch
```

Expected flow:

1. WoL packet sent to the workstation MAC.
2. yad splash window appears (if `yad` is installed) showing journal lines
   from `llama-primary` until the four endpoints respond.
3. Zed opens with the isolated 2GPU-remote profile.
4. In a Zed terminal, `cd ~/Projects/<some-project>` then run
   `opencode-remote-session`. Zed's agent panel can also launch it
   automatically — the `agent_servers.opencode.command` in settings.json
   wires it to the agent panel.

## Verifying it works

From the laptop, with WireGuard up:

```
# 1. SSH to workstation works
ssh <user>@<workstation-ip> 'hostname'

# 2. Edit-predictions endpoint reachable
curl -fs http://<workstation-ip>:11438/v1/models | jq '.data[0].id'

# 3. SSHFS reverse-mount works (the script does this; manual test:)
ssh <user>@<workstation-ip> "mountpoint /mnt/<user>-laptop"

# 4. opencode launches under SSH and the ACP handshake completes:
#    open Zed → agent panel → start a new opencode chat → it should
#    reach the model selection screen, not hang.
```

In Zed:

- Type code in a buffer; after a brief pause, edit-prediction completions
  should appear inline.
- Open the agent panel, start a new opencode session. Ask "What MCP tools do
  you have?" — the answer should include `library_research` and friends.

## Troubleshooting

**Edit-prediction returns nothing / curl to :11438 from the laptop times out.**
- Check the laptop's WireGuard tunnel is up: `ip -4 addr show wg0`.
- Check the workstation's INPUT chain accepts :11438 from your subnet:
  `sudo iptables -S INPUT | grep 11438` on the workstation.
- Check `llama-coder` is listening on `0.0.0.0`, not `127.0.0.1`:
  `ss -lntp | grep 11438` on the workstation. If it shows `127.0.0.1`, the
  drop-in at `/etc/systemd/system/llama-coder.service.d/listen-lan.conf` is
  missing the fully-expanded `ExecStart=` with `--host 0.0.0.0`.

**`opencode-remote-session` appears to hang forever; Zed agent panel never
shows a response.**
- This is almost always the `ssh -n` gotcha. The pre-flight
  `ssh "mountpoint -q ..."` check inside `opencode-remote-session` MUST use
  `ssh -n` so it does not consume Zed's stdin (Zed pipes the ACP `initialize`
  JSON in via stdin). Without `-n`, ssh swallows the JSON and the agent
  appears to hang. Verify the script has `-n` on the preliminary ssh calls.

**`opencode-remote-session` errors with "WireGuard interface wg0 not found".**
- The laptop's tunnel is down. Bring it up before re-running.

**SSHFS mount fails with "could not resolve hostname" or connection refused.**
- The workstation cannot reach the laptop. WiFi AP client isolation is the
  most common cause on home networks. Confirm WireGuard is up and that the
  workstation has a route to the WG subnet (check
  `/etc/NetworkManager/dispatcher.d/10-workstation-net` ran).

**SSHFS mount fails with "permission denied" on `/mnt/<user>-laptop`.**
- The mountpoint exists but is owned by root. Re-do step A6:
  `sudo chown <user>:<user> /mnt/<user>-laptop`.

**Library MCP fails to start with "permission denied" or "no such command".**
- The `.venv/` is half-built. Re-do step A5 — `rm -rf .venv && uv sync`
  inside the user's `Library/`.

**opencode does not load global agent rules from AGENTS.md.**
- The path `~/.config/opencode/AGENTS.md` is a symlink. opencode does not
  follow it. Replace with a copy (step A4).

**`2gpu-remote-launch` reports "workstation did not respond to SSH within
120s".**
- WoL packet did not wake the workstation, or the workstation took longer
  than 120s. Check the BIOS WoL setting, the configured MAC and broadcast
  address in the script, and that the laptop is on the same broadcast domain
  (or that the WoL relay is in place).

**polkit prompts for a password when the user runs `systemctl start
llama-primary.service`.**
- The user is not in the `allowedUsers` array (or the equivalent condition)
  in `/etc/polkit-1/rules.d/10-llama-services.rules`. Re-do step A2.

## Known issues / repo work needed

- Laptop-side scripts (`2gpu-remote-launch`, `opencode-remote-session`,
  `setup-laptop.sh`) do not yet live in the umbrella repo. They should move
  to `scripts/laptop/` and the workstation IP / user / MAC should be sourced
  from a small env file the user populates rather than hardcoded.
- See `docs/repo-issues.md` for: polkit hardcoded usernames, private Library
  submodule, optional-secrets-env, live-rule-divergence.
