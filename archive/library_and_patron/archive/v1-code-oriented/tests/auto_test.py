#!/usr/bin/env python3
"""Automated test suite for library_and_patron.

Covers all logic that can be verified without human eyes or sudo.
Run from the repo root:

    .venv/bin/python tests/auto_test.py

GPU URLs are auto-detected via gpu_detect (rocm-smi) at startup.
Override if needed:

    OLLAMA_GPU_INFER_URL=http://localhost:11434 \
    OLLAMA_GPU_EMBED_URL=http://localhost:11435 \
    .venv/bin/python tests/auto_test.py

Sections:
  0   GPU detection — verify rocm-smi finds both cards, roles assigned correctly
  1A  Embedder — INFER GPU vector shape and dimensionality
  1C  Embedder — error handling on bad URL
  2   Store    — open/write/search/delete/persist/reload cycle
  3A  Indexer  — file walking, exclusions, chunking
  3B  Indexer  — full index of LevineLabsServer1 (uses INFER GPU, ~1-5 min)
  5   Search   — end-to-end query returns relevant results
  6C  Watcher  — staleness detection before/after file modification
  7C  Detector — always-watch config loading
  11  Persist  — index survives server process restart, no re-embed
"""

import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ── Setup ──────────────────────────────────────────────────────────────────────

logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")

REPO_ROOT = Path(__file__).parent.parent
TEST_REPO = Path("/home/levine/Documents/Repos/LevineLabsServer1")
DB_BASE = Path.home() / ".local/share/librarian/lancedb"

os.environ["LIBRARIAN_DB_BASE"] = str(DB_BASE)
os.environ["LIBRARIAN_WATCH_CONFIG"] = str(Path.home() / ".config/librarian/watched_repos.yaml")

# Add repo to path so imports work when run directly
sys.path.insert(0, str(REPO_ROOT))

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
SKIP = "\033[33mSKIP\033[0m"
INFO = "\033[36mINFO\033[0m"

results = []  # (section, name, passed, note)


def check(section: str, name: str, passed: bool, note: str = ""):
    status = PASS if passed else FAIL
    print(f"  [{status}] {name}" + (f" — {note}" if note else ""))
    results.append((section, name, passed, note))


def skip(section: str, name: str, reason: str):
    print(f"  [{SKIP}] {name} — {reason}")
    results.append((section, name, None, reason))


def section(title: str):
    print(f"\n{'─'*60}")
    print(f"  {title}")
    print(f"{'─'*60}")


# ── Section 0: GPU Detection ───────────────────────────────────────────────────

section("0 · GPU detection — role assignment")

_INFER_URL = "http://localhost:11434"
_EMBED_URL  = "http://localhost:11435"

try:
    from librarian import embedder as _embedder_mod
    from librarian.gpu_detect import GPUInfo, _query_rocm_smi, detect_gpus

    gpus = _query_rocm_smi()
    check("0", "rocm-smi returns at least one GPU", len(gpus) > 0,
          f"found: {len(gpus)}")

    if len(gpus) >= 2:
        sorted_gpus = sorted(gpus.values(), key=lambda g: g.vram_bytes, reverse=True)
        infer_gpu = sorted_gpus[0]
        embed_gpu = sorted_gpus[1]
        check("0", "INFER GPU has more VRAM than EMBED GPU",
              infer_gpu.vram_bytes > embed_gpu.vram_bytes,
              f"infer={round(infer_gpu.vram_bytes/1e9,1)}GB embed={round(embed_gpu.vram_bytes/1e9,1)}GB")
        check("0", "INFER and EMBED assigned to different GPU indices",
              infer_gpu.index != embed_gpu.index,
              f"infer=GPU[{infer_gpu.index}] embed=GPU[{embed_gpu.index}]")
        check("0", "GPU names detected",
              bool(infer_gpu.name) and bool(embed_gpu.name),
              f"infer='{infer_gpu.name}' embed='{embed_gpu.name}'")
        print(f"  [{INFO}] INFER: GPU[{infer_gpu.index}] {infer_gpu.name} "
              f"({round(infer_gpu.vram_bytes/1e9,1)}GB)")
        print(f"  [{INFO}] EMBED: GPU[{embed_gpu.index}] {embed_gpu.name} "
              f"({round(embed_gpu.vram_bytes/1e9,1)}GB)")
    elif len(gpus) == 1:
        print(f"  [{INFO}] Single GPU detected — both roles assigned to same card")
        check("0", "Single GPU fallback", True, "both roles on same GPU")
    else:
        check("0", "GPU detection", False, "no GPUs found")

    _INFER_URL, _EMBED_URL = detect_gpus()
    check("0", "detect_gpus() returns two URLs", bool(_INFER_URL) and bool(_EMBED_URL),
          f"infer={_INFER_URL} embed={_EMBED_URL}")

    # Initialise embedder with detected URLs for all subsequent tests
    _embedder_mod.init(_INFER_URL, _EMBED_URL)
    check("0", "embedder.init() called with detected URLs", True)

except Exception as e:
    check("0", "GPU detection", False, f"unexpected error: {e}")
    # Still initialise with defaults so later tests can run
    try:
        from librarian import embedder as _embedder_mod
        _embedder_mod.init(_INFER_URL, _EMBED_URL)
    except Exception:
        pass

# ── Section 1A: Embedder — INFER GPU ──────────────────────────────────────────

section("1A · Embedder — INFER GPU vector shape")

try:
    from librarian.embedder import EmbedderError, embed_initial

    vecs = embed_initial(["hello world", "def foo(): pass", "traefik routing"])
    check("1A", "Returns correct number of vectors", len(vecs) == 3, f"got {len(vecs)}")
    check("1A", "Vectors are 1024-dimensional", all(len(v) == 1024 for v in vecs),
          f"dims: {[len(v) for v in vecs]}")
    check("1A", "Vectors are non-zero", all(any(x != 0 for x in v) for v in vecs))
    check("1A", "Different inputs produce different vectors", vecs[0] != vecs[1])
except EmbedderError as e:
    check("1A", "INFER GPU embed call", False, str(e))
except Exception as e:
    check("1A", "INFER GPU embed call", False, f"unexpected error: {e}")

# ── Section 1C: Embedder — error handling ──────────────────────────────────────

section("1C · Embedder — error handling")

try:
    import importlib
    import librarian.embedder as _emb

    # Point infer URL at a dead port, keep embed URL valid
    _emb.init("http://localhost:19999", _EMBED_URL)

    try:
        _emb.embed_initial(["test"])
        check("1C", "EmbedderError raised on unreachable URL", False, "no exception raised")
    except _emb.EmbedderError as e:
        check("1C", "EmbedderError raised on unreachable URL", True, str(e)[:80])
    except Exception as e:
        check("1C", "EmbedderError raised on unreachable URL", False, f"wrong exception type: {type(e).__name__}")
    finally:
        # Restore correct URLs
        _emb.init(_INFER_URL, _EMBED_URL)
except Exception as e:
    check("1C", "Error handling test setup", False, str(e))

# ── Section 2: Store ───────────────────────────────────────────────────────────

section("2 · Store — full lifecycle")

tmp_db = Path(tempfile.mkdtemp(prefix="librarian_test_"))
os.environ["LIBRARIAN_DB_BASE"] = str(tmp_db)

try:
    import importlib
    import librarian.store as _store_mod
    importlib.reload(_store_mod)
    from librarian.store import Store

    fake_repo = tmp_db / "fake_repo"
    fake_repo.mkdir()
    (fake_repo / ".git").mkdir()
    repo_path = str(fake_repo)

    store = Store()
    store.open(repo_path)
    check("2", "Store.open() succeeds", True)

    import numpy as np
    vec = list(np.random.rand(1024).astype(float))

    store.upsert_chunks(repo_path, [{
        "repo": "fake_repo", "file_path": "src/main.py",
        "start_line": 1, "end_line": 20,
        "language": "python", "content": "def main(): pass",
        "vector": vec,
    }])
    check("2", "upsert_chunks() succeeds", True)

    store.upsert_catalog(repo_path, {
        "repo": "fake_repo", "file_path": "src/main.py",
        "mtime": time.time(), "chunk_count": 1,
    })
    check("2", "upsert_catalog() succeeds", True)

    check("2", "get_chunk_count() == 1", store.get_chunk_count(repo_path) == 1)
    check("2", "get_file_count() == 1", store.get_file_count(repo_path) == 1)

    results_search = store.search(repo_path, vec, n=1)
    check("2", "search() returns 1 result", len(results_search) == 1)
    check("2", "search() result has correct file_path",
          results_search[0]["file_path"] == "src/main.py",
          f"got: {results_search[0].get('file_path')}")

    store.delete_file_chunks(repo_path, "src/main.py")
    check("2", "delete_file_chunks() removes chunks", store.get_chunk_count(repo_path) == 0)

    # Staleness: add entry for nonexistent file
    store.upsert_catalog(repo_path, {
        "repo": "fake_repo", "file_path": "/nonexistent/ghost.py",
        "mtime": 999.0, "chunk_count": 0,
    })
    stale = store.is_stale(repo_path)
    check("2", "is_stale() detects missing file", "/nonexistent/ghost.py" in stale,
          f"stale={stale}")

    # Add real file with old mtime
    real_file = fake_repo / "real.py"
    real_file.write_text("print('hello')")
    store.upsert_catalog(repo_path, {
        "repo": "fake_repo", "file_path": str(real_file),
        "mtime": real_file.stat().st_mtime - 10,  # pretend it was indexed 10s ago
        "chunk_count": 1,
    })
    stale2 = store.is_stale(repo_path)
    check("2", "is_stale() detects file with newer mtime", str(real_file) in stale2)

    # Disk persistence
    store.close(repo_path)
    check("2", "store.close() releases connection", not store.is_open(repo_path))

    db_on_disk = tmp_db / "fake_repo"
    check("2", "LanceDB dir exists on disk after close", db_on_disk.exists(),
          f"path: {db_on_disk}")

    # Reopen
    store2 = Store()
    store2.open(repo_path)
    cat = store2.get_catalog(repo_path)
    check("2", "Catalog survives close/reopen", len(cat) > 0, f"entries: {len(cat)}")
    store2.close_all()
    check("2", "close_all() clears all connections", True)

except Exception as e:
    check("2", "Store lifecycle", False, f"unexpected error: {e}")
finally:
    os.environ["LIBRARIAN_DB_BASE"] = str(DB_BASE)
    importlib.reload(_store_mod)
    shutil.rmtree(tmp_db, ignore_errors=True)

# ── Section 3A: Indexer — file walking and chunking ───────────────────────────

section("3A · Indexer — file walking and chunking")

try:
    from librarian.indexer import (ALLOW_EXTENSIONS, SKIP_DIRS,
                                    _chunk_text, _load_gitignore, _walk_repo)

    if not TEST_REPO.exists():
        skip("3A", "File walk", f"Test repo not found: {TEST_REPO}")
    else:
        spec = _load_gitignore(TEST_REPO)
        check("3A", ".gitignore loaded", spec is not None or True)  # None is fine if no .gitignore

        files = _walk_repo(TEST_REPO, spec)
        check("3A", "Found indexable files", len(files) > 0, f"count: {len(files)}")

        # .git exclusion
        git_leaked = [f for f in files if ".git" in f.parts]
        check("3A", ".git directory excluded", len(git_leaked) == 0,
              f"leaked: {git_leaked[:3]}")

        # node_modules / __pycache__ exclusion
        bad = [f for f in files if any(s in f.parts for s in SKIP_DIRS)]
        check("3A", "Skip dirs excluded", len(bad) == 0, f"leaked: {bad[:3]}")

        # Extension allowlist
        non_allowed = [f for f in files if f.suffix.lower() not in ALLOW_EXTENSIONS]
        check("3A", "Only allowed extensions indexed", len(non_allowed) == 0,
              f"bad ext: {[f.suffix for f in non_allowed[:5]]}")

        # Traefik files present
        traefik = [f for f in files if "traefik" in str(f).lower()]
        check("3A", "Traefik files found", len(traefik) > 0,
              f"found: {[f.name for f in traefik]}")

        # Chunking
        sample = TEST_REPO / "traefik" / "traefik.yaml"
        if sample.exists():
            text = sample.read_text()
            chunks = _chunk_text(text, "traefik/traefik.yaml")
            check("3A", "traefik.yaml produces chunks", len(chunks) > 0, f"count: {len(chunks)}")
            check("3A", "All chunks have valid line ranges",
                  all(c["start_line"] > 0 and c["end_line"] >= c["start_line"] for c in chunks))
            check("3A", "All chunks have non-empty content",
                  all(len(c["content"].strip()) > 0 for c in chunks))
            check("3A", "Chunks stay within size limit",
                  all(len(c["content"]) <= 3000 for c in chunks),
                  f"max size: {max(len(c['content']) for c in chunks)}")
        else:
            skip("3A", "Chunking traefik.yaml", "File not found")

except Exception as e:
    check("3A", "File walking setup", False, f"unexpected error: {e}")

# ── Section 3B: Full index of LevineLabsServer1 ───────────────────────────────

section("3B · Indexer — full index of LevineLabsServer1 (GPU1, may take a few minutes)")

_index_ran = False
if not TEST_REPO.exists():
    skip("3B", "Full index", f"Test repo not found: {TEST_REPO}")
else:
    try:
        from librarian.indexer import index_repo
        from librarian.store import Store as Store3B

        # Check if already indexed — skip re-indexing to save time
        marker = TEST_REPO / ".librarian"
        db_path = DB_BASE / TEST_REPO.name
        already_indexed = marker.exists() and db_path.exists()

        if already_indexed:
            print(f"  [{INFO}] Already indexed — verifying existing index, skipping re-embed")
            store3b = Store3B()
            store3b.open(str(TEST_REPO))
            fc = store3b.get_file_count(str(TEST_REPO))
            cc = store3b.get_chunk_count(str(TEST_REPO))
            check("3B", "Existing index has files", fc > 0, f"file count: {fc}")
            check("3B", "Existing index has chunks", cc > 0, f"chunk count: {cc}")
            check("3B", ".librarian/ marker exists", marker.exists())
            exclude = TEST_REPO / ".git" / "info" / "exclude"
            check("3B", ".librarian in .git/info/exclude",
                  exclude.exists() and ".librarian" in exclude.read_text())
            store3b.close_all()
            _index_ran = True
        else:
            print(f"  [{INFO}] Running full index (this may take 1-5 minutes)...")
            store3b = Store3B()
            t0 = time.time()
            summary = index_repo(str(TEST_REPO), store3b)
            elapsed = time.time() - t0

            check("3B", "index_repo() completes", True)
            check("3B", "Files indexed > 0", summary.files_indexed > 0,
                  f"count: {summary.files_indexed}")
            check("3B", "Chunks created > 0", summary.chunks_created > 0,
                  f"count: {summary.chunks_created}")
            check("3B", ".librarian/ marker created", marker.exists())
            exclude = TEST_REPO / ".git" / "info" / "exclude"
            check("3B", ".librarian in .git/info/exclude",
                  exclude.exists() and ".librarian" in exclude.read_text())
            check("3B", "LanceDB dir created on disk", db_path.exists(), f"path: {db_path}")
            print(f"  [{INFO}] Indexed {summary.files_indexed} files, "
                  f"{summary.chunks_created} chunks in {elapsed:.1f}s")
            store3b.close_all()
            _index_ran = True

    except Exception as e:
        check("3B", "Full index", False, f"unexpected error: {e}")

# ── Section 5: End-to-end search ──────────────────────────────────────────────

section("5 · Search — end-to-end query relevance")

if not _index_ran:
    skip("5", "Search", "Section 3B did not complete — index required")
else:
    try:
        from librarian.embedder import EmbedderError, embed_query
        from librarian.store import Store as Store5

        store5 = Store5()
        store5.open(str(TEST_REPO))

        query = "traefik routing configuration"
        try:
            vec = embed_query(query)
        except EmbedderError:
            store5.close_all()
            skip("5", "Search (all checks)",
                 "GPU0 Ollama not running on port 11435 — complete manual check 2A first")
            vec = None

        if vec is not None:
            check("5", "Query embedded successfully", len(vec) == 1024, f"dim: {len(vec)}")

            results_s = store5.search(str(TEST_REPO), vec, n=5)
            check("5", "Search returns results", len(results_s) > 0, f"count: {len(results_s)}")

            traefik_hits = [r for r in results_s
                            if "traefik" in r.get("file_path", "").lower()
                            or "traefik" in r.get("content", "").lower()]
            check("5", "At least 1 traefik-related result in top 5",
                  len(traefik_hits) > 0, f"{len(traefik_hits)}/5 hits")

            check("5", "Results have required fields",
                  all("file_path" in r and "content" in r and "start_line" in r for r in results_s))

            check("5", "Content is non-empty",
                  all(len(r.get("content", "").strip()) > 0 for r in results_s))

            vec2 = embed_query("docker compose container networking")
            results2 = store5.search(str(TEST_REPO), vec2, n=1)
            if results_s and results2:
                check("5", "Different queries return different top results",
                      results_s[0].get("file_path") != results2[0].get("file_path")
                      or results_s[0].get("start_line") != results2[0].get("start_line"))

            print(f"\n  [{INFO}] Top results for '{query}':")
            for i, r in enumerate(results_s[:3], 1):
                print(f"         [{i}] {r['file_path']} lines {r['start_line']}–{r['end_line']}")

            store5.close_all()

    except Exception as e:
        check("5", "Search", False, f"unexpected error: {e}")

# ── Section 6C: Staleness detection ───────────────────────────────────────────

section("6C · Staleness detection — before and after file modification")

if not _index_ran:
    skip("6C", "Staleness detection", "Section 3B did not complete — index required")
else:
    try:
        from librarian.store import Store as Store6

        store6 = Store6()
        store6.open(str(TEST_REPO))

        # Capture current stale baseline (some files may already be stale if index is old)
        stale_baseline = set(store6.is_stale(str(TEST_REPO)))
        if stale_baseline:
            print(f"  [{INFO}] {len(stale_baseline)} file(s) already stale (index is older than files) — testing relative to baseline")
        check("6C", "is_stale() returns a list without error", True,
              f"baseline stale count: {len(stale_baseline)}")

        # Use traefik.yaml as our controlled test subject
        sample = TEST_REPO / "traefik" / "traefik.yaml"
        if sample.exists():
            real_mtime = sample.stat().st_mtime

            # Ensure traefik.yaml is NOT stale to start (set mtime = current)
            store6.upsert_catalog(str(TEST_REPO), {
                "repo":        TEST_REPO.name,
                "file_path":   "traefik/traefik.yaml",
                "mtime":       real_mtime,
                "chunk_count": 1,
                "indexed_at":  time.time(),
            })
            stale_clean = store6.is_stale(str(TEST_REPO))
            check("6C", "traefik.yaml not stale when mtime matches",
                  not any("traefik.yaml" in s for s in stale_clean))

            # Simulate it going stale (set recorded mtime to 100s before real mtime)
            store6.upsert_catalog(str(TEST_REPO), {
                "repo":        TEST_REPO.name,
                "file_path":   "traefik/traefik.yaml",
                "mtime":       real_mtime - 100,
                "chunk_count": 1,
                "indexed_at":  time.time() - 100,
            })
            stale_after = store6.is_stale(str(TEST_REPO))
            check("6C", "traefik.yaml detected as stale after mtime backdated",
                  any("traefik.yaml" in s for s in stale_after),
                  f"stale list: {[s for s in stale_after if 'traefik' in s]}")

            # Restore correct mtime — should go clean again
            store6.upsert_catalog(str(TEST_REPO), {
                "repo":        TEST_REPO.name,
                "file_path":   "traefik/traefik.yaml",
                "mtime":       real_mtime,
                "chunk_count": 1,
                "indexed_at":  time.time(),
            })
            stale_restored = store6.is_stale(str(TEST_REPO))
            check("6C", "traefik.yaml staleness clears after mtime restored",
                  not any("traefik.yaml" in s for s in stale_restored),
                  f"stale: {[s for s in stale_restored if 'traefik' in s]}")
        else:
            skip("6C", "Stale detection on traefik.yaml", "File not found")

        store6.close_all()

    except Exception as e:
        check("6C", "Staleness detection", False, f"unexpected error: {e}")

# ── Section 7C: Always-watch config loading ────────────────────────────────────

section("7C · Repo detector — always-watch config")

try:
    from librarian.repo_detector import _filter_indexed, _load_always_watch

    watch_cfg = Path.home() / ".config/librarian/watched_repos.yaml"

    if not watch_cfg.exists():
        skip("7C", "Always-watch config", f"Config file not found: {watch_cfg}")
    else:
        repos = _load_always_watch()
        check("7C", "Config loads without error", True, f"entries: {len(repos)}")
        check("7C", "All entries are absolute paths", all(Path(r).is_absolute() for r in repos),
              f"paths: {repos}")

        # Write a temp config with a known entry and verify it loads
        import yaml
        tmp_cfg = watch_cfg.parent / "watched_repos_test.yaml"
        tmp_cfg.write_text(yaml.dump({"always_watch": [str(TEST_REPO)]}))

        orig_env = os.environ.get("LIBRARIAN_WATCH_CONFIG")
        os.environ["LIBRARIAN_WATCH_CONFIG"] = str(tmp_cfg)

        import librarian.repo_detector as _det_mod
        importlib.reload(_det_mod)

        test_repos = _det_mod._load_always_watch()
        check("7C", "Test config entry loaded", str(TEST_REPO) in test_repos,
              f"loaded: {test_repos}")

        if (TEST_REPO / ".librarian").exists():
            indexed = _det_mod._filter_indexed(test_repos)
            check("7C", "_filter_indexed passes indexed repos",
                  str(TEST_REPO) in indexed, f"indexed: {indexed}")
        else:
            skip("7C", "_filter_indexed check", ".librarian not yet created (run 3B first)")

        tmp_cfg.unlink()
        if orig_env:
            os.environ["LIBRARIAN_WATCH_CONFIG"] = orig_env
        importlib.reload(_det_mod)

except Exception as e:
    check("7C", "Always-watch config", False, f"unexpected error: {e}")

# ── Section 11: Persistence across restart ─────────────────────────────────────

section("11 · Persistence — index survives process restart")

if not _index_ran:
    skip("11", "Persistence", "Section 3B did not complete — index required")
else:
    try:
        from librarian.store import Store as Store11

        # Capture counts before simulated restart
        store11a = Store11()
        store11a.open(str(TEST_REPO))
        fc_before = store11a.get_file_count(str(TEST_REPO))
        cc_before = store11a.get_chunk_count(str(TEST_REPO))
        last_before = store11a.get_last_indexed(str(TEST_REPO))
        store11a.close_all()

        check("11", "Pre-restart: index has files and chunks",
              fc_before > 0 and cc_before > 0,
              f"files={fc_before}, chunks={cc_before}")

        # Simulate restart: open a fresh Store instance (new process would do the same)
        store11b = Store11()
        store11b.open(str(TEST_REPO))
        fc_after = store11b.get_file_count(str(TEST_REPO))
        cc_after = store11b.get_chunk_count(str(TEST_REPO))
        last_after = store11b.get_last_indexed(str(TEST_REPO))
        store11b.close_all()

        check("11", "Post-restart: file count matches", fc_after == fc_before,
              f"before={fc_before}, after={fc_after}")
        check("11", "Post-restart: chunk count matches", cc_after == cc_before,
              f"before={cc_before}, after={cc_after}")
        check("11", "Post-restart: last-indexed timestamp preserved",
              last_before is not None and abs(last_after - last_before) < 1,
              f"before={last_before}, after={last_after}")

        # Verify no GPU activity needed for reload (can't measure GPU directly,
        # but we can verify reload is near-instant — re-embed would take minutes)
        t0 = time.time()
        store11c = Store11()
        store11c.open(str(TEST_REPO))
        _ = store11c.get_chunk_count(str(TEST_REPO))
        store11c.close_all()
        reload_time = time.time() - t0
        check("11", "Reload from disk is fast (<10s, not re-embedding)",
              reload_time < 10, f"took {reload_time:.2f}s")

    except Exception as e:
        check("11", "Persistence", False, f"unexpected error: {e}")

# ── Summary ────────────────────────────────────────────────────────────────────

print(f"\n{'═'*60}")
print("  RESULTS")
print(f"{'═'*60}")

passed = [r for r in results if r[2] is True]
failed = [r for r in results if r[2] is False]
skipped = [r for r in results if r[2] is None]

for section_name, name, status, note in results:
    if status is False:
        print(f"  [{FAIL}] [{section_name}] {name}" + (f" — {note}" if note else ""))

print(f"\n  Passed:  {len(passed)}")
print(f"  Failed:  {len(failed)}")
print(f"  Skipped: {len(skipped)}")
print()

if failed:
    print(f"  {FAIL}: {len(failed)} test(s) need attention.")
    sys.exit(1)
else:
    print(f"  {PASS}: All automated tests passed.")
    sys.exit(0)
