"""End-to-end test: exercise mine_file against the live embed server on :11437.

Tests the full pipeline:
  - code file -> code chunker + mxbai embed + cosine-similarity retrieval
  - doc  file -> document chunker + mxbai embed + cosine-similarity retrieval
  - strategy auto-switches per file type (no manual hint from caller)
  - relevant chunk beats irrelevant chunk on score
  - repeat calls hit cache (no re-embed)

Prereq: llama-embed.service running on :11437.

This is the test you'd run to validate that the lowest-effort primary-card
interface (single tool, path+query only) actually does what the agent needs.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

# Reset the shared cache between tests so one test's cache doesn't skew another.
from librarian import cache as _cache_mod
from librarian import server as _server_mod


def _fresh_cache():
    """Replace the module-level cache so each test starts fresh."""
    _server_mod._cache = _cache_mod.FileCache()


# ── Preflight: make sure the embed server is up ──────────────────────────────


def _embed_server_up() -> bool:
    try:
        urllib.request.urlopen("http://127.0.0.1:11437/v1/models", timeout=2)
        return True
    except Exception:
        return False


# ── Test fixtures ────────────────────────────────────────────────────────────

CODE_CONTENT = '''#!/usr/bin/env python3
"""A math and infrastructure utilities module.

This file is intentionally large enough to produce multiple chunks under the
500-token fixed-window chunker, so retrieval-ranking tests have headroom.
"""

import json
import logging
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


logger = logging.getLogger(__name__)


def add(a, b):
    """Return the sum of two numbers."""
    return a + b


def subtract(a, b):
    """Return the difference of two numbers."""
    return a - b


def multiply(a, b):
    """Return the product of two numbers."""
    return a * b


def divide(a, b):
    """Return the quotient of two numbers. Raises on divide-by-zero."""
    if b == 0:
        raise ValueError("divide by zero")
    return a / b


def fibonacci(n):
    """Generate the nth Fibonacci number iteratively."""
    if n <= 1:
        return n
    prev, curr = 0, 1
    for _ in range(n - 1):
        prev, curr = curr, prev + curr
    return curr


def is_prime(n):
    """Return True if n is a prime number."""
    if n < 2:
        return False
    if n == 2:
        return True
    if n % 2 == 0:
        return False
    for i in range(3, int(n ** 0.5) + 1, 2):
        if n % i == 0:
            return False
    return True


def prime_sieve(limit):
    """Sieve of Eratosthenes up to limit."""
    sieve = [True] * (limit + 1)
    sieve[0] = sieve[1] = False
    for i in range(2, int(limit ** 0.5) + 1):
        if sieve[i]:
            for j in range(i * i, limit + 1, i):
                sieve[j] = False
    return [i for i, p in enumerate(sieve) if p]


def parse_yaml_config(path):
    """Load a YAML config file and return the parsed dict."""
    import yaml
    with open(path) as f:
        return yaml.safe_load(f)


def parse_json_config(path):
    """Load a JSON config file and return the parsed dict."""
    with open(path) as f:
        return json.load(f)


def connect_to_database(conn_string):
    """Open a database connection from a connection string."""
    import sqlalchemy
    return sqlalchemy.create_engine(conn_string)


def execute_sql_query(engine, query, params=None):
    """Run a parameterized SQL query against an engine."""
    with engine.connect() as conn:
        return conn.execute(query, params or {}).fetchall()


@dataclass
class HttpResponse:
    """Simple container for HTTP response details."""
    status_code: int
    headers: dict
    body: bytes


def fetch_url(url, timeout=10):
    """Fetch a URL and return an HttpResponse. Blocks up to `timeout` seconds."""
    import urllib.request
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return HttpResponse(
            status_code=resp.status,
            headers=dict(resp.headers),
            body=resp.read(),
        )


def ensure_dir(path):
    """Create a directory and all parents, idempotently."""
    Path(path).mkdir(parents=True, exist_ok=True)


def get_env_or_default(name, default):
    """Look up an env var, returning `default` if unset."""
    value = os.environ.get(name)
    return value if value is not None else default
'''

DOC_CONTENT = """# Homelab Network Architecture

## Physical Layout

The homelab sits behind a single WireGuard VPN endpoint. All management
traffic traverses the VPN.

## VLAN Segmentation

We segment traffic into three VLANs:

### Management VLAN

Proxmox UI, SSH, monitoring. Reachable only over VPN.

### DMZ VLAN

Public-facing services: web, reverse proxy. NAT-exposed on selected ports.

### Trust VLAN

Internal services: NAS, git, matrix. LAN-only.

## Firewall Policy

Default deny. Explicit allow per destination port. Logs ship to the
monitoring CT.

## DNS Strategy

Split-horizon DNS via Pi-hole. Internal clients resolve .home to private IPs;
external clients see the public records.
"""


def _write_tmp(suffix: str, content: str) -> str:
    """Write content to a tempfile with the given suffix and return its path."""
    fd, path = tempfile.mkstemp(suffix=suffix)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    return path


# ── Tests ────────────────────────────────────────────────────────────────────


def test_code_file_auto_routes_to_code_strategy_and_returns_relevant_chunk():
    path = _write_tmp(".py", CODE_CONTENT)
    try:
        _fresh_cache()
        result = _server_mod.mine_file(path, "how do I connect to a database?", top_k=3)
        assert result["strategy"] == "code", f"expected 'code', got {result['strategy']}"
        assert result["chunk_count"] >= 1
        assert result["from_cache"] is False

        top = result["results"][0]
        assert "connect_to_database" in top["content"] or "sqlalchemy" in top["content"], (
            f"top chunk should mention database; got: {top['content'][:200]}"
        )
        # line_range metadata should be present for code
        assert "line_range" in top["metadata"]
    finally:
        os.unlink(path)


def test_doc_file_auto_routes_to_document_strategy_and_returns_relevant_section():
    path = _write_tmp(".md", DOC_CONTENT)
    try:
        _fresh_cache()
        result = _server_mod.mine_file(path, "what VLAN is public-facing?", top_k=3)
        assert result["strategy"] == "document", f"expected 'document', got {result['strategy']}"
        assert result["chunk_count"] >= 2

        top = result["results"][0]
        assert "DMZ" in top["content"], (
            f"top chunk should mention DMZ; got: {top['content'][:200]}"
        )
        # section_path metadata should be present for document
        assert "section_path" in top["metadata"]
        # The DMZ subsection lives under VLAN Segmentation
        assert "VLAN" in top["metadata"]["section_path"]
    finally:
        os.unlink(path)


def test_irrelevant_chunk_ranks_lower_than_relevant_chunk():
    """The ranking must actually discriminate; scores should separate relevant
    from irrelevant content. Requires a fixture large enough to produce >1 chunk."""
    path = _write_tmp(".py", CODE_CONTENT)
    try:
        _fresh_cache()
        result = _server_mod.mine_file(path, "how do I connect to a database?", top_k=5)
        if result["chunk_count"] < 2:
            raise AssertionError(
                f"test fixture produced only {result['chunk_count']} chunk(s); "
                "ranking can't be meaningful. Fix the fixture, not the code."
            )
        scores = [r["score"] for r in result["results"]]
        # At least one chunk should be clearly more relevant than the last
        assert scores[0] > scores[-1], (
            f"top score {scores[0]} should exceed bottom score {scores[-1]}; "
            "scores may be too flat to be useful"
        )
        # And the top chunk should be the one about database connection
        top_content = result["results"][0]["content"]
        assert "connect_to_database" in top_content or "sqlalchemy" in top_content, (
            f"top chunk should mention database; got: {top_content[:200]}"
        )
    finally:
        os.unlink(path)


def test_cache_hit_on_second_call_same_file():
    path = _write_tmp(".md", DOC_CONTENT)
    try:
        _fresh_cache()
        r1 = _server_mod.mine_file(path, "firewall policy?", top_k=2)
        assert r1["from_cache"] is False
        r2 = _server_mod.mine_file(path, "DNS strategy?", top_k=2)
        assert r2["from_cache"] is True, "second call on same file should hit cache"
        assert r2["file_id"] == r1["file_id"], "same file -> same id"
    finally:
        os.unlink(path)


def test_cache_miss_when_file_changes():
    path = _write_tmp(".md", DOC_CONTENT)
    try:
        _fresh_cache()
        r1 = _server_mod.mine_file(path, "firewall?", top_k=1)
        time.sleep(1.1)  # ensure mtime tick
        # Modify the file -- mtime changes -> cache key changes -> re-embed
        with open(path, "a") as f:
            f.write("\n\n## New Section\n\nAdded content.\n")
        r2 = _server_mod.mine_file(path, "firewall?", top_k=1)
        assert r2["from_cache"] is False, "modified file should cause cache miss"
        assert r2["file_id"] != r1["file_id"], "new mtime -> new file_id"
    finally:
        os.unlink(path)


def test_release_file_frees_cache_entry():
    path = _write_tmp(".md", DOC_CONTENT)
    try:
        _fresh_cache()
        r = _server_mod.mine_file(path, "VLAN?", top_k=1)
        file_id = r["file_id"]
        released = _server_mod.release_file(file_id)
        assert released["status"] == "freed"
        # Second release is a no-op
        released2 = _server_mod.release_file(file_id)
        assert released2["status"] == "not_cached"
    finally:
        os.unlink(path)


def test_binary_file_rejected():
    fd, path = tempfile.mkstemp(suffix=".bin")
    with os.fdopen(fd, "wb") as f:
        f.write(bytes(range(256)) * 8)  # lots of non-printable
    try:
        _fresh_cache()
        try:
            _server_mod.mine_file(path, "anything", top_k=1)
        except ValueError as e:
            assert "binary" in str(e).lower()
            return
        raise AssertionError("expected ValueError for binary file")
    finally:
        os.unlink(path)


def test_missing_file_raises():
    _fresh_cache()
    try:
        _server_mod.mine_file("/tmp/definitely_does_not_exist_123abc.md", "x", top_k=1)
    except FileNotFoundError:
        return
    raise AssertionError("expected FileNotFoundError")


# ── Runner ───────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    if not _embed_server_up():
        print("SKIP: llama-embed.service not reachable on :11437", file=sys.stderr)
        print("      Start with: systemctl --user start llama-embed.service", file=sys.stderr)
        sys.exit(2)

    import inspect
    current = sys.modules[__name__]
    tests = [(name, obj) for name, obj in inspect.getmembers(current)
             if name.startswith("test_") and callable(obj)]
    failed = 0
    for name, fn in tests:
        try:
            t0 = time.monotonic()
            fn()
            t1 = time.monotonic()
            print(f"PASS  {name:60s}  ({t1 - t0:.2f}s)")
        except AssertionError as e:
            failed += 1
            print(f"FAIL  {name}: {e}")
        except Exception as e:
            failed += 1
            print(f"ERROR {name}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
