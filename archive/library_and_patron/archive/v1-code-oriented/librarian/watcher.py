"""File system watcher for live delta indexing.

Uses watchdog to monitor repos for changes. On file modify/create/delete,
triggers delta_index_file() after a short debounce to avoid thrashing on
rapid saves.
"""

import logging
import threading
import time
from pathlib import Path
from typing import Callable, Dict

from watchdog.events import FileSystemEventHandler, FileSystemEvent
from watchdog.observers import Observer

from .indexer import ALLOW_EXTENSIONS, SKIP_DIRS

log = logging.getLogger(__name__)

DEBOUNCE_SECONDS = 2.0


class _DebouncedHandler(FileSystemEventHandler):
    def __init__(self, repo_path: str, callback: Callable[[str, str], None]):
        super().__init__()
        self._repo_path = repo_path
        self._callback = callback
        self._pending: Dict[str, threading.Timer] = {}
        self._lock = threading.Lock()

    def _should_handle(self, path: str) -> bool:
        p = Path(path)
        if p.suffix.lower() not in ALLOW_EXTENSIONS:
            return False
        parts = p.parts
        if any(part in SKIP_DIRS for part in parts):
            return False
        return True

    def _schedule(self, path: str):
        if not self._should_handle(path):
            return
        with self._lock:
            existing = self._pending.get(path)
            if existing:
                existing.cancel()
            timer = threading.Timer(DEBOUNCE_SECONDS, self._fire, args=[path])
            self._pending[path] = timer
            timer.start()

    def _fire(self, path: str):
        with self._lock:
            self._pending.pop(path, None)
        log.info("[Watch] Change detected, triggering delta index: %s", path)
        try:
            self._callback(path, self._repo_path)
        except Exception as e:
            log.error("[Error] Delta index failed for %s: %s", path, e)

    def on_modified(self, event: FileSystemEvent):
        if not event.is_directory:
            self._schedule(event.src_path)

    def on_created(self, event: FileSystemEvent):
        if not event.is_directory:
            self._schedule(event.src_path)

    def on_deleted(self, event: FileSystemEvent):
        if not event.is_directory:
            self._schedule(event.src_path)

    def on_moved(self, event: FileSystemEvent):
        if not event.is_directory:
            # Treat as delete old + create new
            self._schedule(event.src_path)
            self._schedule(event.dest_path)


class RepoWatcher:
    def __init__(self, delta_callback: Callable[[str, str], None]):
        """
        delta_callback(file_path, repo_path) — called when a file changes.
        """
        self._callback = delta_callback
        self._observer = Observer()
        self._observer.start()
        self._watches: Dict[str, object] = {}

    def watch(self, repo_path: str):
        if repo_path in self._watches:
            return
        handler = _DebouncedHandler(repo_path, self._callback)
        watch = self._observer.schedule(handler, repo_path, recursive=True)
        self._watches[repo_path] = watch
        log.info("[Watch] Started watching %s", repo_path)

    def unwatch(self, repo_path: str):
        watch = self._watches.pop(repo_path, None)
        if watch:
            self._observer.unschedule(watch)
            log.info("[Watch] Stopped watching %s", repo_path)

    def unwatch_all(self):
        for repo_path in list(self._watches.keys()):
            self.unwatch(repo_path)

    def stop(self):
        self.unwatch_all()
        self._observer.stop()
        self._observer.join()
        log.info("[Watch] Observer stopped")
