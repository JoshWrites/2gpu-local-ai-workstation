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

A complete local agentic-coding workstation that runs frontier-class
80B-parameter reasoning models, a coding specialist, and a fast
generalist on consumer AMD hardware -- using both an old card and a
new one productively, instead of letting one sit idle. No cloud
dependency, no datacenter GPU, no rental cost beyond electricity.

**One-line summary:** llama.cpp router-mode chat on a 24 GB GPU,
three concurrent sidecars (summarizer, embeddings, edit-prediction)
on an 8 GB GPU, a Library MCP that compresses retrieval before it
hits the chat context, and a patched opencode binary that makes Zed's
agent panel actually usable for local models.

**See also:**
[`docs/research/2026-05-03-stack-one-sheet.md`](docs/research/2026-05-03-stack-one-sheet.md)
for the architecture as a single page with measurements;
[`docs/research/2026-05-03-from-one-model-to-an-agentic-stack.md`](docs/research/2026-05-03-from-one-model-to-an-agentic-stack.md)
for the build history (Phases 1-13).

---

## Why this helps with older hardware

The popular local-AI tooling assumes one card. If you have an old GPU
in the same machine as a new one, the second card sits idle while the
big card thrashes. Embeddings get evicted to make room for the chat
model. Retrieval queues behind generation. Your good card is busy
doing things a worse card could handle.

This stack treats the two cards as different *kinds* of resource and
gives each the workload it's actually best at:

**Big card (24 GB, e.g. 7900 XTX) -- the stateful tier.** The chat
model lives here. It's the one workload that genuinely needs a
modern, fast GPU: token-by-token autoregressive generation through
an 80B-parameter MoE, with the 96K-token conversation history
re-evaluated every turn. The big card is reserved for it -- never
asked to do anything else mid-session.

**Small card (8 GB, e.g. 5700 XT) -- the stateless services tier.**
Three small models live here permanently, all loaded at once: a 4B
summarizer, a multilingual embedding model, and a 3B coder for
editor edit-prediction. Total ~8.1 GB used, validated under load.
Each task is *pure*: same input gives same output, no shared state.
That's exactly the shape an older card handles fine -- the bottleneck
is per-call latency, not raw throughput, and the Vulkan path on
consumer RDNA gear is plenty fast for that.

**The Library MCP -- the boundary between the tiers.** Library owns
type conversion: stateless raw output in (HTML, embeddings, file
contents), compressed summaries out (~325-450 tokens per research
call). It fans tool calls out to the small-card workers and CPU
sidecars (docling, pandoc, SearxNG), aggregates, ranks, and
summarizes their results -- so the chat model on the big card sees
only the answer, not the raw bytes. Without it, raw web research
overflows a 96K context window after about 7-10 lookups; with it,
a 15-call research session fits in 7% of the window.
Measured 22-43x compaction across two sessions.

**Persistent memory (mnemory).** Cross-session fact extraction and
recall, running on the same small-card sidecars (no extra GPU
load). The next session starts knowing what the previous one
learned.

**Net effect:** the older 8 GB card stops being dead weight and
becomes the part of the system that makes the 24 GB card usable for
a long agentic session. Frontier-class capability without renting
H100s.

If you have a single 24 GB card, this stack is overkill -- llama-swap
or a model-eviction pattern is a better fit. If your "old" card is
under 6 GB, the sidecar set won't fit and you'll need to drop one
(probably the coder; embeddings + summarizer are load-bearing).

---

## What you get

- **Local chat model on the big card via llama.cpp router mode** --
  one llama-server hosting a four-model pool: Qwen3-Next-80B-Thinking
  (frontier reasoning, 96K ctx, MoE-offload to DRAM), its non-thinking
  Instruct sibling, Qwen3-Coder-30B-Instruct (coding specialist, 64K
  ctx, fully GPU-resident), and GLM-4.7-Flash (fast generalist, 64K
  ctx). One model loaded at a time, swap on demand from inside Zed.
- **Three sidecars on the small card, all loaded at once:**
  Qwen3-4B summarizer, multilingual-e5-large embeddings,
  Qwen2.5-Coder-3B for edit-prediction. ~8.1 GB total VRAM.
- **A Library MCP server** that does retrieval (web research,
  code-aware file mining, on-demand skill injection) and returns
  summaries by default to protect chat-model context. Measured
  22-43x compaction vs. raw webfetch.
- **A patched opencode binary** (5 patches) that makes Zed's agent
  panel actually show what bash command it wants to run before you
  approve it, makes file-write/edit cards informative, surfaces
  skill-load permission requests with name and token cost, and
  drives the router-mode swap UX through a `/models` slash command
  in the chat panel.
- **A launcher** (`scripts/2gpu-launch.sh`) that brings the whole
  stack up when you click a desktop icon, with a yad splash showing
  progress, and shuts services down politely when nothing is using
  them.
- **An env-file structure** that survives `rm -rf /home && reinstall`
  -- system-shape config in `/etc/workstation/`, per-user paths in
  `~/.config/workstation/`, machine secrets in a third file that
  stays gitignored.
- **Persistent memory** (mnemory, port 8050) ingesting every chat
  turn so the next session starts informed.

If you have different hardware, the *architectural* choices and
configuration patterns transfer; the specific model weights and
device flags do not. The docs explain what each choice was for so
you can re-derive your own.

---

## Architecture at a glance

```
+---------------------------------------------------------------+
|  STATEFUL TIER -- 24 GB GPU + System RAM                      |
|                                                               |
|  Router-mode llama-server hosts a 4-model primary pool, one   |
|  loaded at a time, swapped via /models slash command.         |
|  Largest tenant: Qwen3-Next-80B-Thinking @ 96K context        |
|  (~19 GB on GPU + ~25 GB MoE offload to DRAM).                |
+---------------------------------------------------------------+
                ^                     |
                | summaries           | tool calls
                |                     v
+---------------------------------------------------------------+
|  LIBRARY MCP -- the boundary between tiers                    |
|  Owns the type conversion: stateless raw IN, summary OUT.     |
+---------------------------------------------------------------+
                ^                     |
                | raw output          | worker calls
                |                     v
+---------------------------------------------------------------+
|  STATELESS SERVICES TIER -- 8 GB GPU + CPU sidecars           |
|                                                               |
|  Vulkan llama-server on the small card hosts three models     |
|  concurrently: 4B summarizer, e5-large embeddings, 3B coder.  |
|  CPU sidecars: docling, pandoc, SearxNG.                      |
+---------------------------------------------------------------+
```

The full diagram with VRAM/DRAM breakdown, port assignments, and
mnemory's place in the stack is in
[the one-sheet](docs/research/2026-05-03-stack-one-sheet.md).

---

## Build it yourself

The full procedure with verification at each step is in
[`docs/install.md`](docs/install.md) (638 lines, top-to-bottom). The
procedure below is the *map* -- enough to decide whether you want to
take this on, and to find the right doc when you hit a step.

### Prerequisites

**Hardware:**
- AMD primary GPU with >=16 GB VRAM (24 GB recommended; the stack is
  sized for 24 GB).
- AMD secondary GPU with >=8 GB VRAM. Validated on 7900 XTX + 5700
  XT; other RDNA pairs probably work.

**Software:**
- Ubuntu 24.04 or similar, systemd 255+.
- ROCm 7.2+ and the Vulkan loader installed.
- bun runtime (for the opencode build).
- Zed editor with the `acp-beta` feature flag enabled.
- `yad`, `notify-send`, `jq`, `curl`, `ss`, `rocm-smi` (most are
  default-installed).

**Disk:** ~120 GB free for the model catalog. The default set
(GLM-4.7-Flash, Qwen3-Next-80B variants, Qwen3-Coder-30B,
Qwen3-4B, e5-large, Qwen2.5-Coder-3B) is around 100 GB; the rest
is breathing room.

**Knowledge:** comfortable editing systemd unit files and applying
patches to a source tree. Willing to read 5-10 markdown files of
design context before trusting a config.

### Step 1: Build llama.cpp twice

Two builds, two install paths -- one tuned for each GPU:

- **HIP build** at `/usr/local/lib/llama.cpp-hip/llama-server` --
  drives the primary GPU's router-mode unit. HIP's fast-fused FA
  path is what makes 96K context fit on 24 GB at acceptable speed.
- **Vulkan build** at `/usr/local/lib/llama.cpp/llama-server` --
  drives the three sidecar units on the secondary GPU. Vulkan is
  the more compatible path for older RDNA cards (the 5700 XT is
  unofficially supported in ROCm; Vulkan side-steps that).

The exact CMake invocations and the rationale for splitting are in
[`docs/install.md`](docs/install.md) and
[`docs/vulkan-vs-rocm-benchmark.md`](docs/vulkan-vs-rocm-benchmark.md).

### Step 2: Pull the GGUFs

`/var/lib/llama-models/<model-id>/` is the catalog root. The default
models are listed in
[`configs/workstation/llama-router.ini`](configs/workstation/llama-router.ini)
(primary pool) and the three sidecar service files in
[`systemd/`](systemd/). HuggingFace links are in the install doc.

### Step 3: Install env files and the polkit rule

The env-file split is the part of the stack that survives a `/home`
reinstall. There are three files, each owned by a different actor:

- `/etc/workstation/system.env` -- root-owned, hardware/service
  shape. Includes `WS_LLAMA_USERS` (space-separated usernames who
  get passwordless control over `llama-*` units).
- `~/.config/workstation/user.env` -- per-user paths. Contains
  `WS_USER_ROOT` (this repo's checkout path).
- `~/.config/workstation/secrets.env` -- gitignored, machine-specific
  values.

Examples are at
[`configs/workstation/*.example`](configs/workstation/). Copy each,
edit, install with the right ownership.

Run [`scripts/install-systemd-units.sh`](scripts/install-systemd-units.sh)
once to install the four `llama-*` units (one router + three
sidecars), the polite-shutdown coordinator, and the polkit rule.
The rule's `allowedUsers` array is rendered from `WS_LLAMA_USERS`
at install time, so real usernames never enter the repo.

### Step 4: Patch opencode

Stock opencode in a Zed agent panel asks for permission to run a
tool but doesn't always show *what* the tool will do. For bash that
means an empty box where the command should be. For file-write/edit
that means a bare tool name with no path. With a small local model
(GLM-4.7-Flash, Qwen3-Coder-30B) that frequently skips the optional
`description` argument, the user has nothing to approve or deny on.

Five patches in [`opencode-zed-patches/`](opencode-zed-patches/) fix
that:

| Patch | What it does |
|---|---|
| `our-patch-agent.diff` | Looks up the actual tool input from the message store before sending the permission request. Renders a two-line title: verbatim subject (command for bash, `<tool> <path>` for write/edit) on line 1, model-supplied description on line 2. |
| `our-patch-bash.diff` | Renders working-directory and command text on the permission card via the ACP `_meta.terminal_info` convention, plus streams terminal output back to Zed during execution. |
| `our-patch-tools.diff` | Adds a required `description` parameter to the `write` and `edit` tool schemas. With `--jinja` on, llama.cpp's grammar-constrained sampling forces the model to emit one on every call. |
| `our-patch-skill-permission.diff` | Enriches the skill-load permission card with name, description, location, and an estimated token cost. The user sees what the skill is for and how much context it will eat before clicking Allow. |
| `our-patch-router-swap-v3.diff` | Confirm-card UX for model swaps in router mode, collapsed onto a single `/models` slash command. Picker pick, typed `/models <id>`, and bare `/models` (list mode) all converge on one dispatch path that runs `model-swap.sh --preflight`, raises an ACP `swap` permission_request, and on Allow streams `--execute` output as a foldable terminal block. |

The build:

```bash
git clone https://github.com/sst/opencode
cd opencode && git checkout v1.14.28
for p in /path/to/2gpu/opencode-zed-patches/our-patch-*.diff; do
  git apply "$p"
done
bun install
bun build
sudo install -m 755 dist/opencode /usr/local/bin/opencode-patched
```

Point Zed at the patched binary by setting `OPENCODE_BIN` and
`OPENCODE_MODEL_SWAP_SCRIPT` in
`~/.local/share/zed-second-opinion/config/settings.json` under
`agent_servers.opencode.command.env`.

The full procedure with copy-paste lines and a smoke test is in
[`opencode-zed-patches/install-and-wire.md`](opencode-zed-patches/install-and-wire.md).
The design rationale for each patch is in the matching
`fix-N-shipped.md` file.

### Step 5: Bootstrap the Library MCP

Library is a git submodule. After `git clone --recurse-submodules`,
its venv bootstraps with `uv sync` inside the `Library/` directory.
Library is registered in opencode automatically via the rendered
`opencode.json` template -- you don't add it manually.

See [`Library/README.md`](Library/README.md) for the tool surface
(`library_research`, `library_read_file`, `library_convert`,
`library_export`, `library_context_usage`) and the agent-side
routing rules in [`configs/opencode/AGENTS.md`](configs/opencode/AGENTS.md).

### Step 6: The launcher

[`scripts/2gpu-launch.sh`](scripts/2gpu-launch.sh) is the desktop-entry
target. When you click the icon it:

1. Renders `opencode.json` from the template, querying the router's
   `/models` endpoint to discover what's actually loaded and patching
   the top-level `model` and `agent.compaction.model` fields to
   match. (This is fix-9 -- see Phase 12 in the build history for
   why it exists.)
2. Brings the four `llama-*` services up via `systemctl start`
   (no password prompt thanks to the polkit rule), with a yad
   splash showing per-service status.
3. Ensures Library is reachable.
4. exec's Zed in the isolated profile pointed at the patched
   opencode binary.

Polite shutdown is a separate coordinator
([`systemd/llama-shutdown`](systemd/llama-shutdown)) that watches
for active sessions and stops services when nothing is using them.
See [`docs/lifecycle-management.md`](docs/lifecycle-management.md).

### Step 7: Verify

[`bench/regression.sh`](bench/regression.sh) is a 30-assertion
health check covering env files, services, ports, polkit, model
GGUFs on disk, and Library reachability. Run it after install;
every assertion should pass before you click the desktop icon.

---

## When it does not work

Most-common failure modes:

- **`scripts/install-systemd-units.sh` fails with "missing env
  file."** `/etc/workstation/system.env` has to exist before the
  units install. Do step 3 first.
- **A llama service starts but does not respond on its port.**
  Check the service's journal:
  `journalctl -u llama-primary-router.service -n 50`. Most common
  cause is a wrong path in the unit's ExecStart line; env-var
  interpolation is shown literally in `systemctl show` output even
  when runtime values are correct. For the primary router, also
  check `/etc/workstation/llama-router.ini` exists and parses --
  `curl http://localhost:11434/v1/models` should list the pool.
- **Picking a model in Zed gives a silent failure with no card.**
  `OPENCODE_MODEL_SWAP_SCRIPT` is missing from Zed's isolated profile
  config. Without it the patched opencode falls through to a plain
  400 error. Add it under
  `agent_servers.opencode.command.env`.
- **Every Zed launch prompts for the admin password.** The polkit
  allowlist at `/etc/polkit-1/rules.d/10-llama-services.rules` is
  missing the unit name being started. Re-run
  `scripts/install-systemd-units.sh`; it re-renders the rule from
  the template and `WS_LLAMA_USERS`.
- **Zed agent panel says "Configuration is invalid."** The
  rendered `~/.config/opencode/opencode.json` is malformed. Run
  `scripts/opencode-session.sh` from a terminal; it prints the
  exact `jq` error before opencode launches.
- **Polite shutdown refuses while no Zed window is open.** Probably
  Zed left an orphaned opencode subprocess. Check
  `pgrep -af opencode-patched`; kill it, then `llama-shutdown`
  again.
- **Edit prediction works in Zed but the agent panel does not.**
  Edit-prediction goes to llama-coder directly; the agent panel
  goes through opencode + Library. If only the agent fails, the
  issue is in `opencode-session.sh`, the Library MCP, or opencode
  itself -- not the llama services.

[`docs/lessons-learned.md`](docs/lessons-learned.md) has the longer
list, including failures from earlier phases that are no longer
reachable on `main` but worth knowing about if you derive from this.

---

## How this repo is laid out

```
2gpu-local-ai-workstation/
├── README.md                      this file
├── docs/                          how-the-stack-works docs
│   ├── install.md                 the canonical install procedure
│   ├── reference-guide.md         full architectural reference
│   ├── tries-and-takeaways.md     running log of experiments
│   ├── opencode-conventions.md    how opencode is configured
│   ├── lessons-from-the-roo-era.md original-design history
│   ├── llama-services-reference.md the four llama-* units in detail
│   ├── lifecycle-management.md    polite-shutdown semantics
│   ├── code-and-deps-review.md    audit of the dependencies
│   ├── community-stack-review.md  this stack vs. contemporaneous others
│   ├── vulkan-vs-rocm-benchmark.md ROCm vs Vulkan numbers on this hardware
│   └── research/                  prior-art surveys, build narrative
│       ├── 2026-05-03-stack-one-sheet.md           one-page architecture
│       ├── 2026-05-03-from-one-model-to-an-agentic-stack.md
│       │                          phases 1-13 build history
│       └── scripts/               reproducible measurement scripts
├── scripts/
│   ├── 2gpu-launch.sh             desktop-entry target
│   ├── opencode-session.sh        opencode launcher (renders opencode.json)
│   ├── install-systemd-units.sh   one-time machine setup (renders polkit rule)
│   ├── model-swap.sh              router-mode swap engine, called by patch v3
│   └── (other helpers)
├── systemd/                       canonical sources for system units
│   ├── llama-primary-router.service   one llama-server, multiple models
│   ├── llama-secondary.service        4B summarizer (small card)
│   ├── llama-embed.service            e5-large embeddings (small card)
│   ├── llama-coder.service            3B coder, edit-prediction (small card)
│   ├── llama-shutdown                 polite-shutdown coordinator
│   └── polkit/10-llama-services.rules template (allowedUsers rendered at install)
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
│   └── oss-tuning.sh              preset A/B harness
├── opencode-zed-patches/          patches against opencode v1.14.28
├── Library/                       submodule: Library MCP server
├── archive/                       historical artifacts (Roo era, retired V1)
├── private/                       gitignored; per-user working notes
├── etc/                           sysctl drop-in for Electron apps
├── memory-bank-template/          empty starting point for working notes
└── rules-templates/               agent rule templates
```

The `archive/` directory is real. The project predates its current
shape and the older artifacts are kept because they document why
specific choices were made.

---

## Further reading

If you only read two docs, read these:

- [**The one-sheet**](docs/research/2026-05-03-stack-one-sheet.md)
  -- the architecture as a single page with measured numbers
  (throughput, stability, Library compaction).
- [**The build history**](docs/research/2026-05-03-from-one-model-to-an-agentic-stack.md)
  -- 13 phases from "two cards sitting in the same desktop" to the
  current configuration. Includes the wrong turns.

For depth on specific subsystems:

- [`docs/install.md`](docs/install.md) -- the canonical install
  procedure (638 lines, every step verified).
- [`docs/llama-services-reference.md`](docs/llama-services-reference.md)
  -- the four llama-* units, their flags, and how to swap models.
- [`docs/lifecycle-management.md`](docs/lifecycle-management.md) --
  polite-shutdown design.
- [`docs/reference-guide.md`](docs/reference-guide.md) -- the full
  architectural reference (long).
- [`opencode-zed-patches/README.md`](opencode-zed-patches/README.md)
  -- the five patches in detail.
- [`Library/README.md`](Library/README.md) -- the Library MCP.

---

## History

The original product framing was "Second Opinion" -- a small support
model watching a large primary model, on the theory that two
perspectives produce better outcomes than one. That framing is
preserved in [`docs/lessons-from-the-roo-era.md`](docs/lessons-from-the-roo-era.md)
and the historical research docs. The active stack is what worked;
the "second opinion" framing is what informed it.

## License

MIT. See LICENSE for the full text. The `opencode-zed-patches/`
contents are intended to apply against opencode (also MIT) and could
be submitted upstream under the same license.

## Acknowledgments

This stack stands on llama.cpp, opencode, Zed, ROCm, and the
multilingual-e5-large model. The patches in `opencode-zed-patches/`
build on the work in opencode PR #7374, which proved the agent.ts
fix shape before being closed. Library is its own thing but borrows
shape ideas from a dozen other MCP servers in the local-AI scene
through 2025-2026.
