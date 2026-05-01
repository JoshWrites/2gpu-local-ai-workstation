"""In-memory LRU cache for mined files.

Keyed on file_id, which is derived from (absolute_path, mtime). If a file is
re-mined after it was modified on disk, the cache miss is automatic because
the key changes.

Bounded by entry count rather than memory bytes -- entries are small (chunks
+ vectors) and the server process is short-lived per opencode session.
"""

from __future__ import annotations

import hashlib
import os
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Optional

from .chunkers import Chunk


MAX_CACHED_FILES = 20  # per-process soft cap


@dataclass
class CachedFile:
    file_id: str
    path: str
    mtime: float
    strategy: str  # "document" | "code"
    chunks: list[Chunk]
    embeddings: list[list[float]]  # parallel to chunks
    last_accessed: float = field(default_factory=time.time)


def make_file_id(path: str, mtime: float) -> str:
    """Stable id for (path, mtime). Short hash for compactness in responses."""
    h = hashlib.sha256(f"{path}|{mtime}".encode("utf-8")).hexdigest()
    return f"f_{h[:12]}"


class FileCache:
    """LRU cache of CachedFile entries, bounded by MAX_CACHED_FILES."""

    def __init__(self, max_entries: int = MAX_CACHED_FILES) -> None:
        self._entries: "OrderedDict[str, CachedFile]" = OrderedDict()
        self._max = max_entries

    def get(self, file_id: str) -> Optional[CachedFile]:
        entry = self._entries.get(file_id)
        if entry is None:
            return None
        # LRU touch
        self._entries.move_to_end(file_id)
        entry.last_accessed = time.time()
        return entry

    def put(self, entry: CachedFile) -> None:
        self._entries[entry.file_id] = entry
        self._entries.move_to_end(entry.file_id)
        while len(self._entries) > self._max:
            self._entries.popitem(last=False)

    def release(self, file_id: str) -> bool:
        """Drop an entry. Returns True if removed, False if not present."""
        return self._entries.pop(file_id, None) is not None

    def lookup_by_path(self, path: str) -> Optional[CachedFile]:
        """Find a cache entry by path (not file_id), matching current mtime.

        If the file on disk has been modified since caching, this returns None
        so callers can re-mine transparently.
        """
        abs_path = os.path.abspath(path)
        try:
            current_mtime = os.path.getmtime(abs_path)
        except OSError:
            return None
        expected_id = make_file_id(abs_path, current_mtime)
        return self.get(expected_id)

    def stats(self) -> dict:
        return {
            "cached_files": len(self._entries),
            "max_entries": self._max,
            "file_ids": list(self._entries.keys()),
        }
