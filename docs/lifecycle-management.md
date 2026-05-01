# Lifecycle management

How the four llama services start, stay up, and stop -- without
fighting each other when more than one client (the editor, a
terminal session, a second user) wants them at the same time.

## The problem

Local AI services have an inconvenient lifecycle shape. They take
~60 seconds to load weights into VRAM, so you do not want them
starting on every editor open. Once loaded, they hold ~21 GB of
VRAM on the primary card and ~8 GB on the secondary card -- VRAM
that gaming, video editing, and other GPU work cannot use. So you
do not want them lingering after the work session ends.

The naive answers both fail:

- **Always-on at boot**: holds VRAM hostage for non-AI work, and
  the boot sequence depends on services that the user may not
  always want running.
- **Started by the editor, killed when the editor closes**: works
  for one client, breaks the moment a terminal opencode session
  shares the same backend, breaks worse when a second user is
  involved.

The actual shape needed: services start when the first client wants
them, stay up across an entire work session even if the editor
closes briefly, stop politely only when nobody is using them. That
"nobody" check has to be reliable enough that one user can run a
shutdown command without yanking the GPU out from under another
user's still-active session.

## What solving it gets you

A two-piece lifecycle:

- **A launcher** (`scripts/2gpu-launch.sh`) that is the desktop's
  primary entry point. Idempotent: clicking the icon when services
  are already up is fast (skips the splash, opens the editor); when
  services are down it shows a yad progress splash, starts the four
  units, polls each endpoint, and opens the editor only after all
  four are ready.
- **A polite-shutdown coordinator** (`/usr/local/bin/llama-shutdown`)
  that decides whether stopping is safe right now. It refuses if
  any TCP connection is established, refuses if any opencode or zed
  process older than 30 seconds is alive (a session-holder), and
  waits a grace period of confirmed idleness before stopping. A
  `--force` flag skips the safety checks for cases where the user
  knows the other side is done.

The pair handles single-user work, terminal-and-editor work, and
two-user work without per-case logic. The launcher does not own
service lifetime beyond starting them; the coordinator owns
stopping.

## How I solved it

### The launcher's flow

`scripts/2gpu-launch.sh` is the desktop entry point. The flow is
five branches off two questions: are services already up, and was
the launcher invoked with a path argument?

```
                          launcher invoked
                                 |
                       services already up?
                          /            \
                       YES              NO
                        |               |
                        |        start the four units
                        |               |
                        |        show yad splash
                        |               |
                        |        poll /v1/models on each port
                        |               |
                        |        deadline: 60s expected,
                        |        75s warn, 180s timeout
                        |               |
                        +-------+-------+
                                |
                       path argument given?
                          /            \
                       YES              NO
                        |               |
                  open Zed --wait       open Zed detached
                  block until close     return immediately
                        |               |
                  llama-shutdown        (user runs llama-shutdown
                  (refuses if          manually when done)
                  someone else is
                  using llama)
```

The fast path (services already up) skips the splash entirely. Two
common cases hit it: a second launch in the same session, or a
launcher invoked while a terminal opencode session is already using
the services. In both cases, the launcher is functionally a Zed
opener with a notification.

The cold path (services not yet up) takes ~60 seconds on this
hardware: ~25 s for primary GLM-4.7-Flash to load tensors and KV
cache, ~5 s each for the three secondary-card services. The yad
splash tails the primary unit's journal so the user can see which
phase is running. A 75-second warn threshold pings notify-send if
the loading is slower than expected; the hard timeout at 180 s
cancels the launch with an error.

### Why Zed gets two open paths

`zed --wait` requires at least one positional path argument. With a
path, Zed blocks until the window closes; without one, Zed prints
its usage line and exits immediately. That is a Zed quirk, not
something the launcher chose.

The launcher accommodates it:

- **With a path** (e.g., `2gpu-launch.sh -- /path/to/repo`): Zed
  runs under `--wait`, the launcher blocks until the editor closes,
  then calls `llama-shutdown`. This is the polite-cleanup path.
- **Without a path** (the normal desktop-icon click): Zed runs
  detached. The launcher exits immediately. The user runs
  `llama-shutdown` manually when they are done with the work
  session.

Both paths are correct for their use case. Desktop-icon launches
are typically "I want to use the editor for a while" -- the user
does the explicit shutdown when they are done. CLI launches with
a path argument are typically "I want to edit this one thing" --
the editor close is a natural shutdown signal.

### The polite-shutdown coordinator

`llama-shutdown` is the only non-trivial piece of lifecycle logic
in the stack. The script lives at `/usr/local/bin/llama-shutdown`
(sourced from `systemd/llama-shutdown` in this repo). Its job is
deciding whether stopping is safe.

The decision tree:

```
                         llama-shutdown invoked
                                  |
                         all units already inactive?
                              /          \
                           YES            NO
                            |              |
                       exit 0       --force flag set?
                                       /        \
                                    YES          NO
                                     |            |
                              stop all units    holder check
                                     |            |
                                  exit 0     opencode or zed
                                             processes alive
                                             and older than 30s?
                                                 /       \
                                              YES         NO
                                               |          |
                                          refuse        TCP connection
                                          exit 1        check
                                                            |
                                                    any established
                                                    connection on a
                                                    llama port?
                                                       /       \
                                                    YES         NO
                                                     |          |
                                                refuse        grace period
                                                exit 1        watch
                                                                  |
                                                          for 30s, recheck
                                                          every second:
                                                          any holder or
                                                          connection?
                                                            /       \
                                                          YES        NO
                                                           |          |
                                                       refuse      stop
                                                       exit 1      exit 0
```

Two checks, in order, plus a grace window:

**Holder check.** opencode and Zed only hold a TCP connection
during active inference. Between turns -- when the user is reading
or thinking -- the connection count goes to zero and may stay zero
for many minutes while the session is genuinely alive. Treating
"zero connections right now" as "safe to stop" would yank services
out from under a session every time the user paused to think.

The fix: any opencode or zed process owned by a configured local
user counts as a holder regardless of TCP state. The age filter
(`HOLDER_MIN_AGE_SEC=30`) excludes very-recent processes that are
likely teardown children of an editor that just closed; a process
older than the threshold is committed to running and counts as a
real holder.

**Connection check.** If no holder process is alive but a TCP
connection is established to a llama port, something we did not
detect (a curl probe, a benchmark script, a third-party client) is
using the services. Refuse.

**Grace window.** Even with both checks above passing, a session
can be briefly idle between turns. The script watches for 30
seconds before stopping; if any holder or connection appears, the
shutdown aborts.

The 30-second grace and the 30-second age filter together produce
behavior that looks responsive to the user (`llama-shutdown` from a
terminal completes within ~30 s when the system is genuinely idle)
without false positives on real sessions (a paused-to-think user
keeps services alive indefinitely).

### Why services are not enabled at boot

`systemctl enable` would start the services every boot. The user's
machine is not always running AI work -- gaming, video editing, and
plain desktop work all want the VRAM that the four services
collectively reserve.

The four units are installed but not enabled. They start on demand
from the launcher, stay up across a work session, and stop politely
when the user runs the shutdown coordinator (or when the launcher
runs it on the path-argument exit path).

This means the boot sequence does not depend on llama-server being
healthy, which is the correct shape: a llama-server failure should
not delay or fail the user's login.

### Why polkit, not sudo

Local users need to start, stop, and restart the four llama units
without typing a password every time. `sudo systemctl start
llama-primary` works, but the per-launch password prompt is bad UX
and discourages the polite-shutdown habit (users hold services up
indefinitely rather than re-type their password).

The polkit rule at `systemd/polkit/10-llama-services.rules` grants
configured local users passwordless control of exactly the four
llama units. Other systemctl actions still require sudo. The rule's
`allowedUsers` array is a customization point -- edit it to list
the local accounts on your machine that should have access.

The pre-publish version of the rule lists `["your-username-here"]`;
real deployments edit that to the actual usernames.

### How the pieces fit together

The lifecycle is owned by three artifacts working together:

1. **The systemd units** (`systemd/llama-*.service`) define what
   gets started, where, and how to restart on failure. They are
   installed but not enabled.
2. **The launcher** (`scripts/2gpu-launch.sh`) starts the four
   units when needed and runs `llama-shutdown` on the path-argument
   exit path. It does not own service lifetime past startup.
3. **The shutdown coordinator** (`/usr/local/bin/llama-shutdown`)
   owns the stop decision. Both the launcher and any direct user
   invocation route through it.

`opencode-session.sh` is a fourth, narrower artifact: it brings
services up when a terminal opencode session needs them, but it
does not stop them on exit. Stopping is always the launcher's
responsibility (path-argument path) or the user's responsibility
(everything else).

## Multi-user note

The polite-shutdown coordinator is the load-bearing piece of
multi-user safety. When a second local user runs the launcher on
the same workstation, the four llama units serve both users from
the same memory; the coordinator's holder check prevents either
user from accidentally stopping the services while the other is
still working.

The deeper multi-user pattern -- SSHFS-mounted laptop filesystems,
UID-remapping with `idmap=user`, the reach-back launcher that
translates laptop paths to mount paths -- is documented in a
forthcoming reference doc. For now, the load-bearing fact is: the
shutdown coordinator's holder check works for any number of local
users, as long as they are listed in `LLAMA_SHUTDOWN_HOLDER_USERS`
(comma-separated; falls back to `$USER` if unset) and in the
polkit rule's `allowedUsers` array.

## What you can change

- **`HOLDER_MIN_AGE_SEC`** (default 30): increase if your editor
  takes longer than 30 seconds to tear down. Decrease if you find
  the polite shutdown waiting longer than necessary on a clearly
  idle system.
- **`GRACE_SEC`** (default 30): increase if you have very-bursty
  work patterns (long pauses between turns) and want a wider
  safety window. Decrease if you trust your "I'm done" signal.
- **`LLAMA_SHUTDOWN_HOLDER_USERS`**: set to a comma-separated list
  of usernames (e.g., `LLAMA_SHUTDOWN_HOLDER_USERS=alice,bob
  llama-shutdown`) to extend holder detection to additional users.
  Defaults to the running user.
- **The launcher's timeouts** (`EXPECTED_READY=60`, `WARN_READY=75`,
  `HARD_TIMEOUT=180`): tune to match your hardware. Slow disks or
  cold page cache push the load time up.

## Where to look when something breaks

- **`llama-shutdown` refuses but you know nobody is connected:**
  run with `--force`. Investigate why afterward -- usually a stale
  opencode/zed process older than 30 seconds. `pgrep -af opencode`
  and `pgrep -af zed` show the survivors.
- **The launcher's splash hangs past 180 seconds:**
  `journalctl -u llama-primary.service -n 100`. Common causes:
  cold disk page cache (model takes longer than usual to load),
  GPU driver hung from a previous session, GGUF file missing or
  corrupted.
- **Services stay up after `llama-shutdown` reports success:**
  the script returns 0 only after issuing `systemctl stop` to each
  active unit. If `systemctl is-active` still returns active,
  systemd's stop hit a timeout. `journalctl -u llama-<role>.service
  -n 50` shows the stop sequence.
- **Polite shutdown loops in the grace window forever:**
  something is reconnecting between checks. `ss -tn state
  established '( sport = :11434 )'` (and the other ports) shows
  the live connection. Often a benchmark script or a browser tab
  pointed at one of the endpoints.

## Where to look for adjacent docs

- The four llama services and what they run: `docs/llama-services-reference.md`.
- The env files that the launcher and shutdown coordinator both
  read: `configs/workstation/README.md`.
- The opencode template that gets rendered at every session start:
  `configs/opencode/README.md`.
- The patched opencode binary that Zed launches:
  `opencode-zed-patches/README.md`.
- The Library MCP that opencode connects to:
  `Library/README.md`.
