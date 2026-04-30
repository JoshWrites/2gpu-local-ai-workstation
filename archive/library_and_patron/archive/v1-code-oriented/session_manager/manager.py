"""AI Session Manager.

Starts configured GPU services when any trigger AI app is launched (inotify),
stops them when all trigger apps have exited (polling + grace period).

Config:
  ~/.config/ai-session/config.yaml   — trigger_apps, timing
  ~/.config/ai-session/services.yaml — services to manage
"""

import logging
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import List

log = logging.getLogger(__name__)

CONFIG_DIR = Path(os.environ.get("AI_SESSION_CONFIG", Path.home() / ".config/ai-session"))
CONFIG_FILE = CONFIG_DIR / "config.yaml"
SERVICES_FILE = CONFIG_DIR / "services.yaml"


# --- Config loading ---

def _load_yaml(path: Path) -> dict:
    import yaml
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_config() -> dict:
    defaults = {
        "trigger_apps": ["codium", "aider", "code", "zed"],
        "grace_period_seconds": 60,
        "poll_interval_seconds": 10,
        "watch_dirs": ["/usr/bin", "/usr/local/bin", str(Path.home() / ".local/bin")],
    }
    if CONFIG_FILE.exists():
        try:
            data = _load_yaml(CONFIG_FILE)
            defaults.update(data)
        except Exception as e:
            log.warning("Could not load config.yaml: %s", e)
    return defaults


def load_services() -> List[dict]:
    defaults = [
        {"name": "ollama-gpu1", "type": "system", "required": True},
        {"name": "ollama-gpu0", "type": "system", "required": True},
        {"name": "librarian",   "type": "system", "required": True},
    ]
    if SERVICES_FILE.exists():
        try:
            data = _load_yaml(SERVICES_FILE)
            return data.get("services", defaults)
        except Exception as e:
            log.warning("Could not load services.yaml: %s", e)
    return defaults


# --- Service control ---

def _systemctl(action: str, service: str) -> bool:
    """Run systemctl start/stop. Returns True on success."""
    cmd = ["sudo", "systemctl", action, service]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        log.error("systemctl %s %s failed: %s", action, service, result.stderr.strip())
        return False
    log.info("systemctl %s %s: OK", action, service)
    return True


def _notify(title: str, body: str, actions: List[str] = None) -> str:
    """Send a desktop notification. Returns chosen action name or '' on failure."""
    cmd = ["notify-send", "--wait", title, body]
    if actions:
        for i, action in enumerate(actions):
            cmd += [f"--action={i}={action}"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        output = result.stdout.strip()
        if actions and output.isdigit():
            idx = int(output)
            if 0 <= idx < len(actions):
                return actions[idx]
        return output
    except Exception as e:
        log.warning("notify-send failed: %s", e)
        return ""


# --- Process detection ---

def _any_trigger_running(trigger_apps: List[str]) -> bool:
    try:
        result = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            for app in trigger_apps:
                if app in line and "grep" not in line and "session_manager" not in line:
                    return True
    except Exception as e:
        log.warning("ps aux failed: %s", e)
    return False


# --- Session lifecycle ---

class SessionManager:
    def __init__(self):
        self.config = load_config()
        self.services = load_services()
        self._active = False
        self._skipped = set()
        self._lock = threading.Lock()
        self._grace_timer: threading.Timer = None
        self._poll_thread: threading.Thread = None
        self._stop_event = threading.Event()

    def start_session(self):
        with self._lock:
            if self._active:
                return
            # Cancel any pending shutdown
            if self._grace_timer:
                self._grace_timer.cancel()
                self._grace_timer = None
                log.info("Grace period cancelled — apps reopened")
                return
            self._active = True

        log.info("=== AI session starting ===")
        for svc in self.services:
            name = svc["name"]
            if name in self._skipped:
                continue
            if not _systemctl("start", name):
                if svc.get("required", True):
                    action = _notify(
                        f"AI Session: {name} failed to start",
                        f"Service '{name}' could not be started. What would you like to do?",
                        actions=["Continue without", "Retry"],
                    )
                    if action == "Retry":
                        if _systemctl("start", name):
                            _notify(f"AI Session: {name} started", f"Service '{name}' started successfully.")
                        else:
                            _notify(f"AI Session: {name} unavailable", f"Service '{name}' still unavailable. Continuing without it.")
                            self._skipped.add(name)
                    else:
                        log.info("Skipping %s for this session (user choice)", name)
                        self._skipped.add(name)

        log.info("=== AI session active ===")

    def stop_session(self):
        with self._lock:
            if not self._active:
                return
            self._active = False
            self._grace_timer = None

        log.info("=== AI session stopping ===")
        self._skipped.clear()
        for svc in reversed(self.services):
            name = svc["name"]
            _systemctl("stop", name)
        log.info("=== AI session stopped ===")

    def _start_grace_period(self):
        grace = self.config.get("grace_period_seconds", 60)
        log.info("Grace period started (%ds) — all trigger apps closed", grace)
        with self._lock:
            if self._grace_timer:
                self._grace_timer.cancel()
            self._grace_timer = threading.Timer(grace, self.stop_session)
            self._grace_timer.start()

    def _poll_loop(self):
        trigger_apps = self.config.get("trigger_apps", [])
        poll_interval = self.config.get("poll_interval_seconds", 10)

        while not self._stop_event.wait(poll_interval):
            running = _any_trigger_running(trigger_apps)
            if running:
                # Cancel any pending shutdown, start session if not active
                with self._lock:
                    if self._grace_timer:
                        self._grace_timer.cancel()
                        self._grace_timer = None
                        log.info("Grace period cancelled — app redetected by poll")
                if not self._active:
                    self.start_session()
            else:
                # No apps running — start grace period if session is active and none pending
                should_start_grace = False
                with self._lock:
                    if self._active and not self._grace_timer:
                        should_start_grace = True
                if should_start_grace:
                    self._start_grace_period()

    def _inotify_loop(self):
        """Watch trigger app binary dirs for exec events."""
        try:
            import inotify_simple
        except ImportError:
            log.warning("inotify-simple not available — falling back to poll-only startup detection")
            return

        trigger_apps = self.config.get("trigger_apps", [])
        watch_dirs = self.config.get("watch_dirs", ["/usr/bin", "/usr/local/bin"])

        inotify = inotify_simple.INotify()
        flags = inotify_simple.flags.OPEN

        watched = {}
        for d in watch_dirs:
            if Path(d).exists():
                wd = inotify.add_watch(d, flags)
                watched[wd] = d
                log.info("inotify: watching %s", d)

        if not watched:
            log.warning("inotify: no watch dirs found")
            return

        log.info("inotify: ready — watching for %s", trigger_apps)
        while not self._stop_event.is_set():
            events = inotify.read(timeout=1000)
            for event in events:
                name = event.name
                if any(app in name for app in trigger_apps):
                    d = watched.get(event.wd, "?")
                    log.info("inotify: trigger app opened: %s/%s", d, name)
                    self.start_session()

    def run(self):
        log.info("Session manager starting. Config: %s", CONFIG_DIR)

        # Check if any trigger apps already running on startup
        trigger_apps = self.config.get("trigger_apps", [])
        if _any_trigger_running(trigger_apps):
            log.info("Trigger apps already running on startup — starting session")
            self.start_session()

        # inotify thread for fast startup detection
        inotify_thread = threading.Thread(target=self._inotify_loop, daemon=True, name="inotify")
        inotify_thread.start()

        # Polling thread for shutdown detection
        self._poll_thread = threading.Thread(target=self._poll_loop, daemon=True, name="poller")
        self._poll_thread.start()

        log.info("Session manager running. Watching for: %s", trigger_apps)

        try:
            self._stop_event.wait()
        except KeyboardInterrupt:
            pass
        finally:
            self._stop_event.set()
            if self._active:
                self.stop_session()
            log.info("Session manager exited")


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stderr,
    )
    # Install PyYAML if missing (needed for config)
    try:
        import yaml
    except ImportError:
        log.error("PyYAML is required. Install with: pip install pyyaml")
        sys.exit(1)

    mgr = SessionManager()
    mgr.run()


if __name__ == "__main__":
    main()
