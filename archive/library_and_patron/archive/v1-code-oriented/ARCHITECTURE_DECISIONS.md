# Architecture Decisions — AI Dev Environment

These are the agreed design choices, including decisions made during implementation.

---

## GPU Role Assignment — Dynamic, Not Hardcoded

**Decision**: GPU roles are resolved at runtime by `librarian/gpu_detect.py`, not by hardcoded index numbers.

**Rationale**: ROCm assigns GPU indices (0, 1) at boot based on PCIe enumeration order. These can change after hardware moves, BIOS updates, or kernel changes. Hardcoding `ROCR_VISIBLE_DEVICES=0` for a specific card is fragile.

**Implementation**: `gpu_detect.py` queries `rocm-smi` at startup, sorts GPUs by VRAM descending, and assigns:
- `INFER` role → largest VRAM card (7900 XTX, 24GB) — inference + initial indexing
- `EMBED` role → second-largest VRAM card (5700 XT, 8GB) — delta + query embeds

All code uses `INFER_URL` / `EMBED_URL` strings returned by `detect_gpus()`. No GPU index appears anywhere in application logic.

**Override hierarchy** (for when auto-detection is wrong):
1. `OLLAMA_GPU_INFER_URL` + `OLLAMA_GPU_EMBED_URL` — skip rocm-smi entirely
2. `LIBRARIAN_INFER_GPU_INDEX` + `LIBRARIAN_EMBED_GPU_INDEX` — use specific indices
3. Auto-detect by VRAM (default)

**Single-GPU fallback**: if only one GPU is found, both roles are assigned to it with a warning logged.

---

## Port Assignment

| Port | Service | Role |
|---|---|---|
| 11434 | ollama-gpu1 (INFER) | `qwen2.5-coder` inference + initial repo indexing |
| 11435 | ollama-gpu0 (EMBED) | `mxbai-embed-large` delta embeds + query embeds |
| 11436 | librarian | MCP HTTP server |

- Each GPU runs its own Ollama instance (separate systemd services, separate ports)
- Ollama hot-swaps models within a port on demand — no manual intervention needed
- Initial full index: INFER GPU does the embedding (fast, large VRAM) then hands off to EMBED GPU
- Ongoing operation: EMBED GPU handles all delta re-embeds and query embeds
- EMBED GPU (5700 XT) does NOT require `HSA_OVERRIDE_GFX_VERSION` — Ollama detects gfx1010:xnack- correctly on its own; setting the override breaks the llama runner

---

## Librarian: Persistent Service (not a Cline child process)

- Transport: **streamable HTTP** (MCP persistent server spec), not stdio
- Runs on `localhost:11436`
- Managed by session manager as a systemd service
- Accessible to any MCP-compatible client: Cline, Aider (when supported), CLI tools
- Cline and Aider both point to the same Librarian instance

---

## Librarian: Storage

- Vector store + catalog: **LanceDB**, always writing through to disk
- DB location: `~/.local/share/librarian/lancedb/<repo_name>/`
- Marker: `.librarian/` directory in each repo root
- `.librarian/` added to `.git/info/exclude` (repo-local, never touches project `.gitignore`)
- LanceDB is the source of truth — RAM is just the working cache (memory-mapped files)
- On service stop: LanceDB connections close cleanly, RAM released
- On service start: repos reload from disk in seconds (memory-map, no re-embedding)
- Full embeddings only ever run once per repo (initial index)
- Write-and-dump per batch: embed 16 chunks → write to LanceDB → discard vectors → next batch

**Schema — chunks table:**
```python
{ "repo", "file_path", "start_line", "end_line", "language", "content", "vector" (1024-dim float32) }
```

**Schema — catalog table:**
```python
{ "repo", "file_path", "mtime", "chunk_count", "indexed_at" }
```

**Note on paths**: catalog stores relative paths (e.g. `traefik/traefik.yaml`). `is_stale()` resolves them against `repo_path` before `stat()` — do not assume absolute paths in catalog entries.

---

## Librarian: Repo Watching

**Primary — implicit detection:**
- Poll VSCodium and Aider process args every 30s
- VSCodium: extract workspace path from process args
- Aider: read cwd from `/proc/<pid>/cwd`
- If detected repo has `.librarian/` → load and watch automatically
- If no `.librarian/` → do nothing (never auto-index without explicit permission)
- When repo closes/switches → stop watching, LanceDB connection closes, RAM freed

**Fallback — explicit always-watch list:**
```yaml
# ~/.config/librarian/watched_repos.yaml
always_watch:
  - /home/levine/Documents/Repos/LevineLabsServer1
```
- These repos are watched regardless of what apps are open
- Repo must already be indexed (have `.librarian/`) to be auto-loaded

**Union behavior:** both lists active simultaneously, no conflicts.

---

## Librarian: Live Delta Maintenance

- `watchdog` file watcher runs as background thread inside Librarian service
- Watches all currently-loaded repos for file changes
- 2s debounce prevents thrashing on rapid saves
- On file change: EMBED GPU re-embeds only that file's chunks → LanceDB incremental update
- Old rows for changed file deleted before new ones written
- Catalog updated immediately
- No manual re-index needed during a working session

---

## Librarian: Context Usage

- Always-watch repos sitting idle: **zero tokens consumed**
- LanceDB warm in RAM = fast queries, no model involvement
- EMBED GPU only activates on: file change (delta embed) or query (embed the query string)
- Model only ever sees top-N chunks when `get_relevant_context` is explicitly called

---

## Session Manager

Lightweight daemon (`ai-session`) that manages GPU service lifecycle.

**Startup: event-driven**
- `inotify` watch on trigger app binary directories (`/usr/bin`, `/usr/local/bin`, `~/.local/bin`)
- Trigger app executed → start all managed services immediately
- No polling delay on startup

**Shutdown: polling**
- Check every 10s whether any trigger app process is running
- All gone → start 60s grace period → stop all managed services
- Grace period prevents thrashing on brief close/reopen

**User-configurable:**
```yaml
# ~/.config/ai-session/config.yaml
trigger_apps:
  - codium
  - aider
  - code
  - zed
grace_period_seconds: 60
poll_interval_seconds: 10

# ~/.config/ai-session/services.yaml
services:
  - name: ollama-gpu1
    type: system
    required: true
  - name: ollama-gpu0
    type: system
    required: true
  - name: librarian
    type: system
    required: true
```

**Failure handling:**
- Service fails to start → `notify-send` desktop notification with two actions:
  - "Continue without" → skip that service for this session
  - "Retry" → attempt start once more, notify result
- Session manager logs and continues regardless of outcome

**Portability:**
- Session manager itself is app/service agnostic — all names are in config files
- To deploy on a new machine: copy `~/.config/ai-session/`, edit the two yaml files, enable the user service
- Add corresponding sudoers lines for any new services

---

## Librarian Environment Detection (repeatable pattern)

- Presence of `.librarian/` in a repo root = librarian-aware project
- Librarian service auto-detects and loads on startup
- `index_repo_tool` creates `.librarian/` and adds it to `.git/info/exclude`
- Any future tool/script can use this same convention

---

## What Was Built

### Librarian MCP Server — `librarian/`
- `gpu_detect.py` — dynamic GPU role detection via rocm-smi, VRAM-based assignment
- `server.py` — FastMCP entrypoint, HTTP transport, port 11436, calls detect_gpus() at startup
- `embedder.py` — role-based Ollama client, init(infer_url, embed_url) pattern
- `indexer.py` — file walking, chunking, batch embed + write-through to LanceDB
- `store.py` — LanceDB read/write, catalog management, staleness detection
- `watcher.py` — watchdog-based file watcher, 2s debounce, triggers delta re-embeds
- `repo_detector.py` — implicit repo detection from VSCodium/Aider process args

### Second Ollama Instance (EMBED GPU)
- `systemd/ollama-gpu0.service` — NOT enabled at boot, managed by session manager
- `ROCR_VISIBLE_DEVICES=0`, port 11435 (no HSA_OVERRIDE_GFX_VERSION — Ollama handles gfx1010 natively)

### Session Manager — `session_manager/`
- `manager.py` — inotify startup, polling shutdown, service control, notify-send
- `systemd/ai-session.service` — user systemd unit, always-on
- `systemd/ai-session-sudoers` — minimal passwordless sudo for service control
- `~/.config/ai-session/config.yaml` — trigger apps, timing
- `~/.config/ai-session/services.yaml` — managed services

### Tests
- `tests/auto_test.py` — 52 automated checks (0 failures)
- `tests/manual_checklist.md` — 16 hardware/UI checks

---

## Dependencies

```
mcp[cli]    lancedb    ollama    numpy    pyarrow
pathspec    watchdog   inotify-simple  pyyaml
```

---

## Key Constraints (do not violate)

- Never auto-index a repo without an explicit `index_repo_tool` call
- Never load chunks into model context without an explicit `get_relevant_context` call
- All MCP tool errors return text with no uncaught exceptions
- `.librarian/` never appears in project `.gitignore` — always `.git/info/exclude`
- Full re-embedding only on first index — delta only thereafter
- Session manager never hardcodes app or service names
- GPU roles always resolved via `gpu_detect.py` — never hardcode indices in application logic
