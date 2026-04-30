"""File walking, chunking, and indexing.

index_repo()       — full initial index via GPU1 embeddings
delta_index_file() — re-index a single changed file via GPU0 embeddings
"""

import logging
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

import pathspec

from .embedder import EmbedderError, embed_delta, embed_initial
from .store import Store

log = logging.getLogger(__name__)

# ~2000 chars as a proxy for 500 tokens
CHUNK_SIZE_CHARS = 2000
CHUNK_OVERLAP_CHARS = 200

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".librarian",
             "dist", "build", ".next", ".nuxt", "target"}

SKIP_EXTENSIONS = {".lock", ".min.js", ".min.css", ".map", ".pyc", ".pyo",
                   ".so", ".dylib", ".dll", ".exe", ".bin", ".o", ".a",
                   ".jpg", ".jpeg", ".png", ".gif", ".ico", ".svg", ".webp",
                   ".mp3", ".mp4", ".wav", ".zip", ".tar", ".gz", ".pdf"}

ALLOW_EXTENSIONS = {
    ".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs",
    ".yaml", ".yml", ".json", ".md", ".sh", ".toml",
    ".tf", ".nix", ".c", ".cpp", ".h", ".hpp",
    ".html", ".css", ".env.example", ".sql",
}

LANGUAGE_MAP = {
    ".py": "python", ".js": "javascript", ".ts": "typescript",
    ".jsx": "javascript", ".tsx": "typescript", ".go": "go",
    ".rs": "rust", ".c": "c", ".cpp": "cpp", ".h": "c",
    ".hpp": "cpp", ".sh": "bash", ".yaml": "yaml", ".yml": "yaml",
    ".json": "json", ".toml": "toml", ".md": "markdown",
    ".tf": "terraform", ".nix": "nix", ".html": "html",
    ".css": "css", ".sql": "sql",
}


@dataclass
class IndexSummary:
    repo_path: str
    files_indexed: int
    chunks_created: int
    elapsed_seconds: float


def _load_gitignore(repo_path: Path) -> Optional[pathspec.PathSpec]:
    gitignore = repo_path / ".gitignore"
    if gitignore.exists():
        with open(gitignore) as f:
            return pathspec.PathSpec.from_lines("gitwildmatch", f)
    return None


def _should_index(path: Path, repo_path: Path, spec: Optional[pathspec.PathSpec]) -> bool:
    if path.suffix.lower() in SKIP_EXTENSIONS:
        return False
    if path.suffix.lower() not in ALLOW_EXTENSIONS:
        return False
    rel = path.relative_to(repo_path)
    parts = rel.parts
    if any(part in SKIP_DIRS for part in parts):
        return False
    if spec and spec.match_file(str(rel)):
        return False
    return True


def _walk_repo(repo_path: Path, spec: Optional[pathspec.PathSpec]) -> List[Path]:
    files = []
    for p in repo_path.rglob("*"):
        if p.is_file() and _should_index(p, repo_path, spec):
            files.append(p)
    return files


def _chunk_text(text: str, file_path: str) -> List[dict]:
    """Split text into overlapping chunks, returning list of chunk dicts (no vector yet)."""
    chunks = []
    lines = text.splitlines(keepends=True)
    current_chars = 0
    current_lines: List[str] = []
    start_line = 1
    line_num = 1

    def flush(lines_buf, s_line, e_line):
        content = "".join(lines_buf).strip()
        if content:
            chunks.append({
                "file_path":  file_path,
                "start_line": s_line,
                "end_line":   e_line,
                "content":    content,
            })

    for line in lines:
        current_lines.append(line)
        current_chars += len(line)
        if current_chars >= CHUNK_SIZE_CHARS:
            flush(current_lines, start_line, line_num)
            # Overlap: keep last N chars worth of lines
            overlap_chars = 0
            overlap_lines = []
            for ol in reversed(current_lines):
                overlap_chars += len(ol)
                overlap_lines.insert(0, ol)
                if overlap_chars >= CHUNK_OVERLAP_CHARS:
                    break
            current_lines = overlap_lines
            current_chars = sum(len(l) for l in current_lines)
            start_line = line_num - len(overlap_lines) + 1
        line_num += 1

    if current_lines:
        flush(current_lines, start_line, line_num - 1)

    return chunks


def _read_file(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        log.warning("[Index] Could not read %s: %s", path, e)
        return None


def _setup_librarian_dir(repo_path: Path):
    """Create .librarian marker dir and add to .git/info/exclude."""
    marker = repo_path / ".librarian"
    marker.mkdir(exist_ok=True)
    (marker / "README").write_text(
        "This directory is managed by the Librarian MCP server.\n"
        "It contains metadata used for fast context retrieval.\n"
        "Do not commit this directory — it is excluded via .git/info/exclude.\n"
    )
    exclude_file = repo_path / ".git" / "info" / "exclude"
    if exclude_file.exists():
        content = exclude_file.read_text()
        if ".librarian" not in content:
            with open(exclude_file, "a") as f:
                f.write("\n# Librarian MCP index\n.librarian/\n")
            log.info("[Setup] Added .librarian/ to .git/info/exclude")


def index_repo(repo_path: str, store: Store) -> IndexSummary:
    """Full initial index of a repo. Uses GPU1 for embeddings."""
    start = time.time()
    rp = Path(repo_path).resolve()
    repo_name = rp.name
    log.info("[Index] Starting full index of '%s'", repo_name)

    _setup_librarian_dir(rp)
    store.open(repo_path)

    spec = _load_gitignore(rp)
    files = _walk_repo(rp, spec)
    log.info("[Index] Found %d indexable files", len(files))

    files_indexed = 0
    chunks_created = 0

    for file_path in files:
        text = _read_file(file_path)
        if text is None:
            continue

        rel_path = str(file_path.relative_to(rp))
        lang = LANGUAGE_MAP.get(file_path.suffix.lower(), "text")
        raw_chunks = _chunk_text(text, rel_path)
        if not raw_chunks:
            continue

        # Delete any existing chunks for this file before re-indexing
        store.delete_file_chunks(repo_path, rel_path)

        # Embed in batches, write-through immediately
        texts = [c["content"] for c in raw_chunks]
        try:
            vectors = embed_initial(texts)
        except EmbedderError as e:
            log.error("[Error] %s — skipping file %s", e, rel_path)
            continue

        enriched = []
        for chunk, vector in zip(raw_chunks, vectors):
            enriched.append({
                "repo":       repo_name,
                "file_path":  chunk["file_path"],
                "start_line": chunk["start_line"],
                "end_line":   chunk["end_line"],
                "language":   lang,
                "content":    chunk["content"],
                "vector":     vector,
            })

        store.upsert_chunks(repo_path, enriched)
        store.upsert_catalog(repo_path, {
            "repo":        repo_name,
            "file_path":   rel_path,
            "mtime":       file_path.stat().st_mtime,
            "chunk_count": len(enriched),
        })

        files_indexed += 1
        chunks_created += len(enriched)
        log.info("[Index] Indexed %s (%d chunks)", rel_path, len(enriched))

    elapsed = time.time() - start
    log.info("[Index] Complete: %d files, %d chunks in %.1fs", files_indexed, chunks_created, elapsed)
    return IndexSummary(
        repo_path=repo_path,
        files_indexed=files_indexed,
        chunks_created=chunks_created,
        elapsed_seconds=elapsed,
    )


def delta_index_file(file_path: str, repo_path: str, store: Store):
    """Re-index a single changed file. Uses GPU0 for embeddings."""
    rp = Path(repo_path).resolve()
    repo_name = rp.name
    abs_path = Path(file_path).resolve()
    rel_path = str(abs_path.relative_to(rp))
    lang = LANGUAGE_MAP.get(abs_path.suffix.lower(), "text")

    log.info("[Index] Delta re-index: %s", rel_path)

    store.delete_file_chunks(repo_path, rel_path)

    if not abs_path.exists():
        # File was deleted — remove from catalog too
        cat_table = store._catalog_tables.get(rp.name)
        if cat_table:
            fp = rel_path.replace("'", "''")
            cat_table.delete(f"file_path = '{fp}'")
        log.info("[Index] File deleted, removed from index: %s", rel_path)
        return

    text = _read_file(abs_path)
    if text is None:
        return

    raw_chunks = _chunk_text(text, rel_path)
    if not raw_chunks:
        return

    texts = [c["content"] for c in raw_chunks]
    try:
        vectors = embed_delta(texts)
    except EmbedderError as e:
        log.error("[Error] Delta embed failed for %s: %s", rel_path, e)
        return

    enriched = []
    for chunk, vector in zip(raw_chunks, vectors):
        enriched.append({
            "repo":       repo_name,
            "file_path":  chunk["file_path"],
            "start_line": chunk["start_line"],
            "end_line":   chunk["end_line"],
            "language":   lang,
            "content":    chunk["content"],
            "vector":     vector,
        })

    store.upsert_chunks(repo_path, enriched)
    store.upsert_catalog(repo_path, {
        "repo":        repo_name,
        "file_path":   rel_path,
        "mtime":       abs_path.stat().st_mtime,
        "chunk_count": len(enriched),
    })
    log.info("[Index] Delta complete: %s (%d chunks)", rel_path, len(enriched))
