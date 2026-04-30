# Project Context — library_and_patron

This file captures the hardware environment, known gotchas, and project history needed to work on this project without losing prior session knowledge.

---

## Hardware

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 9 5950X, 16-core/32-thread |
| RAM | 64GB DDR4 |
| GPU0 | AMD Radeon RX 5700 XT — 8GB VRAM, gfx1010, PCIe `0000:06:00.0` |
| GPU1 | AMD Radeon RX 7900 XTX — 24GB VRAM, gfx1100, PCIe `0000:0F:00.0` |
| OS | Linux, shell: zsh |
| Editor | VSCodium (not VS Code) |

**GPU0 ROCm note**: gfx1010 has unofficial ROCm support. `HSA_OVERRIDE_GFX_VERSION=10.3.0` is NOT needed for Ollama — Ollama's bundled ROCm correctly identifies the card as `gfx1010:xnack-` on its own. Setting the override actually breaks it (llama runner hangs at 0% progress). Do NOT set `HSA_OVERRIDE_GFX_VERSION` in `ollama-gpu0.service`.

**GPU index stability warning**: ROCm assigns GPU indices (0, 1) at boot based on PCIe enumeration order. They are NOT guaranteed stable across hardware changes or BIOS updates. The system handles this automatically via `gpu_detect.py` — do not hardcode GPU indices anywhere.

**Current observed indices** (verify with `rocm-smi --showproductname`):
- `GPU[0]` = 5700 XT — EMBED role (delta + query embeds)
- `GPU[1]` = 7900 XTX — INFER role (inference + initial indexing)

---

## Existing Infrastructure

### Ollama (INFER GPU, port 11434)
- System service: `/etc/systemd/system/ollama.service.d/override.conf`
- Pinned to current INFER GPU via `ROCR_VISIBLE_DEVICES=1`
- Models available: `qwen2.5-coder:14b-instruct-q8_0`, `qwen2.5-coder:32b`, `mxbai-embed-large`, `llama3.1:8b-instruct-q4_K_M`
- `OLLAMA_KEEP_ALIVE=1h`, `OLLAMA_HOST=0.0.0.0:11434`

### local-mcp-servers repo
- `/home/levine/Documents/Repos/local-mcp-servers/`
- Has `.venv` with `mcp[cli]`
- `sysmon.py`: live GPU/RAM/Ollama monitoring MCP server

---

## Known Failure Modes

### OOM / Ollama crashes
- qwen2.5-coder:32b (19GB) split across both GPUs leaves zero VRAM for KV cache — crashes on any non-trivial context
- qwen2.5-coder:14b-q8 (15GB) on INFER GPU crashes when Cline sends >~16k tokens
- Root cause: Cline sends the full repo map + file contents by default
- Fix: Librarian MCP — model only ever sees top-N relevant chunks

### Ollama model hot-swap
- Ollama unloads the current model and loads the new one when you call a different model name
- Cost: a few seconds of load time — acceptable for our use case
- This is how we share a single Ollama instance across embed + inference roles

### EMBED GPU (5700 XT) ROCm instability
- gfx1010 support is unofficial — if embedding causes hangs, fall back to INFER GPU for all embeds
- Override: set `OLLAMA_GPU_INFER_URL` and `OLLAMA_GPU_EMBED_URL` to the same port to force single-GPU mode
- Always test with `rocm-smi` watching during first indexing run

### LanceDB API version
- `LanceTable.to_list()` does not exist in lancedb 0.29+ — use `.to_arrow().to_pylist()`
- Search query builder (`LanceVectorQueryBuilder`) does have `.to_list()` — only the bare table does not

### is_stale() path resolution
- Catalog stores relative file paths (e.g. `traefik/traefik.yaml`)
- `is_stale()` must resolve them against repo_path before calling `stat()` — fixed in store.py

---

## Project Purpose

**library_and_patron** is a two-component local AI infrastructure system:

1. **Librarian** (`librarian/`) — persistent MCP server that indexes code repos using embeddings and serves relevant context chunks on demand. Replaces "send the whole repo" with "send only what's relevant."

2. **Session Manager** (`session_manager/`) — lightweight daemon that starts/stops GPU services (Ollama instances, Librarian) when AI applications open and closes them when all AI apps exit.

---

## GPU Role System

GPU roles are resolved at startup by `gpu_detect.py` — never hardcoded:

| Role | Assigned to | How determined |
|---|---|---|
| `INFER` | Largest VRAM card | rocm-smi VRAM sort, descending |
| `EMBED` | Second-largest VRAM card | rocm-smi VRAM sort, descending |

Override env vars (if auto-detection is wrong):
- `OLLAMA_GPU_INFER_URL` — force infer URL
- `OLLAMA_GPU_EMBED_URL` — force embed URL
- `LIBRARIAN_INFER_GPU_INDEX` + `LIBRARIAN_EMBED_GPU_INDEX` — force by index

---

## Port Map

| Port | Role | Card (current) |
|---|---|---|
| 11434 | INFER — `qwen2.5-coder` inference + initial repo indexing | 7900 XTX |
| 11435 | EMBED — `mxbai-embed-large` delta + query embeds | 5700 XT |
| 11436 | Librarian MCP server (HTTP) | CPU |

---

## Document Index

| File | Contents |
|---|---|
| `README.md` | User-facing overview, architecture diagram, install steps |
| `ARCHITECTURE_DECISIONS.md` | Every design decision with rationale |
| `LIBRARIAN_BUILD_PLAN.md` | Librarian implementation spec (v2) |
| `SESSION_MANAGER_BUILD_PLAN.md` | Session Manager implementation spec |
| `TEST_PLAN.md` | Full structured test plan |
| `CONTEXT.md` | This file — hardware, gotchas, current state |

---

## Current Implementation State

**BUILT and tested:**
- `librarian/gpu_detect.py` — dynamic role detection via rocm-smi
- `librarian/embedder.py` — role-based Ollama client, init() pattern
- `librarian/indexer.py` — file walking, chunking, write-through indexing
- `librarian/store.py` — LanceDB with catalog, staleness detection
- `librarian/watcher.py` — watchdog delta re-index with debounce
- `librarian/repo_detector.py` — implicit VSCodium/Aider detection + always-watch
- `librarian/server.py` — FastMCP HTTP on port 11436, four tools
- `session_manager/manager.py` — inotify startup, polling shutdown, notify-send
- `systemd/` — all service units and sudoers drop-in
- `install.sh` — idempotent install script
- `tests/auto_test.py` — 52 automated checks, all passing
- `tests/manual_checklist.md` — 16 hardware/UI checks

**Pending (manual test steps):**
- `ollama-gpu0.service` install and GPU0 Ollama verification (manual checklist 2A)
- Session manager service lifecycle test (manual checklist 7)
- GPU VRAM routing observation (manual checklist 1, 2B, 3)

## Test Repo
- Primary: `/home/levine/Documents/Repos/LevineLabsServer1`
- Already indexed: 24 files, 77 chunks
- Expected: `get_relevant_context("traefik routing", ...)` returns `.yaml` chunks from `traefik/`
