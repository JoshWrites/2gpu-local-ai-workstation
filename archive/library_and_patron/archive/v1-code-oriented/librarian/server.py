"""Librarian MCP Server — entrypoint.

Persistent HTTP server on localhost:11436.
Manages the Store, RepoWatcher, and RepoDetector.
Exposes four MCP tools to any connected client.
"""

import logging
import os
import signal
import sys
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from . import embedder
from .embedder import EmbedderError, embed_query
from .gpu_detect import detect_gpus, verify_or_abort
from .indexer import delta_index_file, index_repo
from .repo_detector import RepoDetector
from .store import Store
from .watcher import RepoWatcher

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

PORT = int(os.environ.get("LIBRARIAN_PORT", 11436))

# Global state
store = Store()
watcher: RepoWatcher = None
detector: RepoDetector = None
mcp = FastMCP("librarian", host="127.0.0.1", port=PORT)


# --- Repo lifecycle callbacks ---

def _on_new_repo(repo_path: str):
    try:
        store.open(repo_path)
        watcher.watch(repo_path)
        log.info("[Setup] Loaded and watching: %s", repo_path)
    except Exception as e:
        log.error("[Error] Failed to load repo %s: %s", repo_path, e)


def _on_closed_repo(repo_path: str):
    try:
        watcher.unwatch(repo_path)
        store.close(repo_path)
        log.info("[Setup] Unloaded: %s", repo_path)
    except Exception as e:
        log.error("[Error] Failed to unload repo %s: %s", repo_path, e)


def _delta_callback(file_path: str, repo_path: str):
    delta_index_file(file_path, repo_path, store)


# --- MCP Tools ---

@mcp.tool()
def index_repo_tool(repo_path: str) -> str:
    """Index a repository for the first time.

    Walks all code files, embeds them using GPU1, and stores vectors in LanceDB.
    Creates a .librarian/ marker in the repo root.
    This only needs to be run once per repo — delta updates happen automatically after that.

    Args:
        repo_path: Absolute path to the git repository root.
    """
    try:
        rp = Path(repo_path).resolve()
        if not rp.exists():
            return f"Error: path does not exist: {repo_path}"
        if not (rp / ".git").exists():
            return f"Error: not a git repository: {repo_path}"

        summary = index_repo(str(rp), store)

        # Start watching after initial index
        if not watcher or str(rp) not in watcher._watches:
            _on_new_repo(str(rp))

        return (
            f"Index complete for '{rp.name}':\n"
            f"  Files indexed:  {summary.files_indexed}\n"
            f"  Chunks created: {summary.chunks_created}\n"
            f"  Time taken:     {summary.elapsed_seconds:.1f}s\n"
            f"  .librarian/ marker created and added to .git/info/exclude"
        )
    except Exception as e:
        log.error("[Error] index_repo failed: %s", e)
        return f"Error indexing repo: {e}"


@mcp.tool()
def get_relevant_context(query: str, repo_path: str, n_results: int = 5) -> str:
    """Retrieve the most relevant code chunks for a query from an indexed repository.

    Returns top-N chunks with file path, line range, and content — ready to paste into context.

    Args:
        query:     Natural language description of what you're looking for.
        repo_path: Absolute path to the git repository root.
        n_results: Number of chunks to return (default 5).
    """
    try:
        rp = Path(repo_path).resolve()

        if not store.is_open(str(rp)):
            if not Store.repo_is_indexed(str(rp)):
                return (
                    f"Repository '{rp.name}' has not been indexed yet.\n"
                    f"Call index_repo_tool with repo_path='{rp}' to index it first."
                )
            # Auto-load if indexed but not open (e.g. after service restart)
            store.open(str(rp))

        try:
            query_vector = embed_query(query)
        except EmbedderError as e:
            return f"Error embedding query (is ollama-gpu0 running on port 11435?): {e}"

        results = store.search(str(rp), query_vector, n=n_results)

        if not results:
            return f"No results found for query '{query}' in '{rp.name}'."

        lines = [f"Relevant context from '{rp.name}' for query: {query}\n{'='*60}"]
        for i, row in enumerate(results, 1):
            lines.append(
                f"\n[{i}] {row['file_path']} (lines {row['start_line']}–{row['end_line']}) "
                f"[{row['language']}]\n"
                f"{'-'*40}\n"
                f"{row['content']}"
            )
        return "\n".join(lines)

    except Exception as e:
        log.error("[Error] get_relevant_context failed: %s", e)
        return f"Error retrieving context: {e}"


@mcp.tool()
def list_indexed_repos() -> str:
    """List all indexed repositories with file count, chunk count, last-indexed time, and watch status."""
    try:
        from .store import DB_BASE
        if not DB_BASE.exists():
            return "No repositories have been indexed yet."

        lines = ["Indexed repositories:\n"]
        found = False
        for db_dir in sorted(DB_BASE.iterdir()):
            if not db_dir.is_dir():
                continue
            repo_name = db_dir.name
            # Try to open and read stats
            try:
                tmp_store = Store()
                # Find a matching repo path by name
                # We store stats without needing the full path
                db = __import__("lancedb").connect(str(db_dir))
                if "catalog" not in db.table_names():
                    continue
                catalog_table = db.open_table("catalog")
                catalog = catalog_table.to_arrow().to_pylist()
                chunk_table = db.open_table("chunks") if "chunks" in db.table_names() else None
                chunk_count = chunk_table.count_rows() if chunk_table else 0
                file_count = len(catalog)
                last_indexed = max((r["indexed_at"] for r in catalog), default=0)
                last_str = time.strftime("%Y-%m-%d %H:%M", time.localtime(last_indexed)) if last_indexed else "never"
                watched = any(repo_name in rp for rp in (watcher._watches if watcher else {}))
                lines.append(
                    f"  {repo_name}\n"
                    f"    Files:        {file_count}\n"
                    f"    Chunks:       {chunk_count}\n"
                    f"    Last indexed: {last_str}\n"
                    f"    Watched:      {'yes' if watched else 'no'}"
                )
                found = True
            except Exception as e:
                lines.append(f"  {repo_name}: (error reading stats: {e})")

        return "\n".join(lines) if found else "No repositories have been indexed yet."
    except Exception as e:
        log.error("[Error] list_indexed_repos failed: %s", e)
        return f"Error listing repos: {e}"


@mcp.tool()
def get_index_status(repo_path: str) -> str:
    """Get the index status of a repository — indexed/not-indexed, file/chunk counts, stale files.

    Args:
        repo_path: Absolute path to the git repository root.
    """
    try:
        rp = Path(repo_path).resolve()
        repo_name = rp.name

        if not Store.repo_is_indexed(str(rp)):
            return f"'{repo_name}' is not indexed. Call index_repo_tool to index it."

        if not store.is_open(str(rp)):
            store.open(str(rp))

        file_count = store.get_file_count(str(rp))
        chunk_count = store.get_chunk_count(str(rp))
        last_indexed = store.get_last_indexed(str(rp))
        last_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(last_indexed)) if last_indexed else "unknown"
        stale = store.is_stale(str(rp))
        watched = watcher and str(rp) in watcher._watches

        lines = [
            f"Index status for '{repo_name}':",
            f"  Files indexed: {file_count}",
            f"  Chunks:        {chunk_count}",
            f"  Last indexed:  {last_str}",
            f"  Watched:       {'yes (live delta updates active)' if watched else 'no'}",
        ]
        if stale:
            lines.append(f"  Stale files ({len(stale)}):")
            for f in stale[:20]:
                lines.append(f"    - {f}")
            if len(stale) > 20:
                lines.append(f"    ... and {len(stale) - 20} more")
        else:
            lines.append("  Stale files:   none (index is current)")

        return "\n".join(lines)
    except Exception as e:
        log.error("[Error] get_index_status failed: %s", e)
        return f"Error getting index status: {e}"


# --- Shutdown ---

def _shutdown(signum, frame):
    log.info("[Setup] Shutting down Librarian...")
    if detector:
        detector.stop()
    if watcher:
        watcher.stop()
    store.close_all()
    log.info("[Setup] Librarian shutdown complete")
    sys.exit(0)


# --- Main ---

def main():
    global watcher, detector

    log.info("[Setup] Librarian MCP server starting on port %d", PORT)

    # Detect GPUs and initialise embedder — must happen before any embed calls
    infer_url, embed_url = detect_gpus()
    embedder.init(infer_url, embed_url)

    if not verify_or_abort(infer_url, embed_url):
        log.warning(
            "[Setup] One or more Ollama instances unreachable. "
            "Continuing — embed calls will fail until they become available."
        )

    watcher = RepoWatcher(delta_callback=_delta_callback)
    detector = RepoDetector(on_new_repo=_on_new_repo, on_closed_repo=_on_closed_repo)
    detector.start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
