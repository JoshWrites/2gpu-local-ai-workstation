#!/usr/bin/env python3
"""Librarian MCP server.

Exposes two tools:

- mine_file(path, query, top_k=5): chunk + embed a file, then return the
  top-K chunks most relevant to the query. Strategy chosen automatically
  from file extension. Results cached in DRAM keyed on (path, mtime);
  subsequent calls against the same file skip re-chunking and re-embedding.

- release_file(file_id): drop a cached entry to free DRAM.

Design: present the lowest-effort interface to the primary card. GLM just
passes a path and a question; the server handles strategy choice, chunking,
caching, retrieval, and ranking. GLM receives only what's relevant, with
minimal envelope bloat.

See docs/README.md in this repo for full design notes.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from .cache import CachedFile, FileCache, make_file_id
from .chunkers import chunk as chunk_file
from .embedder import EmbedderError, cosine_similarity, embed_batch, embed_one


# ── Logging ──────────────────────────────────────────────────────────────────

# stderr JSONL -- stdout is the MCP transport.
def _log(event: str, **fields) -> None:
    line = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event, **fields}
    print(json.dumps(line), file=sys.stderr, flush=True)


# ── Binary rejection ─────────────────────────────────────────────────────────

BINARY_SAMPLE_BYTES = 1024
BINARY_REJECT_RATIO = 0.30  # >30% non-printable -> binary, reject


def looks_binary(path: str) -> bool:
    """Heuristic: read first 1 KB and check non-printable ratio."""
    try:
        with open(path, "rb") as f:
            sample = f.read(BINARY_SAMPLE_BYTES)
    except OSError:
        return True  # can't read -> treat as binary / reject
    if not sample:
        return False  # empty is not binary
    # Printable = ASCII 0x20-0x7E, plus tab/newline/cr (0x09, 0x0A, 0x0D)
    printable = sum(1 for b in sample if 0x20 <= b <= 0x7E or b in (0x09, 0x0A, 0x0D))
    non_printable_ratio = 1.0 - (printable / len(sample))
    return non_printable_ratio > BINARY_REJECT_RATIO


# ── Cache (module-level singleton for this server process) ───────────────────

_cache = FileCache()


# ── Embedding helpers ────────────────────────────────────────────────────────

_EMBED_BATCH = 16  # matches distiller's tested batch size


def _embed_chunks(contents: list[str]) -> list[list[float]]:
    """Embed a list of chunk contents in batches of _EMBED_BATCH."""
    vectors: list[list[float]] = []
    for i in range(0, len(contents), _EMBED_BATCH):
        batch = contents[i : i + _EMBED_BATCH]
        vectors.extend(embed_batch(batch))
    return vectors


# ── MCP surface ──────────────────────────────────────────────────────────────

mcp = FastMCP("librarian")


@mcp.tool()
def mine_file(path: str, query: str, top_k: int = 5) -> dict:
    """Answer a question about a file's content by returning only the
    relevant chunks, not the whole file.

    PREFER THIS OVER `read` whenever the goal is to *understand something in a
    file* rather than *get the file verbatim*. Reading a whole file costs
    primary-context proportional to file size (a 1000-line doc is ~30 KB of
    tokens). This tool returns only the top-K chunks most relevant to your
    query, typically 1-5 KB of tokens regardless of file size.

    Typical uses:
    - "How does X work in this config?" -> mine_file(config_path, "how does X work")
    - "What does the plan say about Y?"  -> mine_file(plan_path, "policy on Y")
    - "Which section covers Z?"           -> mine_file(path, "Z")

    The file is chunked on first access using a strategy chosen automatically
    from the file extension (markdown-section chunking for .md/.txt/.rst,
    fixed-window chunking for source/config). Embeddings are cached in DRAM,
    so repeat calls on the same unchanged file skip the chunk+embed step.

    Use `read` instead when:
    - You need the whole file verbatim (copying, reproducing, editing).
    - The file is small (<100 lines) -- `read` is simpler for tiny files.
    - The librarian is unavailable (embed server down, tool errored).

    Args:
        path: Absolute or workspace-relative path to the target file.
        query: The question or topic to match chunks against. Pass the
            user's question verbatim if you don't have a sharper framing.
        top_k: How many chunks to return (default 5). Higher values use
            more primary-context; 3-5 is typical.

    Returns:
        {
          "file_id": str,           # stable id; pass to release_file when done
          "path": str,              # absolute path
          "strategy": "document"|"code",
          "chunk_count": int,       # total chunks in the file
          "from_cache": bool,       # true if served from cache
          "results": [
            {"chunk_id": int, "score": float,
             "byte_range": [int, int], "content": str,
             "metadata": {...}}    # section_path (docs) or line_range (code)
          ]
        }

    Errors raise and the tool call fails. Common failures:
    - File does not exist.
    - File looks binary (first 1 KB >30% non-printable). Binary support is
      planned but not in V1.
    - Embed server unreachable on :11437.
    """
    abs_path = os.path.abspath(path)
    if not os.path.exists(abs_path):
        raise FileNotFoundError(f"not found: {abs_path}")
    if not os.path.isfile(abs_path):
        raise ValueError(f"not a regular file: {abs_path}")
    if looks_binary(abs_path):
        raise ValueError(
            f"file looks binary ({abs_path}); v1 rejects binary input. "
            "TODO: binary parser/embedder support."
        )

    # Cache lookup by path (auto-miss if mtime changed)
    cached = _cache.lookup_by_path(abs_path)
    if cached is not None:
        _log("cache_hit", path=abs_path, file_id=cached.file_id)
        entry = cached
        from_cache = True
    else:
        from_cache = False
        mtime = os.path.getmtime(abs_path)
        file_id = make_file_id(abs_path, mtime)
        _log("mine_start", path=abs_path, file_id=file_id)

        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()

        strategy, chunks = chunk_file(abs_path, content)
        _log("chunked", path=abs_path, strategy=strategy, n_chunks=len(chunks))

        try:
            t0 = time.monotonic()
            embeddings = _embed_chunks([c.content for c in chunks])
            t1 = time.monotonic()
        except EmbedderError as e:
            _log("embed_error", path=abs_path, error=str(e))
            raise
        _log("embedded", path=abs_path, n_chunks=len(chunks), elapsed_sec=round(t1 - t0, 3))

        entry = CachedFile(
            file_id=file_id,
            path=abs_path,
            mtime=mtime,
            strategy=strategy,
            chunks=chunks,
            embeddings=embeddings,
        )
        _cache.put(entry)

    # Embed the query and rank chunks by cosine similarity
    query_vec = embed_one(query)
    scored: list[tuple[float, int]] = []  # (score, chunk_index)
    for i, chunk_vec in enumerate(entry.embeddings):
        scored.append((cosine_similarity(query_vec, chunk_vec), i))
    scored.sort(reverse=True)
    top = scored[: max(1, min(top_k, len(scored)))]

    results = []
    for score, idx in top:
        c = entry.chunks[idx]
        results.append(
            {
                "chunk_id": c.chunk_id,
                "score": round(score, 4),
                "byte_range": [c.byte_range[0], c.byte_range[1]],
                "content": c.content,
                "metadata": c.metadata,
            }
        )

    return {
        "file_id": entry.file_id,
        "path": entry.path,
        "strategy": entry.strategy,
        "chunk_count": len(entry.chunks),
        "from_cache": from_cache,
        "results": results,
    }


@mcp.tool()
def release_file(file_id: str) -> dict:
    """Release a cached file entry from DRAM.

    Call this when you're done with a file to free its chunks and embeddings.
    The cache is bounded (LRU eviction at capacity) so this isn't strictly
    required, but explicit release is cheaper than waiting for eviction.

    Args:
        file_id: The file_id returned by a prior mine_file call.

    Returns:
        {"status": "freed"|"not_cached", "file_id": str}
    """
    removed = _cache.release(file_id)
    _log("release", file_id=file_id, removed=removed)
    return {"status": "freed" if removed else "not_cached", "file_id": file_id}


# ── Entry point ──────────────────────────────────────────────────────────────


def main() -> None:
    _log("librarian_start", cache_max=_cache.stats()["max_entries"])
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
