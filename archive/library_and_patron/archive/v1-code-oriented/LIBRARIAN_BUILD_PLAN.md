# Librarian MCP Server — Build Plan (v2)

Supersedes the original plan. See `ARCHITECTURE_DECISIONS.md` for full rationale.

---

## Status: BUILT

This plan has been implemented. See `CONTEXT.md` for current state.
The repo is at `/home/levine/Documents/Repos/Workstation/library_and_patron/`.

## Original Context

- Linux, VSCodium, zsh
- GPU0: 5700 XT (gfx1010, 8GB) — unofficial ROCm support, but Ollama handles it natively (no HSA_OVERRIDE needed)
- GPU1: 7900 XTX (gfx1100, 24GB) — primary inference GPU, Ollama on port 11434
- GPU indices are NOT hardcoded — resolved at runtime by `gpu_detect.py` via rocm-smi

---

## Goal

A persistent MCP server that:
1. Indexes repos using embeddings (GPU1 for initial, GPU0 for deltas)
2. Watches indexed repos for changes and keeps the index current in real time
3. Serves relevant context chunks on demand so the coding model only sees a small focused slice
4. Auto-detects open repos from running processes
5. Persists its index to `.librarian/` in each repo root — reloads on startup, no re-embedding needed

---

## Hardware / Port Assignment

| Port | GPU | Role |
|---|---|---|
| 11434 | GPU1: 7900 XTX | Inference (`qwen2.5-coder`) + initial repo indexing (`mxbai-embed-large`) |
| 11435 | GPU0: 5700 XT | Delta embeds + query embeds (`mxbai-embed-large`) |
| 11436 | CPU/any | Librarian MCP server (HTTP transport) |

---

## Repository Structure (as built)

```
library_and_patron/
├── librarian/
│   ├── __init__.py
│   ├── gpu_detect.py      # dynamic GPU role detection via rocm-smi (added post-plan)
│   ├── server.py          # MCP entrypoint, HTTP transport, port 11436
│   ├── embedder.py        # role-based Ollama client, init(infer_url, embed_url) pattern
│   ├── indexer.py         # file walking, chunking, batch embed + write-through
│   ├── store.py           # LanceDB read/write, catalog management
│   ├── watcher.py         # watchdog file watcher, 2s debounce, triggers delta re-embeds
│   └── repo_detector.py   # implicit repo detection from VSCodium/Aider process args
├── session_manager/
│   └── manager.py
├── systemd/               # service units and sudoers
├── tests/
│   ├── auto_test.py       # 52 automated checks
│   └── manual_checklist.md
├── pyproject.toml
├── install.sh
└── ARCHITECTURE_DECISIONS.md
```

---

## Dependencies to Add to pyproject.toml

```
lancedb
ollama
numpy
pyarrow
pathspec
watchdog
```

---

## Environment Variables (set in systemd service unit)

```
# GPU routing — gpu_detect.py auto-detects by VRAM if these are not set
OLLAMA_GPU_INFER_URL=http://localhost:11434  # override: force infer URL
OLLAMA_GPU_EMBED_URL=http://localhost:11435  # override: force embed URL
# LIBRARIAN_INFER_GPU_INDEX=1              # override: force by index
# LIBRARIAN_EMBED_GPU_INDEX=0              # override: force by index

ROCR_VISIBLE_DEVICES=0           # Librarian process affinity (for non-Ollama ROCm ops)
# NOTE: HSA_OVERRIDE_GFX_VERSION is NOT set — Ollama detects gfx1010:xnack- correctly on its own

LIBRARIAN_PORT=11436
LIBRARIAN_DB_BASE=~/.local/share/librarian/lancedb
LIBRARIAN_WATCH_CONFIG=~/.config/librarian/watched_repos.yaml
```

---

## Transport

**Streamable HTTP** — persistent server, not a Cline child process. Runs on `localhost:11436`. Any MCP-compatible client can connect.

---

## Storage

- **LanceDB** at `~/.local/share/librarian/lancedb/<repo_name>/`
- Always writing through to disk — RAM is just the working cache
- `.librarian/` directory created in each indexed repo root (symlink or marker file pointing to the LanceDB table name)
- `.librarian/` added to `.git/info/exclude` on first index

### LanceDB Schema

```python
{
  "repo":       str,
  "file_path":  str,
  "start_line": int,
  "end_line":   int,
  "language":   str,
  "content":    str,
  "vector":     list[float]   # 1024-dim, mxbai-embed-large
}
```

### Catalog Schema (separate LanceDB table: `_catalog`)

```python
{
  "repo":         str,
  "file_path":    str,
  "mtime":        float,   # last seen modification time
  "chunk_count":  int,
  "indexed_at":   float    # timestamp
}
```

---

## Module Specifications

### `embedder.py`

```python
class Embedder:
    def embed_initial(self, texts: list[str]) -> list[list[float]]
        # Uses GPU1 (port 11434), batch size 16

    def embed_delta(self, texts: list[str]) -> list[list[float]]
        # Uses GPU0 (port 11435), batch size 16

    def embed_query(self, text: str) -> list[float]
        # Uses GPU0 (port 11435), single call
```

- Batch size: 16 chunks per Ollama call
- Model: `mxbai-embed-large` on both ports
- On Ollama unreachable: raise `EmbedderError` with clear message

### `indexer.py`

```python
def index_repo(repo_path: str, embedder: Embedder, store: Store) -> IndexSummary:
    # 1. Walk files (respect .gitignore + extension allowlist)
    # 2. For each file: chunk into ~500 token segments (50 token overlap)
    # 3. Embed batch of 16 chunks via embedder.embed_initial()
    # 4. Write batch to LanceDB immediately (write-through, discard vectors)
    # 5. Update catalog entry for each file
    # 6. Return summary: files, chunks, time

def delta_index_file(file_path: str, repo_path: str, embedder: Embedder, store: Store):
    # 1. Delete existing chunks for this file from LanceDB
    # 2. Chunk the file
    # 3. Embed via embedder.embed_delta()
    # 4. Write to LanceDB
    # 5. Update catalog
```

**Chunking:**
- Target: 500 tokens (~2000 chars as proxy)
- Overlap: 50 tokens between chunks
- Split on: function/class boundaries where detectable, otherwise newlines

**File walking rules (in priority order):**
1. `.gitignore` in repo root (use `pathspec`)
2. Skip: `.git`, `node_modules`, `__pycache__`, `*.lock`, `*.min.js`, binary extensions, `.librarian`
3. Allowlist: `.py .js .ts .go .rs .yaml .yml .json .md .sh .toml .tf .nix .c .cpp .h`

### `store.py`

```python
class Store:
    def open(self, repo_path: str)         # open/create LanceDB table for repo
    def close(self, repo_path: str)        # close connection, release RAM
    def close_all()
    def upsert_chunks(self, chunks: list[dict])   # incremental append
    def delete_file_chunks(self, repo: str, file_path: str)
    def search(self, repo: str, query_vector: list[float], n: int) -> list[dict]
    def get_catalog(self, repo: str) -> list[dict]
    def upsert_catalog(self, entry: dict)
    def is_stale(self, repo: str) -> list[str]   # files modified since last index
```

### `watcher.py`

```python
class RepoWatcher:
    def watch(self, repo_path: str, callback)   # start watchdog on repo
    def unwatch(self, repo_path: str)
    def unwatch_all()
```

- Uses `watchdog` `Observer` with `PatternMatchingEventHandler`
- Respects same extension allowlist as indexer
- On file modified/created: calls `delta_index_file`
- On file deleted: calls `store.delete_file_chunks`
- Debounce: 2s delay before re-indexing (prevents thrashing on rapid saves)

### `repo_detector.py`

```python
class RepoDetector:
    def get_open_repos(self) -> list[str]
    # Scans VSCodium process args for workspace paths
    # Scans Aider process cwd via /proc/<pid>/cwd
    # Returns list of absolute repo paths that have .librarian/ present
```

- Runs on a 30s polling loop inside server
- New repo detected → `store.open()` + `watcher.watch()`
- Repo no longer open → `watcher.unwatch()` + `store.close()`
- Always-watch list loaded from `~/.config/librarian/watched_repos.yaml` (merged with detected)

### `server.py`

FastMCP server, HTTP transport, port 11436.

---

## MCP Tools

### `index_repo`
- **Input**: `repo_path` (string)
- **Behavior**: full initial index via GPU1, creates `.librarian/` marker, adds to `.git/info/exclude`
- **Returns**: summary — files indexed, chunks created, time taken
- **Note**: intentionally excluded from `alwaysAllow` — long-running, requires explicit approval

### `get_relevant_context`
- **Input**: `query` (string), `repo_path` (string), `n_results` (int, default 5)
- **Behavior**: embed query via GPU0, cosine search in LanceDB, return top N chunks
- **Returns**: formatted text block with file path, line range, content
- **Error if not indexed**: return message telling client to call `index_repo` first

### `list_indexed_repos`
- **Input**: none
- **Returns**: all indexed repos with file count, chunk count, last-indexed timestamp, watch status

### `get_index_status`
- **Input**: `repo_path` (string)
- **Returns**: indexed/not-indexed, file count, chunk count, stale file list if any

---

## Error Handling

- All tools return `{ content: [{ type: "text", text: "..." }], isError: true }` on failure
- Never raise uncaught exceptions
- Log with bracket tags: `[Setup]`, `[Embed]`, `[Index]`, `[Search]`, `[Watch]`, `[Detect]`, `[Error]`
- Ollama unreachable: return clear error, don't hang (timeout: 30s)
- Repo not indexed: return actionable message

---

## Systemd Service Unit

`/etc/systemd/system/librarian.service`:

```ini
[Unit]
Description=Librarian MCP Server
After=network.target ollama-gpu0.service ollama-gpu1.service
Wants=ollama-gpu0.service ollama-gpu1.service

[Service]
User=levine
Group=levine
WorkingDirectory=/home/levine/Documents/Repos/Workstation/library_and_patron
ExecStart=/home/levine/Documents/Repos/Workstation/library_and_patron/.venv/bin/python -m librarian.server
Restart=on-failure
RestartSec=5
Environment="ROCR_VISIBLE_DEVICES=0"
Environment="OLLAMA_GPU_INFER_URL=http://localhost:11434"
Environment="OLLAMA_GPU_EMBED_URL=http://localhost:11435"
Environment="LIBRARIAN_PORT=11436"
Environment="LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb"
Environment="LIBRARIAN_WATCH_CONFIG=/home/levine/.config/librarian/watched_repos.yaml"

[Install]
WantedBy=multi-user.target
```

---

## Cline MCP Settings Entry

`~/.config/VSCodium/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`:

```json
{
  "mcpServers": {
    "librarian": {
      "url": "http://localhost:11436/mcp",
      "alwaysAllow": ["get_relevant_context", "list_indexed_repos", "get_index_status"],
      "disabled": false
    }
  }
}
```

---

## Testing Checklist (required before completion)

- [ ] `index_repo` on `/home/levine/Documents/Repos/LevineLabsServer1` completes without error
- [ ] `.librarian/` created in repo root, added to `.git/info/exclude`
- [ ] `list_indexed_repos` shows correct file count, chunk count, timestamp
- [ ] `get_relevant_context("traefik routing", ...)` returns relevant `.yml` chunks
- [ ] `get_relevant_context` on unindexed repo returns actionable error message
- [ ] `get_index_status` detects stale index after modifying a file
- [ ] File watcher picks up a saved change and delta re-indexes within ~5s
- [ ] GPU0 (5700 XT) active during delta embed — verify via `rocm-smi` during file save
- [ ] GPU1 (7900 XTX) active during initial index — verify via `rocm-smi`
- [ ] GPU1 VRAM unaffected during delta operations
- [ ] Implicit repo detection picks up open VSCodium workspace
- [ ] Always-watch repo loaded on service start without explicit `index_repo`
- [ ] Service restart reloads index from disk without re-embedding
- [ ] RAM released when service stops (no LanceDB connections held)
