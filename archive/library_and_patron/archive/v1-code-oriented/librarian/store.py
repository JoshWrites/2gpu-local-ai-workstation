"""LanceDB vector store and catalog management.

One LanceDB database per repo, stored at:
  $LIBRARIAN_DB_BASE/<repo_name>/

Tables:
  chunks   — vector embeddings + metadata
  catalog  — per-file mtime tracking for staleness detection
"""

import logging
import os
import time
from pathlib import Path
from typing import Dict, List, Optional

import lancedb
import numpy as np
import pyarrow as pa

log = logging.getLogger(__name__)

DB_BASE = Path(os.environ.get("LIBRARIAN_DB_BASE", Path.home() / ".local/share/librarian/lancedb"))

CHUNK_SCHEMA = pa.schema([
    pa.field("repo",       pa.string()),
    pa.field("file_path",  pa.string()),
    pa.field("start_line", pa.int32()),
    pa.field("end_line",   pa.int32()),
    pa.field("language",   pa.string()),
    pa.field("content",    pa.string()),
    pa.field("vector",     pa.list_(pa.float32(), 1024)),
])

CATALOG_SCHEMA = pa.schema([
    pa.field("repo",        pa.string()),
    pa.field("file_path",   pa.string()),
    pa.field("mtime",       pa.float64()),
    pa.field("chunk_count", pa.int32()),
    pa.field("indexed_at",  pa.float64()),
])


def _repo_key(repo_path: str) -> str:
    return Path(repo_path).name


class Store:
    def __init__(self):
        self._dbs: Dict[str, lancedb.DBConnection] = {}
        self._chunk_tables: Dict[str, lancedb.table.Table] = {}
        self._catalog_tables: Dict[str, lancedb.table.Table] = {}

    def open(self, repo_path: str):
        key = _repo_key(repo_path)
        if key in self._dbs:
            return
        db_path = DB_BASE / key
        db_path.mkdir(parents=True, exist_ok=True)
        log.info("[Setup] Opening LanceDB for repo '%s' at %s", key, db_path)
        db = lancedb.connect(str(db_path))
        self._dbs[key] = db

        # Chunks table
        if "chunks" in db.table_names():
            self._chunk_tables[key] = db.open_table("chunks")
        else:
            self._chunk_tables[key] = db.create_table("chunks", schema=CHUNK_SCHEMA)

        # Catalog table
        if "catalog" in db.table_names():
            self._catalog_tables[key] = db.open_table("catalog")
        else:
            self._catalog_tables[key] = db.create_table("catalog", schema=CATALOG_SCHEMA)

    def close(self, repo_path: str):
        key = _repo_key(repo_path)
        self._dbs.pop(key, None)
        self._chunk_tables.pop(key, None)
        self._catalog_tables.pop(key, None)
        log.info("[Setup] Closed LanceDB connection for repo '%s'", key)

    def close_all(self):
        for key in list(self._dbs.keys()):
            self._dbs.pop(key, None)
            self._chunk_tables.pop(key, None)
            self._catalog_tables.pop(key, None)
        log.info("[Setup] All LanceDB connections closed")

    def is_open(self, repo_path: str) -> bool:
        return _repo_key(repo_path) in self._dbs

    def upsert_chunks(self, repo_path: str, chunks: List[dict]):
        """Append chunks to the chunks table. Caller must delete old chunks first for updates."""
        key = _repo_key(repo_path)
        table = self._chunk_tables[key]
        rows = []
        for c in chunks:
            rows.append({
                "repo":       c["repo"],
                "file_path":  c["file_path"],
                "start_line": c["start_line"],
                "end_line":   c["end_line"],
                "language":   c["language"],
                "content":    c["content"],
                "vector":     np.array(c["vector"], dtype=np.float32),
            })
        table.add(rows)

    def delete_file_chunks(self, repo_path: str, file_path: str):
        key = _repo_key(repo_path)
        table = self._chunk_tables[key]
        table.delete(f"file_path = '{file_path.replace(chr(39), chr(39)*2)}'")
        log.info("[Index] Deleted old chunks for %s", file_path)

    def search(self, repo_path: str, query_vector: List[float], n: int = 5) -> List[dict]:
        key = _repo_key(repo_path)
        table = self._chunk_tables[key]
        results = (
            table.search(np.array(query_vector, dtype=np.float32))
            .limit(n)
            .to_list()
        )
        return results

    def upsert_catalog(self, repo_path: str, entry: dict):
        key = _repo_key(repo_path)
        table = self._catalog_tables[key]
        fp = entry["file_path"].replace("'", "''")
        table.delete(f"file_path = '{fp}'")
        table.add([{
            "repo":        entry["repo"],
            "file_path":   entry["file_path"],
            "mtime":       entry["mtime"],
            "chunk_count": entry["chunk_count"],
            "indexed_at":  entry.get("indexed_at", time.time()),
        }])

    def get_catalog(self, repo_path: str) -> List[dict]:
        key = _repo_key(repo_path)
        table = self._catalog_tables[key]
        return table.to_arrow().to_pylist()

    def get_chunk_count(self, repo_path: str) -> int:
        key = _repo_key(repo_path)
        return self._chunk_tables[key].count_rows()

    def get_file_count(self, repo_path: str) -> int:
        key = _repo_key(repo_path)
        return self._catalog_tables[key].count_rows()

    def get_last_indexed(self, repo_path: str) -> Optional[float]:
        catalog = self.get_catalog(repo_path)
        if not catalog:
            return None
        return max(row["indexed_at"] for row in catalog)

    def is_stale(self, repo_path: str) -> List[str]:
        """Return list of relative file paths whose mtime on disk is newer than recorded."""
        stale = []
        rp = Path(repo_path)
        for row in self.get_catalog(repo_path):
            rel = row["file_path"]
            fp = Path(rel) if Path(rel).is_absolute() else rp / rel
            if fp.exists():
                current_mtime = fp.stat().st_mtime
                if current_mtime > row["mtime"]:
                    stale.append(rel)
            else:
                stale.append(rel)  # deleted files are also stale
        return stale

    @staticmethod
    def repo_is_indexed(repo_path: str) -> bool:
        """Check if a repo has a .librarian marker and LanceDB data."""
        marker = Path(repo_path) / ".librarian"
        key = _repo_key(repo_path)
        db_path = DB_BASE / key
        return marker.exists() and db_path.exists()
