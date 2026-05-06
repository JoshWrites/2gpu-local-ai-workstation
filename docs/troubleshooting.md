# Troubleshooting

Flat list keyed by the error message you'd actually see, not by which
component owns the bug. For design context behind any fix, follow the
links into the matching reference doc or build-history phase.

For the longer narrative ("why we made this choice"), see
[`docs/lessons-learned.md`](lessons-learned.md). For known
not-yet-fixed quirks, see [`docs/repo-issues.md`](repo-issues.md).

---

## Install-time

### `scripts/install-systemd-units.sh` fails: `missing env file`

`/etc/workstation/system.env` has to exist before the units install.
Do install.md step 4 first:

```
sudo install -m 0644 configs/workstation/system.env.example /etc/workstation/system.env
```

### `scripts/install-systemd-units.sh` fails: `unrendered placeholder in <unit>`

The mnemory.service template or one of the sidecar templates didn't
get all its placeholders replaced. Most common cause is `models.toml`
missing a field. Check `models.toml.example` against your `models.toml`
and copy any missing keys. Then re-run the install script.

### `scripts/install-systemd-units.sh` fails: `uvx not found`

mnemory's systemd unit needs uvx (from
[uv](https://docs.astral.sh/uv/)). Install uv with:

```
curl -LsSf https://astral.sh/uv/install.sh | sh
```

…then re-source your shell profile and re-run the install script.

### `git clone --recurse-submodules` fails on Library

Library is currently a private GitHub repo (this is a known issue
tracked in `docs/repo-issues.md`). Until it's made public, ask the
workstation admin for a tarball of the Library tree and unpack it
into the umbrella's `Library/` directory. The rest of install.md
treats `Library/` as a populated working directory regardless of
where it came from.

### `huggingface-cli download` fails with 401 / 403

The model repo is private or gated. Either:
- Get added as a member on HuggingFace.
- Run `huggingface-cli login` and paste a token with read access.
- Pick a different model in `models.toml` (see
  [`docs/tested-models.md`](tested-models.md) for alternatives).

---

## Runtime

### A llama service starts but does not respond on its port

Check the service's journal for the actual exec command:

```
journalctl -u llama-primary-router.service -n 50
journalctl -u llama-secondary.service -n 50
```

Most common causes:

- **Wrong path in unit's ExecStart line.** Env-var interpolation is
  shown literally in `systemctl show` output even when the runtime
  values are correct -- check the journal, not `systemctl show`.
- **For the primary router**: `/etc/workstation/llama-router.ini`
  missing or unparseable. Test with `curl http://localhost:11434/v1/models`
  -- it should list every pool member from the .ini file.
- **GGUF missing**: the `model 'X' not loaded` log line means the
  model named in router.ini doesn't exist in
  `${WS_MODELS_DIR}/<id>/`. Run `scripts/download-models.sh`.
- **HIP/Vulkan toolchain missing**: ROCm runtime errors only appear
  at service start, not at build. Verify with
  `/usr/local/lib/llama.cpp-hip/llama-server --help | grep -i hip`.

### `model is not loaded` (HTTP 400) when sending a prompt

The session is pointed at a model that's not currently loaded on the
router. Two paths:

- **Picker UI says one thing, opencode sends to another.** The
  launcher's fix-9 logic should patch `opencode.json` at startup to
  match the loaded model. If you're seeing this anyway, restart the
  launcher (close Zed, run `2gpu-launch.sh` again).
- **You typed the model id wrong.** Bare `/models` lists what's
  available; pick from that list with `/models <id>`.

### Picking a model in Zed gives a silent failure with no card

`OPENCODE_MODEL_SWAP_SCRIPT` is missing from Zed's isolated profile
config. Without it, the patched opencode falls through to a plain
400 error. Add it under `agent_servers.opencode.command.env` in
`~/.local/share/zed-second-opinion/config/settings.json`:

```jsonc
"OPENCODE_MODEL_SWAP_SCRIPT": "/path/to/repo/scripts/model-swap.sh"
```

### Every Zed launch prompts for the admin password

The polkit allowlist at `/etc/polkit-1/rules.d/10-llama-services.rules`
is missing the unit name being started, or your username isn't in
`WS_LLAMA_USERS`. Re-run `scripts/install-systemd-units.sh` -- it
re-renders the rule from the template using the current value of
`WS_LLAMA_USERS` in `/etc/workstation/system.env`.

### Zed agent panel says `Configuration is invalid`

The rendered `~/.config/opencode/opencode.json` is malformed. Re-run
the render manually:

```
scripts/opencode-session.sh
```

It will print the exact `jq` error before opencode launches. Most
common cause: an unset env var in `secrets.env` left an empty string
where opencode expected a string. Set the missing var or remove the
permission rule that references it from
`configs/opencode/opencode.json.template`.

### Polite shutdown refuses while no Zed window is open

Probably Zed left an orphaned `opencode-patched` subprocess. Check:

```
pgrep -af opencode-patched
```

Kill any stale process, then `llama-shutdown` again.

### Edit prediction works in Zed but the agent panel does not

Edit-prediction goes to llama-coder directly on port 11438; the
agent panel goes through opencode + Library. If only the agent
fails, the issue is in `opencode-session.sh`, the Library MCP, or
opencode itself -- not the llama services. Tail the opencode log:

```
tail -f ~/.local/share/opencode/log/$(ls -t ~/.local/share/opencode/log/ | head -1)
```

### `mnemory.service` is `Activating` or repeatedly `failed`

Three usual causes:

- **Embedded Qdrant can't write.** The unit runs as the install user;
  `$HOME/.mnemory/` must be writable. Check
  `journalctl -u mnemory.service -n 50`.
- **LLM endpoint unreachable.** mnemory uses `LLM_BASE_URL` from
  `/etc/workstation/mnemory.env` (default `http://127.0.0.1:11435/v1`).
  If the secondary llama service isn't up, mnemory crash-loops. Start
  the llama services first.
- **EMBED_DIMS mismatch.** If you swapped the embeddings model
  without dropping `$HOME/.mnemory/qdrant/`, the new model's
  dimension won't match the stored collection. Drop the qdrant dir
  (loses memories) and restart, or revert to the previous embedding
  model.

### `<think>` tags appear inline in chat

You're running a thinking-mode model (Qwen3-Next-Thinking) with
`reasoning-format = none` in `llama-router.ini`. This is the Phase 12
trade-off that Phase 13 fixed -- update your router.ini to set
`reasoning-format = deepseek` and `reasoning-budget = 4096` for the
thinking model section. See Phase 13 in
[`docs/research/2026-05-03-from-one-model-to-an-agentic-stack.md`](research/2026-05-03-from-one-model-to-an-agentic-stack.md).

### `library_research` returns nothing useful

Three layers can fail:

- **SearxNG isn't running** (Library uses it for the search step).
  Run `systemctl --user status searxng` or whatever launcher you use.
- **The summarizer or embeddings sidecar is down.** Library fan-outs
  to them. Check the small-card services:
  `systemctl status llama-secondary llama-embed`.
- **Token budget too low.** A `library_research` call costs ~325-450
  tokens of return; if your context is already 95% full, the response
  may be rejected post-hoc. Compact the session or split it.

---

## Hardware

### `rocm-smi` shows 0 GPUs

ROCm cannot see your AMD GPUs. Either the kernel module isn't loaded
(`lsmod | grep amdgpu`), the user isn't in the `render` and `video`
groups, or the GPU is too old for ROCm 7.x. The 5700 XT is
unofficially supported; you may need a different ROCm version. The
Vulkan path side-steps this for the sidecars.

### llama.cpp HIP build crashes at runtime with `hipErrorNoBinaryForGpu`

The HIP build was compiled for a different GPU architecture than the
one running it. Rebuild with `-DAMDGPU_TARGETS=<your-gfx-id>`. Find
yours with `rocminfo | grep gfx`.

### OOM mid-session on the primary GPU

Most likely the loaded primary-pool model is too big for your
combined VRAM + DRAM envelope. Use `/models <smaller-model>` to swap.
If it OOMs at *startup* rather than mid-session, the per-model
`n-cpu-moe` value in `llama-router.ini` is wrong -- raise it (more
MoE layers offloaded to DRAM, less VRAM used).

---

## Build

### `bun build` fails with `Text file busy`

You're running an instance of the existing patched binary while
trying to overwrite it. The `install + mv` pattern in
`build-patched-opencode.sh` avoids this; if you used a manual
`cp`, kill running opencode-patched processes first
(`pkill -f opencode-patched`).

### `bun add bun@1.3.13` lands a Windows .exe shim

Don't install bun via `bun add` -- npm's bun package distributes a
.exe shim that breaks the build. Use the official installer with a
custom `BUN_INSTALL` directory, the way `build-patched-opencode.sh`
does. See
[`opencode-zed-patches/install-and-wire.md`](../opencode-zed-patches/install-and-wire.md)
for the rationale.

### A patch fails to apply against opencode HEAD

The patches are pinned to opencode v1.14.28. `build-patched-opencode.sh`
checks out that tag; if you want to rebase against a newer opencode,
expect manual conflict resolution -- the patches are surgical and
small, but upstream may have refactored the file. See each
`fix-N-shipped.md` doc for the patch's intent so you can re-derive
the same change in the new file structure.

---

## Where to file bugs

- **The 2GPU stack itself** -- issues in this repo.
- **opencode upstream** -- https://github.com/sst/opencode/issues
  (use one of our patches as your starting point if it's a bug we
  already fixed locally; mention the patch by name).
- **llama.cpp** -- https://github.com/ggml-org/llama.cpp/issues.
- **Library, mnemory** -- the respective repos.

If you don't know which layer is at fault, that itself is the
question -- file in this repo and we'll help triage.
