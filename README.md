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
This module's assumptions: ROCm 7.2.1, llama.cpp built two ways
(HIP for the primary GPU's router-mode unit, Vulkan for the secondary
sidecars), Ubuntu 24.04, opencode v1.14.28-derived patched binary
(5 patches), Zed editor with isolated profile.

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

- Local chat model on the big card via llama.cpp router mode -- one
  llama-server hosting GLM-4.7-Flash (~30 GB, fast default) and
  GPT-OSS-120B (116B-param MoE, 128K context, expert-offload to DRAM)
  on the same port, swapping on demand. Picking a not-loaded model
  in Zed's footer triggers a yad confirm dialog and a progress popup;
  the swap completes in ~35 s for GLM or ~4 min for OSS.
- Three sidecars on the small card, all loaded at once: a 4B
  summarizer, a multilingual embedding model, and a 3B coder model
  for editor edit-prediction. Total ~8.1 GB used, validated under
  load.
- A Library MCP server that does retrieval (web research, code-aware
  file mining, on-demand skill injection) and returns summaries by
  default to protect chat-model context.
- A patched opencode binary (5 patches) that makes Zed's agent panel
  actually show what bash command it wants to run before you approve
  it, makes file-write/edit cards informative, surfaces skill-load
  permission requests with name and token cost, and triggers the
  router-mode swap UX when you pick a not-loaded model. See
  `docs/research/2026-05-03-zed-ux-improvements.md` for the full
  walkthrough.
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
- llama.cpp built two ways:
  - **HIP** at `/usr/local/lib/llama.cpp-hip/llama-server` -- the
    primary GPU's router-mode unit, hosts GLM and OSS on demand.
  - **Vulkan** at `/usr/local/lib/llama.cpp/llama-server` -- the
    three sidecar units on the 5700 XT (secondary, embed, coder).
- bun runtime, for opencode build steps.
- Zed editor with `acp-beta` feature flag enabled.
- yad (for the model-swap popup), notify-send, jq, curl, ss,
  rocm-smi (probably already installed except yad).

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

The full procedure with verification at each step is in
`docs/install.md`. It walks you from a fresh clone through the
first launch, with prerequisites named explicitly so you can
spot-check what your machine has before starting.

The shape of the install:

1. Clone this repo (with `--recurse-submodules` so Library
   submodule comes along).
2. Build llama.cpp twice -- Vulkan at
   `/usr/local/lib/llama.cpp/llama-server` (sidecars) and HIP at
   `/usr/local/lib/llama.cpp-hip/llama-server` (router).
3. Pull the model GGUFs to `/var/lib/llama-models/`.
4. Install the env files. Set `WS_LLAMA_USERS` in
   `/etc/workstation/system.env` to the space-separated list of
   local usernames who should have passwordless llama-* control.
5. Install the router-mode preset INI at
   `/etc/workstation/llama-router.ini` (sourced from
   `configs/workstation/llama-router.ini`).
6. Run `scripts/install-systemd-units.sh`. Installs the four
   `llama-*` units (one router + three sidecars), the
   polite-shutdown coordinator, and the polkit rule. The polkit
   rule's `allowedUsers` array is rendered from `WS_LLAMA_USERS`
   at install time, so real usernames never enter the repo.
7. Build the patched opencode binary (5 patches).
8. Bootstrap the Library MCP venv with `uv sync`.
9. Set up Zed's isolated profile, including
   `OPENCODE_MODEL_SWAP_SCRIPT` env var pointing at
   `scripts/model-swap.sh`.
10. Symlink AGENTS.md (the repo root has a symlink for
    opencode's `findUp()`; the global copy in `~/.config/opencode/`
    is also fine).
11. Install the desktop entry.
12. Run `bench/regression.sh` to verify everything is in place.

Then click the desktop icon. The launcher brings the llama services
up with a progress splash and opens Zed in the isolated profile.
Library gets registered in opencode.json automatically through the
render-at-launch templating.

For the deeper context behind each piece:

- Lifecycle and polite shutdown: `docs/lifecycle-management.md`.
- The four llama services and how to swap models:
  `docs/llama-services-reference.md`.
- The env files: `configs/workstation/README.md`.
- The opencode template: `configs/opencode/README.md`.
- The Library MCP: `Library/README.md`.
- The opencode patches: `opencode-zed-patches/README.md`.

## What to do when it does not work

A few real failure modes:

- **`scripts/install-systemd-units.sh` fails with "missing env file."**
  The env file at `/etc/workstation/system.env` has to exist before
  the units install. Do step 2 first.
- **A llama service starts but does not respond on its port.** Check
  the service's journal for the actual exec command:
  `journalctl -u llama-primary-router.service -n 50`. The most common
  cause is a wrong path in the unit's ExecStart line; env-var
  interpolation is shown literally in `systemctl show` output even
  when the runtime values are correct. For the primary router, also
  check `/etc/workstation/llama-router.ini` exists and parses
  (`curl http://localhost:11434/models` should list both presets).
- **Picking a model in Zed gives a silent failure with no popup.**
  The `OPENCODE_MODEL_SWAP_SCRIPT` env var is missing from Zed's
  isolated profile config. Without it, the patched opencode falls
  through to a plain 400 error. Add it to
  `~/.local/share/zed-second-opinion/config/settings.json` under
  `agent_servers.opencode.command.env`.
- **Every Zed launch prompts for the admin password.** The polkit
  allowlist at `/etc/polkit-1/rules.d/10-llama-services.rules` is
  missing the unit name being started. Re-run
  `scripts/install-systemd-units.sh` -- it re-renders the rule from
  the template and `WS_LLAMA_USERS`.
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
│   ├── install-systemd-units.sh   one-time machine setup (renders polkit rule)
│   ├── model-swap.sh              yad swap UX, called by the router-swap patch
│   └── (other helpers)
├── systemd/                       canonical sources for system units
│   ├── llama-primary-router.service   one llama-server, multiple models
│   ├── llama-primary.service          (legacy, masked, kept for rollback)
│   ├── llama-primary-experiment.service (legacy, masked, kept for rollback)
│   ├── llama-secondary.service
│   ├── llama-embed.service
│   ├── llama-coder.service
│   ├── llama-shutdown             the polite-shutdown coordinator
│   └── polkit/10-llama-services.rules  template (allowedUsers rendered at install)
├── configs/
│   ├── opencode/
│   │   ├── AGENTS.md              global agent rules (also symlinked at repo root)
│   │   └── opencode.json.template render-at-launch template
│   └── workstation/
│       ├── llama-router.ini       per-model llama-server flags (router source of truth)
│       ├── primary-pool.json      registry model-swap.sh reads
│       ├── system.env.example     root-owned, hardware/service shape (incl. WS_LLAMA_USERS)
│       ├── user.env.example       per-user paths
│       └── secrets.env.example    machine-specific values, gitignored
├── bench/
│   ├── regression.sh              30-assertion health check
│   └── oss-tuning.sh              preset A/B harness (router /models/load + curl)
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
