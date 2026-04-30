# Test Plan — library_and_patron

Structured verification of every component and data flow in the system.
Run sections in order — each section depends on the previous passing.

Test repo: `/home/levine/Documents/Repos/LevineLabsServer1`
Expected query: `"traefik routing"` → should return `.yaml` chunks from `traefik/`

---

## Prerequisites Before Any Testing

These must be true before starting:

```bash
# Ollama (GPU1) is running and has the embed model
ollama list | grep mxbai-embed-large

# The venv is intact
.venv/bin/python -c "from librarian.server import mcp; print('OK')"

# LevineLabsServer1 is a git repo
ls /home/levine/Documents/Repos/LevineLabsServer1/.git
```

Expected: all three return without error.

---

## Section 1 — Unit: Embedder

**Goal**: Verify the embedder correctly routes to each GPU's Ollama instance and returns valid vectors.

### 1A — GPU1 embed (initial path)

```bash
cd /home/levine/Documents/Repos/Workstation/library_and_patron

OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
.venv/bin/python - <<'EOF'
from librarian.embedder import embed_initial
vecs = embed_initial(["test chunk one", "test chunk two"])
assert len(vecs) == 2, f"Expected 2 vectors, got {len(vecs)}"
assert len(vecs[0]) == 1024, f"Expected 1024-dim, got {len(vecs[0])}"
print(f"PASS: GPU1 embed returned {len(vecs)} vectors of dim {len(vecs[0])}")
EOF
```

Expected: `PASS: GPU1 embed returned 2 vectors of dim 1024`

**Verify GPU**: While the above runs, in a second terminal:
```bash
watch -n1 'rocm-smi --showmeminfo vram | grep -A2 "GPU\[0\]\|GPU\[1\]"'
```
Expected: GPU1 (index 1, 7900 XTX) VRAM increases during embed. GPU0 VRAM unchanged.

### 1B — GPU0 embed (delta/query path)

> Requires ollama-gpu0 running on port 11435.
> Skip this test until Section 4 (ollama-gpu0 service install) is complete.
> Come back and run it after that section passes.

```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
.venv/bin/python - <<'EOF'
from librarian.embedder import embed_delta, embed_query
vec = embed_query("traefik routing configuration")
assert len(vec) == 1024
print(f"PASS: GPU0 query embed returned dim {len(vec)}")

vecs = embed_delta(["changed file chunk"])
assert len(vecs[0]) == 1024
print(f"PASS: GPU0 delta embed returned dim {len(vecs[0])}")
EOF
```

Expected: both PASS lines. GPU0 (5700 XT) VRAM increases, GPU1 unchanged.

### 1C — Embedder error handling

```bash
OLLAMA_GPU1_URL=http://localhost:19999 \
.venv/bin/python - <<'EOF'
from librarian.embedder import embed_initial, EmbedderError
try:
    embed_initial(["test"])
    print("FAIL: should have raised EmbedderError")
except EmbedderError as e:
    print(f"PASS: EmbedderError raised as expected: {e}")
EOF
```

Expected: `PASS: EmbedderError raised as expected: ...`

---

## Section 2 — Unit: Store

**Goal**: Verify LanceDB opens, writes, reads, and closes correctly. Confirm data is on disk after close.

```bash
.venv/bin/python - <<'EOF'
import numpy as np
import tempfile, os
from pathlib import Path

# Point DB to a temp location for this test
os.environ["LIBRARIAN_DB_BASE"] = "/tmp/librarian_test_db"

from librarian.store import Store

store = Store()
repo_path = "/tmp/fake_repo_for_test"
Path(repo_path).mkdir(exist_ok=True)
# Fake a .git dir so repo_key works
(Path(repo_path) / ".git").mkdir(exist_ok=True)

store.open(repo_path)
print("PASS: Store.open() succeeded")

# Write a chunk
fake_vector = list(np.random.rand(1024).astype(float))
store.upsert_chunks(repo_path, [{
    "repo":       "fake_repo_for_test",
    "file_path":  "test/file.py",
    "start_line": 1,
    "end_line":   10,
    "language":   "python",
    "content":    "def hello(): pass",
    "vector":     fake_vector,
}])
print("PASS: upsert_chunks() succeeded")

# Catalog entry
store.upsert_catalog(repo_path, {
    "repo":        "fake_repo_for_test",
    "file_path":   "test/file.py",
    "mtime":       1234567890.0,
    "chunk_count": 1,
})
print("PASS: upsert_catalog() succeeded")

# Search
results = store.search(repo_path, fake_vector, n=1)
assert len(results) == 1, f"Expected 1 result, got {len(results)}"
assert results[0]["file_path"] == "test/file.py"
print(f"PASS: search() returned correct result: {results[0]['file_path']}")

# Counts
assert store.get_chunk_count(repo_path) == 1
assert store.get_file_count(repo_path) == 1
print("PASS: chunk_count and file_count correct")

# Delete file chunks
store.delete_file_chunks(repo_path, "test/file.py")
assert store.get_chunk_count(repo_path) == 0
print("PASS: delete_file_chunks() removed chunks")

# Staleness check — file doesn't exist, so should be stale
store.upsert_catalog(repo_path, {
    "repo": "fake_repo_for_test",
    "file_path": "/nonexistent/file.py",
    "mtime": 999.0,
    "chunk_count": 0,
})
stale = store.is_stale(repo_path)
assert "/nonexistent/file.py" in stale
print(f"PASS: is_stale() detected missing file as stale")

# Close and verify data persists on disk
store.close(repo_path)
assert not store.is_open(repo_path)
print("PASS: store.close() released connection")

db_path = Path("/tmp/librarian_test_db/fake_repo_for_test")
assert db_path.exists(), f"LanceDB dir missing: {db_path}"
print(f"PASS: Data persisted on disk at {db_path}")

# Reopen and verify data is still there
store2 = Store()
store2.open(repo_path)
# Catalog should still have the nonexistent entry
cat = store2.get_catalog(repo_path)
assert len(cat) > 0
print("PASS: Data survived close/reopen cycle")
store2.close_all()

import shutil
shutil.rmtree("/tmp/librarian_test_db")
shutil.rmtree(repo_path)
print("\nAll Store tests passed.")
EOF
```

Expected: all PASS lines, no exceptions.

---

## Section 3 — Unit: Indexer

**Goal**: Verify file walking, chunking, and full indexing of LevineLabsServer1 using GPU1.

### 3A — File walking (dry run, no embedding)

```bash
.venv/bin/python - <<'EOF'
from pathlib import Path
from librarian.indexer import _walk_repo, _load_gitignore, _chunk_text

repo = Path("/home/levine/Documents/Repos/LevineLabsServer1")
spec = _load_gitignore(repo)
files = _walk_repo(repo, spec)

print(f"PASS: Found {len(files)} indexable files")

# Spot check — traefik yaml should be present
traefik_files = [f for f in files if "traefik" in str(f)]
assert traefik_files, "Expected traefik files in walk result"
print(f"PASS: Traefik files found: {[f.name for f in traefik_files]}")

# Verify .git is excluded
git_files = [f for f in files if ".git" in f.parts]
assert not git_files, f"FAIL: .git files leaked into walk: {git_files[:3]}"
print("PASS: .git directory correctly excluded")

# Chunking test
sample = repo / "traefik" / "traefik.yaml"
if sample.exists():
    text = sample.read_text()
    chunks = _chunk_text(text, "traefik/traefik.yaml")
    print(f"PASS: traefik.yaml chunked into {len(chunks)} chunks")
    for c in chunks:
        assert c["start_line"] > 0
        assert c["end_line"] >= c["start_line"]
        assert len(c["content"]) > 0
    print("PASS: All chunks have valid start_line, end_line, content")
EOF
```

Expected: PASS lines, file count > 0, traefik files found.

### 3B — Full index of LevineLabsServer1

> This uses GPU1 and takes ~1-5 minutes depending on repo size.
> Watch `rocm-smi` in a second terminal during this step.

```bash
# Terminal 2: watch GPU VRAM during indexing
watch -n2 'rocm-smi --showmeminfo vram'
```

```bash
# Terminal 1: run the index
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
import logging, time
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

from librarian.store import Store
from librarian.indexer import index_repo

store = Store()
start = time.time()
summary = index_repo("/home/levine/Documents/Repos/LevineLabsServer1", store)

print(f"\n=== Index Summary ===")
print(f"Files indexed:  {summary.files_indexed}")
print(f"Chunks created: {summary.chunks_created}")
print(f"Time taken:     {summary.elapsed_seconds:.1f}s")

assert summary.files_indexed > 0, "No files indexed!"
assert summary.chunks_created > 0, "No chunks created!"
print("PASS: index_repo() completed successfully")

# Verify .librarian marker
from pathlib import Path
marker = Path("/home/levine/Documents/Repos/LevineLabsServer1/.librarian")
assert marker.exists(), "FAIL: .librarian/ not created"
print("PASS: .librarian/ marker created")

# Verify .git/info/exclude
exclude = Path("/home/levine/Documents/Repos/LevineLabsServer1/.git/info/exclude")
content = exclude.read_text()
assert ".librarian" in content, "FAIL: .librarian not in .git/info/exclude"
print("PASS: .librarian added to .git/info/exclude")

# Verify DB on disk
from pathlib import Path
db_path = Path.home() / ".local/share/librarian/lancedb/LevineLabsServer1"
assert db_path.exists(), f"FAIL: LanceDB dir missing: {db_path}"
print(f"PASS: LanceDB data at {db_path}")

store.close_all()
EOF
```

Expected:
- Files indexed > 0, chunks > 0
- `.librarian/` exists in repo root
- `.git/info/exclude` contains `.librarian`
- LanceDB dir exists at `~/.local/share/librarian/lancedb/LevineLabsServer1/`
- GPU1 VRAM shows increased usage during run, returns to baseline after

---

## Section 4 — Integration: ollama-gpu0 Service

**Goal**: Install and verify the second Ollama instance before testing delta embeds and query embeds.

### 4A — Install the service

```bash
sudo cp /home/levine/Documents/Repos/Workstation/library_and_patron/systemd/ollama-gpu0.service \
    /etc/systemd/system/ollama-gpu0.service
sudo systemctl daemon-reload
```

### 4B — Start and verify

```bash
sudo systemctl start ollama-gpu0
sleep 3
systemctl status ollama-gpu0 | head -15
```

Expected: `active (running)`

```bash
# Verify it's listening on port 11435
curl -s http://localhost:11435/api/version | python3 -m json.tool
```

Expected: JSON with `"version": "..."` — confirms separate instance is reachable.

```bash
# Verify GPU assignment
# Watch rocm-smi while pulling the embed model to port 11435
watch -n2 'rocm-smi --showmeminfo vram'

OLLAMA_HOST=http://localhost:11435 ollama pull mxbai-embed-large
```

Expected: GPU0 (5700 XT, index 0) VRAM increases during pull/load.

### 4C — Now run Test 1B (GPU0 embed path)

Go back and run Section 1B now. It should pass.

---

## Section 5 — Integration: Search (end-to-end query)

**Goal**: Embed a query and retrieve relevant chunks from the indexed repo.

```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
import logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

from librarian.store import Store
from librarian.embedder import embed_query

store = Store()
store.open("/home/levine/Documents/Repos/LevineLabsServer1")

query = "traefik routing configuration"
print(f"Query: '{query}'")

vec = embed_query(query)
print(f"PASS: Query embedded, dim={len(vec)}")

results = store.search("/home/levine/Documents/Repos/LevineLabsServer1", vec, n=5)
assert results, "FAIL: No results returned"
print(f"PASS: {len(results)} results returned\n")

for i, r in enumerate(results, 1):
    print(f"[{i}] {r['file_path']} (lines {r['start_line']}–{r['end_line']}) [{r['language']}]")
    print(f"     {r['content'][:120].strip()}")
    print()

# Relevance check — at least one result should mention traefik
traefik_hits = [r for r in results if "traefik" in r["file_path"].lower() or "traefik" in r["content"].lower()]
assert traefik_hits, "FAIL: No traefik-related results in top 5"
print(f"PASS: {len(traefik_hits)}/5 results are traefik-related")
store.close_all()
EOF
```

Expected:
- Query embeds on GPU0
- At least 1 of top-5 results comes from `traefik/` files
- Content snippets are readable YAML/config, not garbage

---

## Section 6 — Integration: File Watcher (live delta)

**Goal**: Modify a file in the indexed repo and verify the watcher re-indexes it automatically.

### 6A — Start watcher manually

```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
import time, logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

from librarian.store import Store
from librarian.indexer import delta_index_file
from librarian.watcher import RepoWatcher

store = Store()
store.open("/home/levine/Documents/Repos/LevineLabsServer1")

def on_change(file_path, repo_path):
    print(f"\n>>> Watcher triggered: {file_path}")
    delta_index_file(file_path, repo_path, store)
    print(f">>> Delta index complete")

watcher = RepoWatcher(delta_callback=on_change)
watcher.watch("/home/levine/Documents/Repos/LevineLabsServer1")
print("Watching LevineLabsServer1... (modify a file within 30s)")

time.sleep(30)
watcher.stop()
store.close_all()
print("Done.")
EOF
```

### 6B — In a second terminal, touch a file

```bash
# While 6A is running, in a second terminal:
echo "# test comment" >> /home/levine/Documents/Repos/LevineLabsServer1/traefik/traefik.yaml
```

Expected in terminal 1 (within ~5s):
```
>>> Watcher triggered: .../traefik/traefik.yaml
>>> Delta index complete
```

### 6C — Verify stale detection caught it before the watcher fired

After Section 3B (initial index), before modifying the file, run:
```bash
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
from librarian.store import Store
store = Store()
store.open("/home/levine/Documents/Repos/LevineLabsServer1")
stale = store.is_stale("/home/levine/Documents/Repos/LevineLabsServer1")
print(f"Stale files before modification: {stale}")
assert stale == [], f"Expected no stale files, got: {stale}"
print("PASS: No stale files immediately after index")
store.close_all()
EOF
```

Then modify the file and re-run:
```bash
# After touching traefik.yaml (without watcher running):
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
from librarian.store import Store
store = Store()
store.open("/home/levine/Documents/Repos/LevineLabsServer1")
stale = store.is_stale("/home/levine/Documents/Repos/LevineLabsServer1")
print(f"Stale files after modification: {stale}")
assert any("traefik" in s for s in stale), "FAIL: traefik.yaml not detected as stale"
print("PASS: Modified file correctly detected as stale")
store.close_all()
EOF
```

Remember to revert the test change:
```bash
# Remove the test comment from traefik.yaml
sed -i '/# test comment/d' /home/levine/Documents/Repos/LevineLabsServer1/traefik/traefik.yaml
```

---

## Section 7 — Integration: Repo Detector

**Goal**: Verify implicit detection finds LevineLabsServer1 while VSCodium has it open.

### 7A — With VSCodium open on LevineLabsServer1

Open LevineLabsServer1 in VSCodium, then:

```bash
.venv/bin/python - <<'EOF'
from librarian.repo_detector import _get_codium_repos, _filter_indexed

repos = _get_codium_repos()
print(f"Detected repos from VSCodium: {repos}")

indexed = _filter_indexed(repos)
print(f"Of those, indexed (have .librarian/): {indexed}")

assert any("LevineLabsServer1" in r for r in indexed), \
    "FAIL: LevineLabsServer1 not detected. Is it open in VSCodium?"
print("PASS: LevineLabsServer1 detected via VSCodium process")
EOF
```

Expected: `LevineLabsServer1` appears in both lists.

### 7B — With VSCodium closed

Close VSCodium entirely, then re-run 7A. Expected: empty lists.

### 7C — Always-watch list

Add to `~/.config/librarian/watched_repos.yaml`:
```yaml
always_watch:
  - /home/levine/Documents/Repos/LevineLabsServer1
```

```bash
.venv/bin/python - <<'EOF'
from librarian.repo_detector import _load_always_watch, _filter_indexed

repos = _load_always_watch()
print(f"Always-watch list: {repos}")
assert any("LevineLabsServer1" in r for r in repos), "FAIL: Expected LevineLabsServer1 in always-watch"
print("PASS: Always-watch list loaded correctly")
EOF
```

---

## Section 8 — Integration: MCP Server (full tool test)

**Goal**: Start the Librarian server and call all four tools via the MCP HTTP endpoint.

### 8A — Start the server

```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
LIBRARIAN_PORT=11436 \
LIBRARIAN_WATCH_CONFIG=/home/levine/.config/librarian/watched_repos.yaml \
.venv/bin/python -m librarian.server &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"
sleep 3
```

### 8B — Confirm server is listening

```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | python3 -m json.tool
```

Expected: JSON response listing `index_repo_tool`, `get_relevant_context`, `list_indexed_repos`, `get_index_status`.

### 8C — list_indexed_repos

```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":2,
    "method":"tools/call",
    "params":{"name":"list_indexed_repos","arguments":{}}
  }' | python3 -m json.tool
```

Expected: output mentions `LevineLabsServer1` with file count, chunk count, last-indexed timestamp.

### 8D — get_index_status

```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":3,
    "method":"tools/call",
    "params":{"name":"get_index_status","arguments":{"repo_path":"/home/levine/Documents/Repos/LevineLabsServer1"}}
  }' | python3 -m json.tool
```

Expected: indexed=true, file count, chunk count, stale files=none (or list if any modified).

### 8E — get_relevant_context

```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":4,
    "method":"tools/call",
    "params":{"name":"get_relevant_context","arguments":{
      "query":"traefik routing configuration",
      "repo_path":"/home/levine/Documents/Repos/LevineLabsServer1",
      "n_results":3
    }}
  }' | python3 -m json.tool
```

Expected: formatted text with file paths, line ranges, YAML content. At least one result from `traefik/`.

### 8F — get_relevant_context on unindexed repo

```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":5,
    "method":"tools/call",
    "params":{"name":"get_relevant_context","arguments":{
      "query":"anything",
      "repo_path":"/home/levine/Documents/Repos/local-mcp-servers"
    }}
  }' | python3 -m json.tool
```

Expected: `isError: false` but text says "not indexed" and tells user to call `index_repo_tool`. Not a crash.

### 8G — Stop server

```bash
kill $SERVER_PID
```

---

## Section 9 — System: RAM Release on Service Stop

**Goal**: Confirm LanceDB RAM is released when the Librarian process stops.

```bash
# Get RAM baseline
free -h

# Start server and open a repo (run server as in 8A)
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python -m librarian.server &
SERVER_PID=$!
sleep 5

# Check RAM with server + repo loaded
free -h

# Stop the server
kill $SERVER_PID
sleep 3

# Check RAM after stop — should return toward baseline
free -h
```

Expected: RAM usage drops after server stops. (LanceDB uses memory-mapped files — OS may hold pages in page cache briefly, but process RSS should drop.)

---

## Section 10 — System: Session Manager

**Goal**: Verify services start and stop with AI apps.

> Requires: sudoers file installed, ollama-gpu0 and librarian services installed.
> Complete `./install.sh` before this section.

### 10A — Start session manager manually (foreground for visibility)

```bash
.venv/bin/python -m session_manager.manager
```

### 10B — Open a trigger app

Open VSCodium. Within a few seconds, in a second terminal:

```bash
systemctl status ollama-gpu0 | grep Active
systemctl status librarian | grep Active
```

Expected: both `active (running)`.

### 10C — Close all trigger apps

Close VSCodium. Wait 65 seconds (60s grace + 5s buffer). Then:

```bash
systemctl status ollama-gpu0 | grep Active
systemctl status librarian | grep Active
```

Expected: both `inactive (dead)`.

### 10D — Grace period cancellation

Open VSCodium → wait 10s → close VSCodium → immediately reopen within 30s.
Expected: services never stop (grace period cancelled by reopen).

### 10E — Service failure notification

Stop ollama-gpu0 service manually to simulate failure, then open VSCodium:
```bash
sudo systemctl mask ollama-gpu0   # make it unstarttable
```
Open VSCodium. Expected: `notify-send` popup appears with "Continue without" / "Retry" options.
```bash
sudo systemctl unmask ollama-gpu0  # restore
```

---

## Section 11 — Persistence: Index Survives Restart

**Goal**: Confirm that stopping and restarting the Librarian loads the existing index from disk without re-embedding.

```bash
# Start server, open repo, verify it's loaded
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python -m librarian.server &
SERVER_PID=$!
sleep 5

# Note the time
date

# Stop server
kill $SERVER_PID
sleep 2

# Restart server — should reload from disk, NOT re-embed
LIBRARIAN_DB_BASE=/home/levine/.local/share/librarian/lancedb \
.venv/bin/python -m librarian.server &
SERVER_PID2=$!
sleep 5

# Query should work immediately — no index_repo call needed
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"tools/call",
    "params":{"name":"get_index_status","arguments":{"repo_path":"/home/levine/Documents/Repos/LevineLabsServer1"}}
  }' | python3 -m json.tool

kill $SERVER_PID2
```

Expected: `get_index_status` returns correct counts immediately after restart. No embed calls made (GPU1 VRAM should NOT spike on restart — only on first `index_repo`).

---

## Test Results Tracker

| Section | Test | Status | Notes |
|---|---|---|---|
| 1A | GPU1 embed returns 1024-dim vectors | | |
| 1A | GPU1 VRAM increases during embed | | |
| 1B | GPU0 embed returns 1024-dim vectors | | After Section 4 |
| 1B | GPU0 VRAM increases, GPU1 unchanged | | After Section 4 |
| 1C | EmbedderError raised on bad URL | | |
| 2 | Store open/write/read/delete/close cycle | | |
| 2 | Data persists on disk after close | | |
| 2 | Data survives close/reopen cycle | | |
| 3A | File walk finds correct files | | |
| 3A | .git excluded from walk | | |
| 3A | Chunking produces valid chunks | | |
| 3B | Full index completes without error | | |
| 3B | .librarian/ marker created | | |
| 3B | .git/info/exclude updated | | |
| 3B | LanceDB dir created on disk | | |
| 3B | GPU1 VRAM spikes during index | | |
| 4A/B | ollama-gpu0 service installed and running | | |
| 4B | GPU0 serves mxbai-embed-large on port 11435 | | |
| 5 | Query returns traefik-related results | | |
| 5 | Query embed uses GPU0 | | |
| 6A/B | Watcher triggers delta re-index on file save | | |
| 6C | is_stale() detects modified file | | |
| 6C | is_stale() clean after fresh index | | |
| 7A | VSCodium repo detected implicitly | | |
| 7B | Detection clears when VSCodium closes | | |
| 7C | Always-watch list loads correctly | | |
| 8B | MCP server lists correct tools | | |
| 8C | list_indexed_repos returns correct data | | |
| 8D | get_index_status returns correct data | | |
| 8E | get_relevant_context returns traefik chunks | | |
| 8F | Unindexed repo returns useful error, not crash | | |
| 9 | RAM released after server stop | | |
| 10B | Services start when trigger app opens | | |
| 10C | Services stop after grace period | | |
| 10D | Grace period cancelled by reopen | | |
| 10E | notify-send failure notification fires | | |
| 11 | Index loads from disk on restart, no re-embed | | |
