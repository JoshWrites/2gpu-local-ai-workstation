# opencode global config

The agent rules and provider config that opencode reads at startup.
Tracked here so they survive a machine rebuild and so changes are
reviewable.

## Files in this directory

- `AGENTS.md` is the global agent rules. Tells the model how to use
  the Library MCP, which tool to prefer for which job, how the
  two-layer return contract works. Symlinked into
  `~/.config/opencode/AGENTS.md` at install time.
- `opencode.json.template` is the provider and permission template.
  It uses `${WS_VAR}` placeholders that get substituted from the
  workstation env files at every opencode launch. The rendered
  output lands at `~/.config/opencode/opencode.json` and is not
  tracked.
- `.gitignore` lists files that exist at `~/.config/opencode/` but
  should never commit (`node_modules/`, lockfiles, state files).
- `README.md` is this file.

## How the two configs reach opencode

**AGENTS.md uses a symlink.** It is plain prose with no per-machine
values to substitute. Symlinking the tracked file into
`~/.config/opencode/AGENTS.md` lets edits land directly in the repo
and lets opencode read them without an extra step.

**opencode.json uses render-at-launch.** The file has machine-specific
values (port numbers, library paths, SSH targets) that come from the
env files. Every opencode launch goes through `opencode-session.sh`,
which:

1. Sources `/etc/workstation/system.env`, `~/.config/workstation/user.env`, and `~/.config/workstation/secrets.env`.
2. Runs `envsubst < opencode.json.template` to substitute the
   `${WS_VAR}` placeholders.
3. Preserves the user's current `model` field from the existing
   rendered file (if valid) so model swaps survive the render.
4. Validates the result with `jq empty`.
5. Atomic-replaces `~/.config/opencode/opencode.json`.
6. Hands off to `opencode`.

Render is idempotent. Run a hundred times, get the same result each
time, except for whatever the user has changed in `model`.

## Setting up on a new machine

After cloning the umbrella repo:

```
cd ~/Documents/Repos/Workstation/second-opinion/configs/opencode
ln -sf "$(pwd)/AGENTS.md" ~/.config/opencode/AGENTS.md
```

The opencode.json side has no manual install step. The render runs
automatically at every `opencode-session.sh` invocation, which is
how opencode launches in this stack (via Zed's agent_servers config
or the terminal alias).

## Why render-at-launch instead of a one-time install

Three real wins:

1. **Secrets never persist as committed text.** The template has
   `${WS_PROXMOX_HOST}`; the rendered file has the literal value
   but is gitignored. Future-proofs the umbrella going public.
2. **No drift.** The template is the only source of truth. There
   is no question whether the rendered file is up to date because
   it gets rebuilt every launch.
3. **Reproducible across users.** A second user on the same
   machine renders their own opencode.json from their own env
   files; values can differ per-user without conflict.

The only state preserved across renders is the `model` field, which
the user changes interactively to swap models for a task. Other
runtime tweaks would get clobbered on next launch; if you find
yourself wanting to preserve another field, add it to
`PRESERVE_FIELDS` in `scripts/opencode-session.sh`.

## Pre-publish work

One organizational hold remains before this directory ships in a
public repo: sweep `AGENTS.md` for non-ASCII characters and tighten
prose to the project writing standards. Tracked for the language
pass.

The SSH-targets templating that was previously listed here is now
done. Real values come from `~/.config/workstation/secrets.env`,
which is private per-user and never tracked.
