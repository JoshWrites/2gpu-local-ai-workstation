# Second-opinion lifecycle management

How launching and closing the editor maps to llama-server state and VRAM.

## The problem

Earlier iterations had `scripts/codium-second-opinion.sh` starting just the
editor and `scripts/primary-llama.sh` started separately in a terminal.
That meant llama-server stayed resident (~23 GB VRAM on the 7900 XTX) until
the user remembered to Ctrl+C it. Josh wanted the editor close to release
the GPU automatically — but also wanted honest progress feedback during the
~35-second cold start, including visibility into which phase is running if
something hangs.

## The design

Two `systemd --user` units plus a launcher with a `yad` splash.

### Units

- **`llama-second-opinion.service`** — wraps `scripts/primary-llama.sh`.
  Never enabled. Started on demand only. Respects the boot-cleanup
  baseline (all system-wide `ollama*` units stay disabled; this is
  user-scoped).
- **`codium-second-opinion.service`** — wraps
  `scripts/codium-second-opinion.sh --wait`, which blocks until the
  editor window is closed. `Requires=llama-second-opinion.service` and
  `BindsTo=llama-second-opinion.service`, so stopping either takes the
  other with it.

### Launcher — `scripts/second-opinion-launch.sh`

1. **Cold vs warm detection.** A boot-marker file
   `/tmp/second-opinion-launched-this-boot` is cleared on reboot (tmpfs).
   First launch after boot → cold; otherwise warm. Thresholds differ.
2. **Start the llama unit.** Not the codium unit yet — we want to know
   llama is healthy before the editor opens so Roo has a live backend
   the moment it asks.
3. **yad splash.** A `--text-info --tail` window streams the filtered
   llama journal: ROCm init, tensor load, KV cache alloc, warm-up,
   server listening. Font monospace 9, on-top, 820x420. If you see
   a phase frozen on one line, that's exactly where it's stuck.
4. **Watchdog.** A backgrounded sleep fires `notify-send` if the
   warn-threshold elapses without a health-ok. The splash stays up;
   the toast is the louder signal.
5. **Health poll.** Every second, `GET /health`. When `{"status":"ok"}`
   returns, kill the splash, toast "Second Opinion — ready".
6. **Start codium unit.** Opens the repo in the isolated VSCodium
   instance; the service blocks on `codium --wait`.
7. **Wait on exit.** Poll `systemctl --user is-active` on the codium
   unit. When the user closes the editor, it goes inactive; we
   explicitly stop the llama unit, toast "stopped".

### Thresholds

Derived from `scripts/bench-llama-startup.sh` results (3 cold + 7 warm
runs, 2026-04-15):

| State | Expected ready | Warn at |
|---|---|---|
| Cold | ~36s | 55s |
| Warm | ~3.3s | 10s |

Variance was tight: ±0.65s cold, ±0.02s warm. Warn thresholds are 50%
slack above the observed max, which is plenty of room for a degraded
disk or a busy CPU without chasing false positives.

Post-tensor phases (KV alloc, warm-up) were sub-second and
deterministic across both states. Not worth their own thresholds; they
roll up into "total to ready".

## Flow summary

- **Click "VSCodium (Second Opinion)"** → launcher runs.
- Splash appears with live phase log. Cold: ~35s. Warm: ~3s.
- Toast "Second Opinion — ready". Editor opens.
- Work. Agent calls llama-server directly.
- **Close VSCodium window** → systemd stops codium unit → BindsTo stops
  llama unit → VRAM released on GPU 1.
- Toast "Second Opinion — stopped".

## Fallback / escape hatches

- **Desktop entry action "Editor only (no llama-server)"** — launches
  the editor without starting llama. Useful when you want to read files
  or edit settings without the GPU cost.
- **Manual llama start** — `systemctl --user start
  llama-second-opinion.service` from a terminal if you want the server
  without the editor.
- **If the launcher hangs** — `systemctl --user stop
  codium-second-opinion.service llama-second-opinion.service`.
- **If Roo disagrees with llama state** — llama crashed mid-session,
  for example — restart with the launcher; Roo reconnects on next
  request.

## What this does *not* do

- No warm-pool: the model is not kept loaded after editor close. If
  you reopen within a minute, you pay the warm-start 3s again — still
  much better than the 35s cold hit, thanks to page cache.
- No auto-recovery: if llama crashes while you're working, the next
  request fails and you restart the launcher. Deliberately no
  `Restart=on-failure` — a crashing agent backend should be noticed,
  not silently reanimated.
- No multi-instance: only one editor can have the agent backend at a
  time. Good — one 23 GB VRAM budget.
