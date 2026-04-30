# Librarian test plan

Validates that the Librarian's **auto-dispatch** behavior works for both code and documents, and that the interface presented to the primary card is the lowest-effort shape possible (single tool, path + query, no strategy hint required).

**Why this plan exists:** the design premise is that GLM should not burn tokens negotiating which retrieval strategy to use. It should pass a path and a question; the server does the right thing based on the file's extension. This plan proves that premise holds end-to-end.

---

## Objectives

1. **Auto-routing works.** `.md` files → document strategy. `.py` / `.yml` / etc. → code strategy. No caller hint needed.
2. **Relevance ranking is real.** Top-scored chunks actually contain content relevant to the query; scores separate relevant from irrelevant.
3. **Cache behavior is correct.** Same file + same mtime → cache hit. File modified → cache miss.
4. **Interface cost is minimal.** The tool schema presented to the primary is small; responses are small; no round-trips for strategy selection.
5. **Binary rejection is clean.** Binary files produce a clear error, not a silent meaningless result.

---

## Preconditions

Before running tests:

- `llama-embed.service` running on `127.0.0.1:11437`, serving `mxbai-embed-large`. Verify with:
  ```
  curl -fs http://127.0.0.1:11437/v1/models | head -c 200
  ```
- No changes to `librarian/server.py`, `chunkers.py`, `embedder.py`, `cache.py` between tests.
- Fresh subprocess per test run (no state leak across runs).

Stage 1 (card-2-only) and Stage 2 (both cards) of the stress test already passed as of 2026-04-22, validating that embedding concurrent with distiller is viable. This test plan builds on that foundation.

---

## Test matrix

### Tier A — offline, no network, no embed server

`tests/test_strategy_dispatch.py`

Runs the chunker dispatch logic in isolation. Does not require any llama services to be running.

Covers:
- `.md`, `.markdown`, `.txt`, `.rst`, `.org` route to `document`
- `.py`, `.js`, `.ts`, `.go`, `.rs`, `.yml`, `.toml`, `.json`, `.sh`, `.sql`, `.css` route to `code`
- Extensionless basenames (`Dockerfile`, `Makefile`, `Caddyfile`, `Jenkinsfile`) route to `code`
- Unknown extensions default to `code`
- Document chunker splits on markdown headers, tracks section path
- Code chunker produces line-range metadata
- Empty file returns zero chunks
- Headerless "document" content falls back cleanly to fixed windows

**Run:**
```
cd ~/Documents/Repos/Workstation/library_and_patron
uv run python tests/test_strategy_dispatch.py
```

**Expected:** `9/9 passed`, exit 0. Runs in <1 s.

### Tier B — end-to-end against live embed server

`tests/test_mine_file_e2e.py`

Exercises the full pipeline. Requires `llama-embed.service` running.

Covers:
- **Code file + code-shaped query** — writes a `.py` file with several functions, queries "how do I connect to a database?", asserts `strategy == "code"` and the `connect_to_database` function is in the top chunk.
- **Doc file + doc-shaped query** — writes an `.md` file with VLAN sections, queries "what VLAN is public-facing?", asserts `strategy == "document"` and the DMZ subsection is in the top chunk with a `section_path` that includes "VLAN".
- **Relevance discrimination** — top-K scores must separate: `scores[0] > scores[-1]`.
- **Cache hit on repeat** — second call on unchanged file returns `from_cache=true`, same `file_id`.
- **Cache miss after mtime change** — appending content and re-mining produces a new `file_id` and `from_cache=false`.
- **Release frees entry** — `release_file(file_id)` returns `freed`; second release returns `not_cached`.
- **Binary rejection** — feeding bytes(range(256)) raises `ValueError` mentioning "binary".
- **Missing file** — raises `FileNotFoundError`.

**Run:**
```
systemctl --user start llama-embed.service
until curl -fs --max-time 2 http://127.0.0.1:11437/v1/models >/dev/null; do sleep 1; done
cd ~/Documents/Repos/Workstation/library_and_patron
uv run python tests/test_mine_file_e2e.py
```

**Expected:** `8/8 passed`, exit 0. Total runtime ~5 s (most of it is the embed calls).

### Tier C — interface-cost assertions (manual, one-time)

These are not programmatic but should be spot-checked once after v1 ships:

- **Tool schema size.** The opencode log's `tool.registry` listing for a session with the Librarian enabled should show one more tool (`librarian_mine_file` plus maybe `librarian_release_file`). The JSON schema opencode sends to GLM per turn for that tool should be under ~500 tokens. Compared to the full tool schema of, say, `edit` (~1-2 KB), this is small.
- **Response payload size.** A `mine_file` call with `top_k=5` on a real doc (e.g., security-plan.md) should return a response under ~5 KB of JSON. The chunks themselves dominate; metadata and envelope should be a small fraction of total response size.
- **Primary-turn behavior.** After enabling the MCP and restarting opencode, a real session that asks GLM to answer a question about a long file should:
  - show exactly one `mine_file` tool call, not multiple chunked read calls
  - result in the primary context growing by `top_k * avg_chunk_size` (~2–4 KB), not by full-file size

### Tier D — coexistence with distiller under load

Already validated by the two-stage stress test (2026-04-22 results in `stress-test-stage2-both-cards.sh` output). Card 2 stayed under 5.5 GB peak during bulk ingest + distiller concurrent. Librarian uses the same embed endpoint, so by construction it shares the same resource envelope.

Re-run the stress test if:
- Embed model changes (e.g., mxbai → a different embedder)
- llama-embed's context or batch flags change
- A third service is added to card 2

---

## Acceptance criteria

- Tier A: **100% pass**. No flakes; pure-Python, deterministic.
- Tier B: **100% pass**. Flakes here indicate a real problem (embed server unstable, cache semantics wrong).
- Tier C: **manual spot-check succeeds** in at least one real opencode session before considering the Librarian "ready."
- Tier D: **stress test passes** when re-run after any of the listed change triggers.

If any Tier A or B test fails, the feature is not shipping.

---

## Known limitations of this test plan

- **No test for large files.** The fixtures are small (~2 KB). Behavior on multi-MB files (chunking time, embed batch throughput, cache memory pressure) is not exercised. Recommended follow-up: run `mine_file` against `LevineLabsServer1/docs/security-plan.md` (43 KB, 981 lines) as a real-world benchmark.
- **No test for retrieval quality across languages.** Only English fixtures. mxbai is multilingual; behavior on non-English text is untested.
- **No adversarial query test.** We don't test what happens when the query has nothing to do with the file. Expected behavior: top score is low, but the tool still returns something. Low-score thresholding is future work (safety-net extension).

---

## When to revise this plan

- Before enabling GLM-flagged persistent ingest (`ingest_topic` tool) — that's a new interface and needs its own tests.
- When a binary parser is added — test that binary dispatch routes to its own strategy, serialized with text embedder.
- When auto-retry-with-alternate-strategy is added — test that a low-score document chunker result triggers a retry with code chunker and the better of the two is served.
