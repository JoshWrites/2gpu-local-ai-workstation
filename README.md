# 2gpu-local-ai-workstation

<!-- AI-CONTEXT
This is the umbrella repo for a homelab agentic-coding workstation built
on a specific asymmetric two-GPU hardware setup. The umbrella holds
launcher scripts, systemd unit sources, opencode configs, opencode
patches, env-file structure, and operational docs. Library, an MCP
server used by this stack, is included as a submodule.

Build position: top-level project. Submodule: Library at github.com/JoshWrites/Library.
Sibling concerns (in ~/Documents/Workstation/, not this repo): workstation-wide
docs like ports-registry.md, the boot-cleanup notes, and the
more-than-pretty-lights repo.

This module's outputs: a runnable agentic-coding stack on a 7900 XTX +
5700 XT machine, plus the documentation describing how it was built.
This module's assumptions: ROCm 7.2.1, llama.cpp Vulkan build,
Ubuntu 24.04, opencode v1.14.28-derived patched binary, Zed editor
with isolated profile.

Common failure context: if a service refuses to start, check
/etc/workstation/system.env exists (Phase 1 invariant). If a path
reference breaks after a clone, check $WS_USER_ROOT in
~/.config/workstation/user.env points at this repo's checkout.
-->

## The problem

I had a 7900 XTX (24 GB) and an old 5700 XT (8 GB) sitting in the same
desktop. Local agentic coding on a single 24 GB card was fine for
small models but kept fighting itself: the chat model would evict
embeddings during retrieval, retrieval would slow down generation,
and the second GPU just sat there because the popular tools assume
you have one card.

I wanted to use both cards productively. The chat model on the big
card. Everything else (summarization, embeddings, edit-prediction)
on the small one. All of it co-resident, no swapping mid-session,
no manual juggling.

Doing that took more than just running four llama-server processes.
It needed a launcher that brings services up cleanly, polite shutdown
that does not yank the GPU out from under an active session, an
env-file structure that survives a machine rebuild, opencode patches
to fix Zed's permission UX, and an MCP server (Library) that knows
how to stay out of the chat model's context budget.

## What this gets you

If you have similar hardware (specifically: an asymmetric two-GPU
Linux box where the smaller GPU still has ~8 GB and the larger one
has ~24 GB), you can run this stack and get:

- Local chat model on the big card. GLM-4.7-Flash by default;
  swap any 16-22 GB Q4 model.
- Three sidecars on the small card, all loaded at once: a 4B
  summarizer, a multilingual embedding model, and a 3B coder model
  for editor edit-prediction. Total ~8.1 GB used, validated under
  load.
- A Library MCP server that does retrieval (web research, code-aware
  file mining, on-demand skill injection) and returns summaries by
  default to protect chat-model context.
- A patched opencode binary that makes Zed's agent panel actually
  show what bash command it wants to run before you approve it.
- A launcher that brings the whole stack up when you click a desktop
  icon, with a yad splash that shows progress, and shuts services
  down politely when nothing is using them.
- An env-file structure that survives `rm -rf /home && reinstall`.

If you have different hardware, the architectural choices and
configuration patterns transfer; the specific model weights and
device flags do not. The docs explain what each choice was for so
you can re-derive your own.

## What this does not get you

- A single-GPU stack. The whole design assumes two cards. If you
  only have one card, llama-swap or model-eviction patterns are
  better fits.
- An NVIDIA stack. ROCm and Vulkan are AMD-specific. Some pieces
  (the launcher, the env-file structure, opencode patches) port
  cleanly; the inference layer needs rework.
- A turnkey installer. Each section below has manual steps and
  decisions. The repo documents what I do; adapting it to your box
  takes thinking.

## What you need before you start

Hardware:
- An AMD primary GPU with at least 16 GB VRAM (24 GB recommended).
- A second AMD GPU with 8 GB VRAM. The setup is validated on
  a 7900 XTX + 5700 XT pair; other RDNA pairs probably work.

Software:
- Ubuntu 24.04 or similar. The systemd units and polkit rule
  assume systemd 255+.
- ROCm 7.2 or later, Vulkan loader installed.
- llama.cpp built with Vulkan backend (the binary path is hardcoded
  in unit files; Phase 2 of this project moved the binary to
  `/usr/local/lib/llama.cpp/llama-server` for system-wide
  consistency).
- bun runtime, for opencode build steps.
- Zed editor.
- jq, curl, ss, rocm-smi (probably already installed).

Disk:
- ~120 GB free for the model catalog. The setup uses GLM-4.7-Flash
  (~10 GB), Qwen3-4B (~2.5 GB), multilingual-e5-large (~0.6 GB),
  and Qwen2.5-Coder-3B (~2 GB) by default; the rest are optional
  extras tracked in the env file's `_AVAILABLE` lists.

Knowledge:
- Comfortable editing systemd unit files.
- Comfortable applying patches to a source tree and rebuilding.
- Willing to read 5-10 markdown files of design context before
  trusting a config.

## How to get it running

The full procedure is in `docs/reference-guide.md` and the
phase-tagged commits in this repo's history. The short version is
five real steps:

1. Clone this repo recursively (`git clone --recurse-submodules ...`)
   so Library is included.
2. Install the env files. Copy `configs/workstation/system.env.example`
   to `/etc/workstation/system.env`, edit values to match your machine,
   and the same for `user.env` and `secrets.env` under
   `~/.config/workstation/`. The `configs/workstation/README.md` has
   the full install steps.
3. Pull the model GGUFs. Default models and their expected paths
   come from `system.env`'s `WS_MODELS_DIR` value.
4. Run `scripts/install-systemd-units.sh`. It installs the four
   `llama-*` system units, the `llama-shutdown` helper, and the
   polkit rule that lets local users start and stop services
   without sudo.
5. Build the patched opencode binary. The procedure is in
   `opencode-zed-patches/install-and-wire.md`. The patches fix
   bash permission rendering in Zed.

Then the launcher script at `scripts/2gpu-launch.sh` starts the
services, shows a yad splash while they load, and opens Zed in an
isolated profile when ready. Set up the desktop entry to point at
that script, click the icon, and the stack comes up.

Library, the MCP server submodule, gets registered in
`opencode.json` automatically through the render-at-launch
templating. opencode finds Library on first agent thread.

## What to do when it does not work

A few real failure modes:

- **`scripts/install-systemd-units.sh` fails with "missing env file."**
  The env file at `/etc/workstation/system.env` has to exist before
  the units install. Do step 2 first.
- **A llama service starts but does not respond on its port.** Check
  the service's journal for the actual exec command:
  `journalctl -u llama-primary.service -n 50`. The most common cause
  is a wrong path in the unit's ExecStart line; env-var interpolation
  is shown literally in `systemctl show` output even when the runtime
  values are correct.
- **Zed agent panel says "Configuration is invalid."** The rendered
  `~/.config/opencode/opencode.json` got something wrong. Re-run the
  render manually by triggering `scripts/opencode-session.sh` from a
  terminal; it will print the exact JQ error before opencode launches.
- **Polite shutdown refuses while no Zed window is open.** Probably
  Zed left an orphaned opencode subprocess. Check with
  `pgrep -af opencode-patched`; kill any old process, then
  `llama-shutdown` again.
- **Edit prediction works in Zed but the agent panel does not.** The
  edit-prediction path uses llama-coder directly; the agent panel
  goes through opencode. If only the agent fails, the issue is in
  opencode-session.sh, the Library MCP, or opencode itself, not in
  the llama services.

## How this repo is laid out

```
2gpu-local-ai-workstation/
├── README.md                      this file
├── docs/                          how-the-stack-works docs
│   ├── reference-guide.md         full architectural reference
│   ├── tries-and-takeaways.md     running log of experiments
│   ├── opencode-conventions.md    how opencode is configured
│   ├── lessons-from-the-roo-era.md original-design history
│   ├── code-and-deps-review.md    audit of the dependencies
│   ├── community-stack-review.md  this stack vs. contemporaneous others
│   ├── vulkan-vs-rocm-benchmark.md ROCm vs Vulkan numbers on this hardware
│   ├── edit-prediction-on-secondary-research.md
│   └── research/                  prior-art surveys, research narrative
├── scripts/
│   ├── 2gpu-launch.sh             desktop-entry target
│   ├── opencode-session.sh        wrapper opencode is launched through
│   ├── install-systemd-units.sh   one-time machine setup
│   └── (benches and helpers)
├── systemd/                       canonical sources for system units
│   ├── llama-primary.service
│   ├── llama-secondary.service
│   ├── llama-embed.service
│   ├── llama-coder.service
│   ├── llama-shutdown             the polite-shutdown coordinator
│   └── polkit/10-llama-services.rules
├── configs/
│   ├── opencode/
│   │   ├── AGENTS.md              global agent rules (symlinked into ~/.config)
│   │   └── opencode.json.template render-at-launch template
│   └── workstation/
│       ├── system.env.example     root-owned, hardware/service shape
│       ├── user.env.example       per-user paths
│       └── secrets.env.example    machine-specific values, gitignored
├── bench/
│   └── regression.sh              30-assertion health check
├── opencode-zed-patches/          patches against opencode v1.14.28
├── Library/                       submodule: Library MCP server
├── archive/                       historical artifacts
│   ├── reviews-roo-era/           Roo Code era notes (closed chapter)
│   ├── library_and_patron/        retired V1 of Library
│   ├── permission-classifier/     unused opencode plugin, kept as reference
│   └── restructure-plan-2026-04-23.md
├── private/                       gitignored; per-user working notes
├── etc/                           a sysctl drop-in for Electron apps
├── memory-bank-template/          empty starting point for working notes
└── rules-templates/               agent rule templates
```

The `archive/` directory is real; the project predates its current
shape and the older artifacts are kept because they document why
specific choices were made.

## History

The original product framing was "Second Opinion" - a small support
model watching a large primary model, on the theory that two
perspectives produce better outcomes than one. That framing is
preserved in `docs/lessons-from-the-roo-era.md` and the various
historical research docs. The active stack is what worked; the
"second opinion" framing is what informed it.

## License

MIT. See LICENSE for the full text. The `opencode-zed-patches/`
contents are intended to apply against opencode (also MIT) and
could be submitted upstream under the same license.

## Acknowledgments

This stack stands on llama.cpp, opencode, Zed, ROCm, and the
multilingual-e5-large model. The patches in `opencode-zed-patches/`
build on the work in opencode PR #7374, which proved the agent.ts
fix shape before being closed. Library is its own thing but borrows
shape ideas from a dozen other MCP servers in the local-AI scene
through 2025-2026.
