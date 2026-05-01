# Librarian

Ad-hoc file retrieval MCP for local LLM agents. Hand it a path and a question; get back only the chunks that matter.

---

## What it does

When an agent needs to answer a question about a file, the naive path is `cat file.md` -> full content into primary context. Big files blow up context fast; much of the content wasn't relevant anyway.

Librarian inverts this: the agent calls `mine_file(path, query)`. The server:

1. Chooses a chunking strategy from the file's extension (document vs. code).
2. Chunks the file once, embeds every chunk via `mxbai-embed-large` on card 2.
3. Caches chunks + embeddings in DRAM keyed on `(path, mtime)`.
4. Embeds the query, ranks chunks by cosine similarity, returns the top-K.

The primary model only sees the relevant slices. No full-file dumps into context.

---

## Architecture (v2)

```
agent (opencode) ──MCP stdio──>  librarian/server.py  ───HTTP──> llama-embed (:11437)
                                         │                        mxbai-embed-large
                                         │                        5700 XT (Vulkan)
                                         v
                                   FileCache (DRAM)
                                   keyed on (path, mtime)
```

Two chunking strategies, chosen by extension:

| Strategy   | Used for                                  | Chunk shape                          |
|------------|-------------------------------------------|--------------------------------------|
| document   | `.md` `.txt` `.rst` `.org` etc.           | Split on markdown headers; section-path metadata |
| code       | `.py` `.js` `.go` `.rs` etc., any config  | Fixed 500-token windows + 50-token overlap; line-range metadata |

Unknown extensions default to `code` (safe generalist).

Binary files are rejected in v1 (>30% non-printable in first 1 KB). See [TODO](#todo).

---

## Tool surface (MCP)

### `mine_file(path, query, top_k=5)`

Returns the top-K chunks ranked by cosine similarity against `query`.

Response:
```json
{
  "file_id": "f_a1b2c3d4e5f6",
  "path": "/abs/path/to/file",
  "strategy": "document",
  "chunk_count": 42,
  "from_cache": false,
  "results": [
    {
      "chunk_id": 7,
      "score": 0.8234,
      "byte_range": [1543, 2091],
      "content": "...",
      "metadata": {"section_path": "Security > Honeypots", "heading": "Honeypots"}
    }
  ]
}
```

### `release_file(file_id)`

Drop a cached entry when done. DRAM discipline; not required (LRU evicts at cap) but explicit is cheaper.

---

## Design decisions

### Single tool, dispatch by extension (not two tools)
Keeps the caller interface minimal -- the agent passes `path` + `query`, the server picks the strategy. Lowest cognitive load on the primary, lowest token cost on the tool schema.

### Session-cache via `(path, mtime)`
Captures the common case (same file queried multiple times in one turn or session) without persistent storage overhead. Changing a file on disk is automatic cache-miss.

### No cross-session persistence (v1)
Cache is in-process DRAM, gone at server restart. For durable topical indexes (e.g., "full Proxmox docs, always searchable"), see the planned two-track architecture in `../second-opinion/`'s memory -- a separate `ingest_topic` tool is the right home, not `mine_file`.

### Rejected: binary files
v1 rejects files that look binary. A binary-parser layer (PDF, jupyter, docx) is TODO. When added, it runs *serialized* against the text embedder -- card 2 never hosts both simultaneously, so VRAM doesn't grow.

### Deferred: auto-retry with alternate strategy
Current dispatch is hardcoded: extension -> strategy. A future safety net could re-run with the other strategy if the first returned low scores, and serve whichever ranked better. The response envelope already includes `strategy` so the wrapper can stub onto this without refactor.

---

## Running

### Dependencies

- Python 3.10+
- `uv` (or `pip`) for dep install
- `mcp[cli]`
- A running `llama-embed.service` on `:11437` (mxbai-embed-large, Q8_0). See `~/.config/systemd/user/llama-embed.service` and `~/Documents/Repos/Workstation/docs/ports-registry.md`.

### Install

```bash
cd ~/Documents/Repos/Workstation/library_and_patron
uv sync  # or: pip install -e .
```

### Run standalone (manual test)

```bash
uv run python -m librarian.server
# stdio -- feed MCP JSON-RPC on stdin for testing
```

### Run via opencode

Add to `~/.config/opencode/opencode.json` under `mcp`:

```json
"librarian": {
  "type": "local",
  "command": [
    "/home/levine/.local/bin/uv",
    "run",
    "--project",
    "/home/levine/Documents/Repos/Workstation/library_and_patron",
    "python",
    "-m",
    "librarian.server"
  ],
  "enabled": true,
  "timeout": 60000
}
```

Opencode launches the server as a subprocess over stdio. The tools `mine_file` and `release_file` become available to the primary model.

---

## Testing

Minimal smoke tests in `tests/` exercise the chunker dispatch, cache behavior, and the MCP surface against a live embed server.

```bash
# Prereq: llama-embed.service running
uv run python tests/test_strategy_dispatch.py
uv run python tests/test_mine_file_e2e.py
```

---

## History

v1 (`archive/v1-code-oriented/`) was repo-wide code retrieval via LanceDB persistence, FastMCP on HTTP :11436, with GPU auto-detection and a session manager. It was tagged `v1-code-oriented` and preserved under `archive/` when this branch forked.

v2 (this branch, `v2-document-retrieval`) is document-first, file-scoped, session-cached. Most of v1's feature surface (persistent LanceDB, repo walking, systemd-orchestrated GPU swap, auto-detection of VSCodium/Aider repos) is deferred until real workflow evidence justifies it.

---

## TODO

- Binary parser + embedder (PDF, ipynb, docx). Runs serialized against the text embedder; VRAM stays flat.
- Auto-retry with alternate strategy when results score poorly.
- `ingest_topic` -- persistent topical indexes, separate tool, still scoped to card 2's mxbai endpoint.
- Optional top-K-as-pointers-only mode for very context-sensitive callers (two-step retrieve-then-expand).
- Test suite with representative fixtures (real markdown, real source files of multiple languages).
