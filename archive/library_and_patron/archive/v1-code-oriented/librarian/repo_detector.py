"""Implicit repo detection from running processes.

Polls VSCodium and Aider process args every 30s to find currently open repos.
Merges with the always-watch list from ~/.config/librarian/watched_repos.yaml.

Only returns repos that already have a .librarian/ marker — never auto-indexes.
"""

import json
import logging
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable, List, Set

log = logging.getLogger(__name__)

POLL_INTERVAL = 30
WATCH_CONFIG = Path(os.environ.get(
    "LIBRARIAN_WATCH_CONFIG",
    Path.home() / ".config/librarian/watched_repos.yaml"
))


def _get_codium_repos() -> List[str]:
    """Extract open workspace paths from VSCodium's backup storage file.

    Only returns results if a VSCodium process is actually running —
    the storage file persists after exit so we guard with a process check.
    """
    repos = []
    # Guard: only read storage if VSCodium is actually running
    try:
        result = subprocess.run(
            ["pgrep", "-x", "codium"],
            capture_output=True, timeout=3
        )
        if result.returncode != 0:
            return repos
    except Exception:
        return repos

    storage = Path.home() / ".config/VSCodium/User/globalStorage/storage.json"
    if not storage.exists():
        return repos
    try:
        with open(storage) as f:
            data = json.load(f)
        workspaces = data.get("backupWorkspaces", {})
        for entry in workspaces.get("folders", []):
            uri = entry.get("folderUri", "")
            if uri.startswith("file://"):
                p = Path(uri[7:])  # strip file://
                if p.is_dir() and (p / ".git").exists():
                    repos.append(str(p))
    except Exception as e:
        log.warning("[Detect] VSCodium detection failed: %s", e)
    return repos


def _get_aider_repos() -> List[str]:
    """Extract working directories from running Aider processes."""
    repos = []
    try:
        result = subprocess.run(
            ["pgrep", "-a", "aider"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            parts = line.split()
            if not parts:
                continue
            pid = parts[0]
            try:
                cwd = os.readlink(f"/proc/{pid}/cwd")
                if Path(cwd).is_dir() and (Path(cwd) / ".git").exists():
                    repos.append(cwd)
            except Exception:
                pass
    except Exception as e:
        log.warning("[Detect] Aider detection failed: %s", e)
    return repos


def _load_always_watch() -> List[str]:
    """Load always-watch list from config file."""
    if not WATCH_CONFIG.exists():
        return []
    try:
        import yaml  # optional dep — only needed if config exists
        with open(WATCH_CONFIG) as f:
            data = yaml.safe_load(f)
        return [str(Path(p).expanduser().resolve()) for p in data.get("always_watch", [])]
    except Exception as e:
        log.warning("[Detect] Could not load watch config %s: %s", WATCH_CONFIG, e)
        return []


def _filter_indexed(repos: List[str]) -> List[str]:
    """Only return repos that have a .librarian/ marker."""
    return [r for r in repos if (Path(r) / ".librarian").exists()]


class RepoDetector:
    def __init__(self, on_new_repo: Callable[[str], None], on_closed_repo: Callable[[str], None]):
        """
        on_new_repo(repo_path)    — called when a new indexed repo is detected
        on_closed_repo(repo_path) — called when a repo is no longer detected
        """
        self._on_new = on_new_repo
        self._on_closed = on_closed_repo
        self._active: Set[str] = set()
        self._thread: threading.Thread = None
        self._stop_event = threading.Event()

    def get_open_repos(self) -> List[str]:
        """Return all currently detected indexed repos (implicit + always-watch)."""
        detected = set()
        detected.update(_get_codium_repos())
        detected.update(_get_aider_repos())
        detected.update(_load_always_watch())
        return _filter_indexed(list(detected))

    def _poll(self):
        while not self._stop_event.wait(POLL_INTERVAL):
            try:
                current = set(self.get_open_repos())
                newly_open = current - self._active
                newly_closed = self._active - current

                for repo in newly_open:
                    log.info("[Detect] New repo detected: %s", repo)
                    self._active.add(repo)
                    self._on_new(repo)

                for repo in newly_closed:
                    log.info("[Detect] Repo no longer open: %s", repo)
                    self._active.discard(repo)
                    self._on_closed(repo)
            except Exception as e:
                log.error("[Error] Repo detector poll failed: %s", e)

    def start(self):
        # Load initial state immediately
        initial = set(self.get_open_repos())
        for repo in initial:
            log.info("[Detect] Initially active repo: %s", repo)
            self._active.add(repo)
            self._on_new(repo)

        self._thread = threading.Thread(target=self._poll, daemon=True, name="repo-detector")
        self._thread.start()
        log.info("[Setup] Repo detector started (poll interval: %ds)", POLL_INTERVAL)

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)
        log.info("[Setup] Repo detector stopped")
