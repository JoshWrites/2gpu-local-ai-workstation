# Session Manager — Build Plan

See `ARCHITECTURE_DECISIONS.md` for full rationale.

---

## Goal

A lightweight always-on daemon that:
1. Detects when AI applications are launched (event-driven via inotify)
2. Starts all configured GPU services immediately
3. Detects when all AI applications have closed (polling)
4. Stops all configured GPU services after a grace period
5. Notifies the user and asks what to do if a service fails to start

Everything configurable — no hardcoded app or service names.

---

## Files

```
~/.config/ai-session/
├── config.yaml          # trigger apps + timing
└── services.yaml        # services to manage

~/.config/systemd/user/
└── ai-session.service   # user systemd unit (always-on, lightweight)

library_and_patron/session_manager/
├── __init__.py
└── manager.py           # the daemon
```

---

## User Configuration

### `~/.config/ai-session/config.yaml`

```yaml
trigger_apps:
  - codium
  - aider
  - code
  - zed

# Seconds to wait after last trigger app closes before stopping services
grace_period_seconds: 60

# How often to poll for running processes during shutdown check
poll_interval_seconds: 10

# Directories to watch for trigger app execution (inotify)
watch_dirs:
  - /usr/bin
  - /usr/local/bin
  - /home/levine/.local/bin
  - /home/levine/.cargo/bin
```

### `~/.config/ai-session/services.yaml`

```yaml
services:
  - name: ollama-gpu1
    type: system          # systemctl (requires sudoers rule)
    required: true        # if false, failure is logged but no notification

  - name: ollama-gpu0
    type: system
    required: true

  - name: librarian
    type: system
    required: true
```

---

## Daemon Behavior

### Startup detection (inotify — event-driven)

- Watch each directory in `watch_dirs` for `IN_OPEN` events
- On open event: check if the opened binary name matches any `trigger_apps` entry
- Match found → call `start_session()`
- Already in active session → no-op

`start_session()`:
1. For each service in `services.yaml`: `systemctl start <name>`
2. If start fails and `required: true`: send desktop notification (see Failure Handling)
3. Log session start with timestamp

### Shutdown detection (polling)

While session is active, every `poll_interval_seconds`:
- Check `ps aux` for any process matching `trigger_apps`
- All gone → start grace period countdown
- Any reappears during countdown → cancel countdown, stay active
- Countdown expires → call `stop_session()`

`stop_session()`:
1. For each service: `systemctl stop <name>`
2. Log session stop with timestamp and duration

### State

Simple in-memory state:
```python
state = {
    "active": bool,
    "session_start": float | None,
    "grace_countdown": float | None
}
```

No persistence needed — if the daemon restarts, it checks process list on startup to determine initial state.

---

## Failure Handling

When `systemctl start <service>` fails:

1. Send desktop notification via `notify-send`:
   ```
   Title: "AI Session: Service Failed"
   Body:  "Failed to start <service-name>. What would you like to do?"
   ```

2. Show two action buttons (requires `libnotify` with action support):
   - **"Continue without"** → mark service as skipped for this session, don't retry
   - **"Retry"** → attempt `systemctl start <name>` once more
     - Success → notify "Service started successfully"
     - Failure → notify "Service still unavailable, continuing without it"

3. Session manager never blocks waiting for user response — uses notification callbacks

Note: action buttons require a notification daemon that supports them (dunst, mako, GNOME). If the daemon doesn't support actions, fall back to two separate notifications: one for the failure, one telling the user to run `systemctl start <name>` manually.

---

## Sudoers Rule (for system service control)

The session manager runs as the user but needs to start/stop system services.

Create `/etc/sudoers.d/ai-session`:
```
levine ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ollama-gpu1
levine ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ollama-gpu1
levine ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ollama-gpu0
levine ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ollama-gpu0
levine ALL=(ALL) NOPASSWD: /usr/bin/systemctl start librarian
levine ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop librarian
```

Minimal privilege — only the exact commands needed, nothing else.

When a new service is added to `services.yaml`, a corresponding sudoers line must be added. This is intentional — it makes privilege grants explicit and auditable.

---

## Systemd User Service

`~/.config/systemd/user/ai-session.service`:

```ini
[Unit]
Description=AI Session Manager
After=graphical-session.target

[Service]
Type=simple
WorkingDirectory=/home/levine/Documents/Repos/Workstation/library_and_patron
ExecStart=/home/levine/Documents/Repos/Workstation/library_and_patron/.venv/bin/python -m session_manager.manager
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Enable with:
```
systemctl --user enable ai-session.service
systemctl --user start ai-session.service
```

---

## Second Ollama Instance (GPU0)

New system service: `/etc/systemd/system/ollama-gpu0.service`

```ini
[Unit]
Description=Ollama (GPU0 - 5700 XT)
After=network.target

[Service]
User=ollama
Group=ollama
ExecStart=/usr/local/bin/ollama serve
Environment="OLLAMA_HOST=0.0.0.0:11435"
Environment="OLLAMA_MODELS=/opt/ollama/models"
Environment="ROCR_VISIBLE_DEVICES=0"
Environment="OLLAMA_KEEP_ALIVE=1h"
# NOTE: Do NOT set HSA_OVERRIDE_GFX_VERSION — Ollama detects gfx1010:xnack- correctly without it.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Note: do NOT enable this service (`systemctl enable`) — session manager starts and stops it on demand. Enabling it would make it start at boot, defeating the purpose.

Same applies to `ollama-gpu1` — disable its auto-start if currently enabled, let session manager own its lifecycle.

Exception: if you want Ollama available outside of AI app sessions (e.g. for scripts, Open WebUI), keep `ollama-gpu1` enabled at boot and remove it from `services.yaml`.

---

## Portability (deploying to a new machine)

1. Copy `~/.config/ai-session/` to new machine
2. Edit `config.yaml` — update `trigger_apps` and `watch_dirs` for that machine's layout
3. Edit `services.yaml` — update service names for that machine's GPU services
4. Add sudoers rules for the new service names
5. Copy the session_manager module and install deps
6. `systemctl --user enable ai-session.service && systemctl --user start ai-session.service`

No code changes needed between machines.

---

## Dependencies

```
inotify-simple  # inotify watching for open events (Python 3.12 compatible)
notify-send     # system package, not pip — sudo apt install libnotify-bin
```

---

## Testing Checklist (required before completion)

- [x]`ai-session.service` starts cleanly, logs visible via `journalctl --user -u ai-session`
- [x]Opening VSCodium triggers immediate service start (check via `systemctl status ollama-gpu0`)
- [x]Opening Aider in a terminal also triggers session start
- [x]Closing all trigger apps → 60s grace → services stop
- [x]Reopening an app during grace period cancels shutdown
- [x]Simulated service start failure triggers `notify-send` notification
- [x]"Continue without" action skips the service for the session
- [x]"Retry" action attempts restart and notifies result
- [x]Adding a new app to `config.yaml` works without code changes
- [x]Adding a new service to `services.yaml` (+ sudoers rule) works without code changes
- [x]Session manager survives daemon restart — correctly detects already-running apps on startup
