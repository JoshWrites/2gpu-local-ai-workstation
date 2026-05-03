# opencode global config

The agent rules and provider config that opencode reads at startup.
Tracked here so they survive a machine rebuild and so changes are
reviewable.

If you are setting up the stack for the first time, the canonical
order is in `docs/install.md` (step 10 covers symlinking AGENTS.md;
the opencode.json render is automatic). This file is the deeper
reference for how the render-at-launch templating works and what
each file in this directory does.

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
cd <umbrella-checkout>/configs/opencode
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

## The `llama-experiment` provider

The template advertises an `llama-experiment` provider on
`localhost:${WS_PORT_EXPERIMENT}` (default 11444). Today this slot is
served by `systemd/llama-primary-experiment.service`, which runs
GPT-OSS-120B with native 128K context via the HIP llama.cpp build.

The experiment cannot run alongside `llama-primary` — both want the
7900 XTX. The expected workflow is opt-in:

```
sudo systemctl stop llama-primary
sudo systemctl start llama-primary-experiment
# ...use it from Zed by picking "GPT-OSS-120B 128K" in the model picker...
sudo systemctl stop llama-primary-experiment
sudo systemctl start llama-primary
```

The launchers (`opencode-session.sh` and `2gpu-launch.sh`) detect when
`llama-primary-experiment` is active and substitute it for
`llama-primary` in their service-management logic, rather than blindly
starting both. Without this, starting Zed while the experiment was
loaded would crash llama-primary's load (no free VRAM) and the
cascading host-memory pressure has been observed to OOM-kill the
experiment (54 GB RSS). See `compute_active_units` in
`scripts/opencode-session.sh` and the equivalent block in
`scripts/2gpu-launch.sh`.

If neither service is running when Zed asks for the experimental
model, opencode gets a connection error on that one provider; the
rest of the stack keeps working.

### Why the model id is aliased to `gpt-oss-120b`

The unit file passes `--alias gpt-oss-120b` to llama-server, and the
template uses `gpt-oss-120b` (not the GGUF filename) as the model key.

This matters: opencode pattern-matches the model id internally to
enable GPT-OSS-specific request handling — Harmony channel parsing,
correct system-prompt shape, and most importantly, attaching tool
definitions to the request. The binary's strings include
`gpt-oss-120b`, `gpt-oss-20b`, `harmony` etc. as recognized ids.

Without the alias, the server reports the GGUF filename as the model
id (`gpt-oss-120b-mxfp4-00001-of-00003.gguf`), opencode does not
match the pattern, falls back to a generic openai-compatible flow,
and **does not send tool definitions in the request** — so the model
can't write files or call MCP tools and just emits code blocks in
chat. This was observed during the first Zed test of this branch
(see commit `dd05c5d` for the diagnosis).

If you swap to a different GGUF for this slot, set the alias to
whatever opencode pattern recognizes — typically the canonical
huggingface model name without the quant/shard suffix.

### Quirk: GPT-OSS uses Harmony channels

Unlike most chat models, GPT-OSS routes its private reasoning into a
separate `reasoning_content` field on the response, leaving `content`
for the final answer. With small `max_tokens` budgets, the reasoning
can consume the full budget and `content` returns empty. Set
`max_tokens` generously (Zed defaults are usually fine; the template
declares `output: 16384`).

See `docs/research/gpt-oss-120b-moe-offload.md` for the full
investigation, performance numbers, and the trip log of dead ends.

