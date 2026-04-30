# library_and_patron

A local AI infrastructure system that gives coding models exactly the context they need — no more, no less.

Two components work together:

- **Librarian** — a persistent MCP server that indexes your code repositories using embeddings and answers "what's relevant to this query?" with a handful of precise chunks instead of dumping the whole repo into context.
- **Session Manager** — a lightweight daemon that starts and stops the GPU services automatically when you open your AI tools, and shuts everything down cleanly when you're done.

The **Patron** is the inference model itself (qwen2.5-coder on the 7900 XTX) — the one who walks up to the Librarian and checks out books. Everything else exists to serve it.

---

## The Problem This Solves

Local coding models have a VRAM budget. When Cline or Aider sends the full repo map + file contents to a model, that budget gets spent on noise — files that have nothing to do with the current task. The model runs out of KV cache room, crashes, or degrades.

Librarian intercepts that pattern. Instead of "here's everything," it answers "here's the 5 most relevant chunks for what you're asking about." The model stays focused, stays within budget, and gives better answers.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  You  →  Cline/Aider  →  qwen2.5-coder (Patron)  :11434            │
│                               7900 XTX — 24GB VRAM                  │
│                                                                      │
│  Model decides it needs context → generates MCP tool call           │
│  Cline executes it (transport only) → Librarian responds            │
│  Cline injects returned chunks into context → model sees them       │
└──────────────────────────┬───────────────────────────────────────────┘
                           │ tool calls (HTTP MCP)
                           ▼
          ┌────────────────────────────────────────┐
          │  Librarian  :11436                     │
          │  (HTTP MCP server)                     │
          │                                        │
          │  • Indexes repos                       │
          │  • Watches for changes                 │
          │  • Answers context queries             │
          │                                        │
          │  Initial index ───► Ollama :11434      │
          │  Delta + query ───► Ollama :11435      │
          └────────────────────────────────────────┘
                     mxbai-embed-large on both ports
                     :11435 = 5700 XT — 8GB (EMBED GPU)

┌─────────────────────────────────────────────────────────┐
│  Session Manager  (always-on user service)              │
│  Starts GPU services when AI tools open                 │
│  Stops them when all AI tools close (60s grace)         │
└─────────────────────────────────────────────────────────┘
```

### GPU Role Assignment

`gpu_detect.py` runs at Librarian startup and assigns GPU roles automatically by querying `rocm-smi` and sorting by VRAM:

- **INFER role** → largest VRAM card (7900 XTX, 24GB) — inference + initial repo indexing
- **EMBED role** → second-largest VRAM card (5700 XT, 8GB) — delta re-embeds + query embeds

No manual GPU index configuration is needed. If auto-detection is wrong, override with env vars:

```bash
OLLAMA_GPU_INFER_URL=http://localhost:11434
OLLAMA_GPU_EMBED_URL=http://localhost:11435
```

### Port Map

| Port | Process | Role |
|---|---|---|
| 11434 | ollama-gpu1 | Inference (`qwen2.5-coder`) + initial repo indexing |
| 11435 | ollama-gpu0 | `mxbai-embed-large` — delta re-embeds and query embeds |
| 11436 | librarian | MCP HTTP server — tools for Cline, Aider, etc. |

### Data Flow

**First time indexing a repo:**
1. You ask the model to index a repo → it calls `index_repo_tool` via Cline
2. Librarian walks all indexable files, respecting `.gitignore`
3. Files are chunked (~500 tokens, 50-token overlap)
4. Chunks are embedded via the INFER GPU Ollama in batches of 16
5. Vectors are written to LanceDB immediately (write-through, never accumulates in RAM)
6. A `.librarian/` marker is created in the repo root and added to `.git/info/exclude`

**Every subsequent session:**
1. Session Manager detects VSCodium/Aider opening → starts GPU services
2. Librarian detects the open repo (from process args) → loads LanceDB from disk in seconds
3. File watcher starts — any saved file is automatically re-embedded on the EMBED GPU within ~5s
4. Model decides it needs context → generates a `get_relevant_context` tool call → Cline executes it → Librarian embeds the query on the EMBED GPU and returns top-N chunks → Cline injects them into context
5. Model only ever sees those chunks — never the whole repo

**When you close your tools:**
1. Session Manager detects all AI apps closed → starts 60s grace period
2. Grace expires → stops librarian, ollama-gpu0, ollama-gpu1
3. LanceDB connections close → RAM freed
4. Index stays safely on disk, ready for next session

---

## Repository Layout

```
library_and_patron/
├── librarian/
│   ├── server.py        — FastMCP HTTP server, four tools
│   ├── embedder.py      — Ollama client, GPU1 initial / GPU0 delta+query
│   ├── indexer.py       — file walking, chunking, write-through indexing
│   ├── store.py         — LanceDB read/write, catalog, staleness detection
│   ├── watcher.py       — watchdog file watcher, debounced delta re-index
│   └── repo_detector.py — implicit repo detection from VSCodium/Aider processes
├── session_manager/
│   └── manager.py       — inotify startup, polling shutdown, notify-send failure handling
├── systemd/
│   ├── ollama-gpu0.service    — second Ollama instance for GPU0
│   ├── librarian.service      — Librarian as a system service
│   ├── ai-session.service     — Session Manager as a user service
│   └── ai-session-sudoers     — minimal sudoers drop-in
├── tests/
│   ├── auto_test.py           — 46 automated checks, no human needed
│   └── manual_checklist.md   — 16 hardware/UI checks requiring human observation
├── install.sh           — idempotent install script
├── pyproject.toml
├── ARCHITECTURE_DECISIONS.md  — every design decision with rationale
├── LIBRARIAN_BUILD_PLAN.md    — Librarian implementation spec
├── SESSION_MANAGER_BUILD_PLAN.md — Session Manager implementation spec
├── TEST_PLAN.md               — full structured test plan
└── CONTEXT.md                 — hardware environment and known gotchas
```

---

## MCP Tools

| Tool | Auto-approved | Description |
|---|---|---|
| `get_relevant_context` | yes | Embed a query, return top-N relevant chunks from an indexed repo |
| `list_indexed_repos` | yes | Show all indexed repos with file count, chunk count, last-indexed time |
| `get_index_status` | yes | Show index health for a specific repo, including stale file list |
| `index_repo_tool` | **no** | Full initial index — requires explicit approval (long-running) |

---

## Installation

### Prerequisites

- ROCm installed and working (`rocm-smi` returns output)
- Ollama installed as a system service (the existing `ollama` service becomes `ollama-gpu1`)
- Python 3.10+
- `libnotify-bin` for desktop notifications: `sudo apt install libnotify-bin`

### Steps

```bash
# 1. Clone
git clone git@github.com:JoshWrites/library_and_patron.git
cd library_and_patron

# 2. Run install script (handles venv, services, sudoers, user service)
./install.sh

# 3. Rename existing Ollama service to ollama-gpu1
# (exact steps depend on how Ollama was installed — see below)

# 4. Start the session manager
systemctl --user start ai-session.service

# 5. Open VSCodium — GPU services start automatically
# 6. Ask your model to index a repo — it will call index_repo_tool via Cline
#    GPU roles are detected automatically at startup (no manual configuration needed)
```

### Renaming the existing Ollama service

If Ollama was installed as `ollama.service`, you need to expose it as `ollama-gpu1` so the session manager can control it:

```bash
# Option A — symlink (non-destructive)
sudo ln -s /etc/systemd/system/ollama.service /etc/systemd/system/ollama-gpu1.service
sudo systemctl daemon-reload

# Option B — copy and disable original
sudo cp /etc/systemd/system/ollama.service /etc/systemd/system/ollama-gpu1.service
sudo systemctl disable ollama
sudo systemctl daemon-reload
```

Then update `~/.config/ai-session/services.yaml` if needed to use `ollama-gpu1`.

### Adding a new repo to always-watch

Edit `~/.config/librarian/watched_repos.yaml`:

```yaml
always_watch:
  - /path/to/your/repo
```

The repo must already be indexed (via `index_repo_tool`) to be auto-loaded. Librarian never indexes without explicit permission.

---

## Running the Tests

```bash
# Automated (no human needed, ~30s if already indexed)
# GPU roles are auto-detected via rocm-smi — no env vars required
.venv/bin/python tests/auto_test.py

# Manual (hardware verification, session manager)
# See tests/manual_checklist.md
```

---

## Configuration Files

| File | Purpose |
|---|---|
| `~/.config/ai-session/config.yaml` | Trigger apps and timing for session manager |
| `~/.config/ai-session/services.yaml` | Which systemd services to manage |
| `~/.config/librarian/watched_repos.yaml` | Always-watch repo list |

### Adding a new trigger app

Edit `~/.config/ai-session/config.yaml`:
```yaml
trigger_apps:
  - codium
  - aider
  - zed          # add new apps here
```

No code changes needed.

### Adding a new managed service

1. Add to `~/.config/ai-session/services.yaml`
2. Add corresponding `sudo` rules to `/etc/sudoers.d/ai-session`

---

## Known Constraints

- **GPU0 (5700 XT)** has unofficial ROCm support (gfx1010) but works without `HSA_OVERRIDE_GFX_VERSION` — Ollama detects the architecture correctly on its own. Do not set this variable in the service file; it breaks the llama runner.
- **`index_repo_tool` is intentionally not auto-approved** in Cline — indexing a large repo takes minutes and uses GPU1, which temporarily displaces the inference model.
- **Aider MCP support** is not available as of v0.86.2. When it lands, point Aider at `http://localhost:11436/mcp`.
- **`.librarian/` is never committed** — always goes into `.git/info/exclude`, not `.gitignore`.
