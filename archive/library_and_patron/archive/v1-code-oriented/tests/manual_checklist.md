# Manual Test Checklist

Only tests that require human eyes, sudo, or physical hardware observation.
Everything else is covered by `auto_test.py`.

Run `auto_test.py` first. Come back here for what's left.

---

## Prerequisites

```bash
# From repo root
cd /home/levine/Documents/Repos/Workstation/library_and_patron

# Install system services and sudoers
sudo ./install.sh
```

After install.sh:
- [ ] `ollama-gpu0.service` installed (not enabled — session manager owns it)
- [ ] `librarian.service` installed (not enabled)
- [ ] `ai-session.service` enabled as user service
- [ ] `/etc/sudoers.d/ai-session` installed

---

## Check 1 — GPU routing during initial index

**Goal**: Confirm GPU1 (7900 XTX) handles initial embeddings, not GPU0.

Open two terminals.

**Terminal 2** — watch VRAM throughout:
```bash
watch -n2 'rocm-smi --showmeminfo vram'
```

**Terminal 1** — note baseline VRAM, then trigger index if not already done:
```bash
# Only needed if auto_test.py reported 3B as "Already indexed"
# In that case, skip this check — GPU routing already happened
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=~/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
from librarian.store import Store
from librarian.indexer import index_repo
import shutil
from pathlib import Path
# Clear existing index to force re-run
shutil.rmtree(Path.home() / ".local/share/librarian/lancedb/LevineLabsServer1", ignore_errors=True)
(Path("/home/levine/Documents/Repos/LevineLabsServer1/.librarian")).unlink(missing_ok=True)
import shutil; shutil.rmtree("/home/levine/Documents/Repos/LevineLabsServer1/.librarian", ignore_errors=True)
store = Store()
summary = index_repo("/home/levine/Documents/Repos/LevineLabsServer1", store)
print(f"Done: {summary.files_indexed} files, {summary.chunks_created} chunks")
EOF
```

**While indexing, observe Terminal 2:**
- [ ] GPU[1] (7900 XTX) VRAM increases during indexing
- [ ] GPU[0] (5700 XT) VRAM stays at baseline during indexing

---

## Check 2 — GPU0 service and delta/query routing

**Goal**: Confirm GPU0 handles query embeds and delta re-embeds.

### 2A — Start ollama-gpu0

```bash
sudo systemctl start ollama-gpu0
sleep 3
systemctl status ollama-gpu0 | grep Active
curl -s http://localhost:11435/api/version
```

- [ ] Status is `active (running)`
- [ ] curl returns JSON with a version string

### 2B — Confirm GPU0 responds to embeds

```bash
OLLAMA_GPU0_URL=http://localhost:11435 \
.venv/bin/python - <<'EOF'
import importlib, os
os.environ["OLLAMA_GPU0_URL"] = "http://localhost:11435"
from librarian import embedder
importlib.reload(embedder)
vec = embedder.embed_query("traefik routing")
print(f"dim={len(vec)}, nonzero={any(x!=0 for x in vec)}")
assert len(vec) == 1024
print("PASS")
EOF
```

**While this runs, observe `watch -n2 'rocm-smi --showmeminfo vram'`:**
- [ ] GPU[0] (5700 XT) VRAM increases during query embed
- [ ] GPU[1] (7900 XTX) VRAM unchanged

### 2C — Run 1B from auto_test (now that GPU0 is up)

```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=~/.local/share/librarian/lancedb \
.venv/bin/python tests/auto_test.py 2>&1 | grep -A1 "1B\|GPU0"
```

- [ ] No additional failures with GPU0 available

---

## Check 3 — File watcher live delta

**Goal**: Modify a file, confirm watcher picks it up and re-indexes using GPU0.

**Terminal 1** — start watcher:
```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=~/.local/share/librarian/lancedb \
.venv/bin/python - <<'EOF'
import time, logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
from librarian.store import Store
from librarian.indexer import delta_index_file
from librarian.watcher import RepoWatcher

store = Store()
store.open("/home/levine/Documents/Repos/LevineLabsServer1")

def on_change(file_path, repo_path):
    print(f"\n>>> TRIGGERED: {file_path}")
    delta_index_file(file_path, repo_path, store)
    print(f">>> DELTA COMPLETE")

watcher = RepoWatcher(delta_callback=on_change)
watcher.watch("/home/levine/Documents/Repos/LevineLabsServer1")
print("Watching... modify a file within 30s")
time.sleep(30)
watcher.stop()
store.close_all()
print("Done.")
EOF
```

**Terminal 2** — while Terminal 1 is watching, modify a file:
```bash
echo "# test" >> /home/levine/Documents/Repos/LevineLabsServer1/traefik/traefik.yaml
```

**Terminal 3** — watch VRAM:
```bash
watch -n2 'rocm-smi --showmeminfo vram'
```

- [ ] Terminal 1 prints `>>> TRIGGERED: .../traefik.yaml` within ~5s of the edit
- [ ] Terminal 1 prints `>>> DELTA COMPLETE`
- [ ] GPU[0] VRAM spikes briefly during delta (GPU1 unchanged)

**Revert the test edit:**
```bash
sed -i '/# test$/d' /home/levine/Documents/Repos/LevineLabsServer1/traefik/traefik.yaml
```

---

## Check 4 — VSCodium implicit repo detection

**Goal**: Confirm repo_detector finds LevineLabsServer1 when open in VSCodium.

### 4A — With VSCodium open on LevineLabsServer1

Open VSCodium and open the LevineLabsServer1 folder. Then:

```bash
.venv/bin/python - <<'EOF'
from librarian.repo_detector import _get_codium_repos, _filter_indexed
repos = _get_codium_repos()
indexed = _filter_indexed(repos)
print(f"Detected: {repos}")
print(f"Indexed:  {indexed}")
assert any("LevineLabsServer1" in r for r in indexed), "Not detected!"
print("PASS")
EOF
```

- [ ] `LevineLabsServer1` appears in detected list
- [ ] `LevineLabsServer1` appears in indexed list

### 4B — With VSCodium closed

Close VSCodium entirely. Run the same script.

- [ ] Lists are empty (or don't contain LevineLabsServer1)

---

## Check 5 — MCP server HTTP tools

**Goal**: Confirm all four MCP tools are reachable and return correct responses.

**Terminal 1** — start server:
```bash
OLLAMA_GPU1_URL=http://localhost:11434 \
OLLAMA_GPU0_URL=http://localhost:11435 \
LIBRARIAN_DB_BASE=~/.local/share/librarian/lancedb \
LIBRARIAN_PORT=11436 \
LIBRARIAN_WATCH_CONFIG=~/.config/librarian/watched_repos.yaml \
.venv/bin/python -m librarian.server
```

Wait for startup log line, then in **Terminal 2**:

### tools/list
```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | python3 -m json.tool
```
- [ ] Response lists: `index_repo_tool`, `get_relevant_context`, `list_indexed_repos`, `get_index_status`

### list_indexed_repos
```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_indexed_repos","arguments":{}}}' \
  | python3 -m json.tool
```
- [ ] Response mentions `LevineLabsServer1` with file count, chunk count, last-indexed date

### get_index_status
```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_index_status","arguments":{"repo_path":"/home/levine/Documents/Repos/LevineLabsServer1"}}}' \
  | python3 -m json.tool
```
- [ ] Shows indexed=true, correct counts, stale files=none

### get_relevant_context
```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_relevant_context","arguments":{"query":"traefik routing configuration","repo_path":"/home/levine/Documents/Repos/LevineLabsServer1","n_results":3}}}' \
  | python3 -m json.tool
```
- [ ] Returns 3 chunks with file paths, line ranges, YAML content
- [ ] At least 1 chunk is from `traefik/`

### get_relevant_context on unindexed repo
```bash
curl -s http://localhost:11436/mcp -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_relevant_context","arguments":{"query":"anything","repo_path":"/home/levine/Documents/Repos/local-mcp-servers"}}}' \
  | python3 -m json.tool
```
- [ ] Returns a message saying "not indexed" and tells user to call `index_repo_tool`
- [ ] No crash, no stack trace

**Stop the server:** `Ctrl+C` in Terminal 1.

---

## Check 6 — RAM released on server stop

**Goal**: Confirm LanceDB RAM is freed when server exits.

```bash
echo "=== Baseline ===" && free -h

LIBRARIAN_DB_BASE=~/.local/share/librarian/lancedb \
.venv/bin/python -m librarian.server &
SERVER_PID=$!
sleep 5

echo "=== With server running ===" && free -h

kill $SERVER_PID
sleep 3

echo "=== After server stop ===" && free -h
```

- [ ] RAM usage with server running is higher than baseline
- [ ] RAM usage after stop returns toward baseline
  (Note: OS page cache may keep some pages warm — look at `used` column, not `available`)

---

## Check 7 — Session Manager full lifecycle

**Goal**: Services start with AI apps, stop after grace period, notify on failure.

### 7A — Start session manager in foreground

```bash
.venv/bin/python -m session_manager.manager
```

### 7B — Open a trigger app

Open VSCodium. Within a few seconds:

```bash
systemctl status ollama-gpu0 | grep Active
systemctl status librarian | grep Active
```
- [ ] Both show `active (running)`
- [ ] Session manager terminal shows `=== AI session starting ===`

### 7C — Close all trigger apps, wait for grace period

Close VSCodium. Wait 65 seconds.

```bash
systemctl status ollama-gpu0 | grep Active
systemctl status librarian | grep Active
```
- [ ] Both show `inactive (dead)`
- [ ] Session manager terminal shows `=== AI session stopped ===`

### 7D — Grace period cancellation

Open VSCodium → wait 10s → close VSCodium → reopen within 20s.
- [ ] Session manager terminal shows grace period cancelled
- [ ] Services never stopped

### 7E — Service failure notification

```bash
sudo systemctl mask ollama-gpu0
```
Open VSCodium. Expected:
- [ ] `notify-send` desktop notification appears: "AI Session: ollama-gpu0 failed to start"
- [ ] Notification has "Continue without" and "Retry" buttons
- [ ] Clicking "Continue without" allows session to proceed (librarian still starts)

```bash
sudo systemctl unmask ollama-gpu0
```

---

## Results Summary

| Check | Description | Pass/Fail | Notes |
|---|---|---|---|
| 1 | GPU1 VRAM spikes during initial index | | |
| 1 | GPU0 VRAM unchanged during initial index | | |
| 2A | ollama-gpu0 service starts and responds | | |
| 2B | GPU0 VRAM spikes during query embed | | |
| 2B | GPU1 unchanged during query embed | | |
| 3 | Watcher triggers on file save within 5s | | |
| 3 | Delta embed uses GPU0 | | |
| 4A | VSCodium repo detected when open | | |
| 4B | Detection clears when VSCodium closed | | |
| 5 | All 4 MCP tools respond correctly | | |
| 5 | Unindexed repo returns useful error | | |
| 6 | RAM released after server stop | | |
| 7B | Services start when app opens | | |
| 7C | Services stop after grace period | | |
| 7D | Grace period cancelled by reopen | | |
| 7E | Failure notification fires with actions | | |
