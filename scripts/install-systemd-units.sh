#!/usr/bin/env bash
# Install or refresh the systemd unit files and the sysctl setting
# that keeps Electron apps from crashing on Ubuntu 24.04.
#
# Idempotent. Safe to re-run after repo updates.
#
# Scope:
# - searxng.service goes to ~/.config/systemd/user/ (user-scope).
# - llama-primary, llama-secondary, llama-embed, llama-coder go to
#   /etc/systemd/system/ (system-scope) so polkit-managed start/stop
#   works for both local users.
# - The sysctl drop-in goes to /etc/sysctl.d/.
#
# Requires sudo for the system-scope and sysctl steps. The script
# uses `sudo install` for those; configure passwordless sudo or be
# prepared to type your password.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="$REPO/systemd"

USER_UNIT_DST="$HOME/.config/systemd/user"
SYSTEM_UNIT_DST="/etc/systemd/system"

SYSCTL_SRC="$REPO/etc/sysctl.d/60-apparmor-namespace.conf"
SYSCTL_DST="/etc/sysctl.d/60-apparmor-namespace.conf"

LLAMA_UNITS=(llama-primary llama-secondary llama-embed llama-coder)

# ── User-scope units ───────────────────────────────────────────────────────
#
# searxng.service is a user-scope unit installed under
# ~/.config/systemd/user/. When this script runs under `sudo`, $HOME
# is /root and there is no user-scope dbus session there. Drop
# privilege to $SUDO_USER for this block in that case; if we're
# running as the invoking user already, just do it.

install_user_unit_as() {
  local user="$1"
  local user_home
  user_home="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "$user_home" ]]; then
    echo "WARN: cannot resolve home for user $user; skipping user-scope unit install" >&2
    return 0
  fi
  local user_unit_dst="$user_home/.config/systemd/user"
  if [[ "$(id -un)" == "$user" ]]; then
    mkdir -p "$user_unit_dst"
    install -m 0644 "$UNIT_SRC/searxng.service" "$user_unit_dst/"
    systemctl --user daemon-reload
  else
    sudo -u "$user" mkdir -p "$user_unit_dst"
    sudo -u "$user" install -m 0644 "$UNIT_SRC/searxng.service" "$user_unit_dst/"
    sudo -u "$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" systemctl --user daemon-reload \
      || echo "WARN: user-scope daemon-reload failed for $user (no active session?). Re-run later as $user if needed." >&2
  fi
}

if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
  install_user_unit_as "$SUDO_USER"
else
  install_user_unit_as "$(id -un)"
fi

# ── System-scope llama units ──────────────────────────────────────────────

# These units use `EnvironmentFile=/etc/workstation/system.env` for paths
# and ports. Make sure that file exists before installing units; otherwise
# the units will fail to start with "missing variable" errors at exec time.
if [[ ! -f /etc/workstation/system.env ]]; then
  echo "ERROR: /etc/workstation/system.env not found." >&2
  echo "       Install configs/workstation/system.env.example there first:" >&2
  echo "       sudo install -m 0644 configs/workstation/system.env.example /etc/workstation/system.env" >&2
  exit 1
fi

# The three sidecar units (llama-secondary, llama-embed, llama-coder)
# are templates with __WS_MODEL_DIR__/__WS_MODEL_GGUF__/__WS_MODEL_FLAGS__
# placeholders. Render them from configs/workstation/models.toml before
# installing. The primary router (llama-primary) is NOT templated this
# way -- it reads its model pool from /etc/workstation/llama-router.ini
# at runtime; see configs/workstation/llama-router.ini for that.

MODELS_TOML="$REPO/configs/workstation/models.toml"
MODELS_TOML_EXAMPLE="$REPO/configs/workstation/models.toml.example"
if [[ ! -f "$MODELS_TOML" ]]; then
  if [[ -f "$MODELS_TOML_EXAMPLE" ]]; then
    echo "ERROR: $MODELS_TOML not found." >&2
    echo "       Copy the example and edit if you want non-default models:" >&2
    echo "       cp $MODELS_TOML_EXAMPLE $MODELS_TOML" >&2
    exit 1
  else
    echo "ERROR: $MODELS_TOML and example template both missing" >&2
    exit 1
  fi
fi

# render_sidecar_unit <unit-name> <toml-role-key>
# Reads the role from models.toml, substitutes placeholders in the
# repo's <unit-name>.service template, prints the rendered text on
# stdout. Aborts on any error.
render_sidecar_unit() {
  local unit="$1" role="$2"
  python3 - "$MODELS_TOML" "$UNIT_SRC/${unit}.service" "$role" <<'PY'
import re, shlex, sys, tomllib
manifest_path, template_path, role = sys.argv[1], sys.argv[2], sys.argv[3]
with open(manifest_path, "rb") as f:
    manifest = tomllib.load(f)
if role not in manifest:
    sys.exit(f"role '{role}' missing in {manifest_path}")
choice = manifest[role].get("user_choice")
if not choice:
    sys.exit(f"role '{role}' has no [user_choice] block in {manifest_path}")
gguf = choice.get("gguf_filename")
mid = choice.get("id")
flags = choice.get("flags", [])
if not gguf or not mid:
    sys.exit(f"role '{role}' user_choice missing id or gguf_filename")
flag_str = " ".join(shlex.quote(f) for f in flags)
with open(template_path) as f:
    text = f.read()
text = (text
    .replace("__WS_MODEL_DIR__", mid)
    .replace("__WS_MODEL_GGUF__", gguf)
    .replace("__WS_MODEL_FLAGS__", flag_str))
if "__WS_" in text:
    sys.exit(f"unrendered placeholder in {template_path}: " + ", ".join(re.findall(r"__WS_[A-Z_]+__", text)))
sys.stdout.write(text)
PY
}

# Map: unit name -> models.toml role key.
declare -A SIDECAR_ROLES=(
  [llama-secondary]=summarizer
  [llama-embed]=embeddings
  [llama-coder]=edit_prediction
)

for unit in "${LLAMA_UNITS[@]}"; do
  if [[ ! -f "$UNIT_SRC/${unit}.service" ]]; then
    echo "ERROR: $UNIT_SRC/${unit}.service missing from repo" >&2
    exit 1
  fi

  if [[ -n "${SIDECAR_ROLES[$unit]:-}" ]]; then
    role="${SIDECAR_ROLES[$unit]}"
    rendered=$(mktemp)
    if ! render_sidecar_unit "$unit" "$role" > "$rendered"; then
      rm -f "$rendered"
      echo "ERROR: failed to render $unit from models.toml role '$role'" >&2
      exit 1
    fi
    sudo install -m 0644 "$rendered" "$SYSTEM_UNIT_DST/${unit}.service"
    rm -f "$rendered"
  else
    # Primary router -- install verbatim.
    sudo install -m 0644 "$UNIT_SRC/${unit}.service" "$SYSTEM_UNIT_DST/"
  fi
done

# ── mnemory unit ─────────────────────────────────────────────────────────
#
# Lives in a separate block from LLAMA_UNITS because it doesn't share
# the polite-shutdown coordinator (llama-shutdown only knows about GPU
# llama-server processes). Mnemory has its own lifecycle: it's a long-
# running HTTP server with embedded Qdrant, restartable independently.
#
# The repo-shipped systemd/mnemory.service is a template with
# placeholders (__WS_USER__, __WS_USER_HOME__, __WS_USER_LOCAL_BIN__,
# __WS_UVX__) that we render here from the invoking user's environment.
# Same pattern as the polkit rule above. The rendered unit lands at
# /etc/systemd/system/mnemory.service.
#
# Reads /etc/workstation/mnemory.env (separate from system.env because
# it carries the per-user MCP_API_KEYS secret). Install that env file
# first via scripts/install-mnemory-env.sh before enabling the unit.
if [[ -f "$UNIT_SRC/mnemory.service" ]]; then
  WS_USER="${SUDO_USER:-$USER}"
  WS_USER_HOME="$(getent passwd "$WS_USER" | cut -d: -f6)"
  if [[ -z "$WS_USER_HOME" ]]; then
    echo "ERROR: cannot resolve home directory for user $WS_USER" >&2
    exit 1
  fi
  WS_USER_LOCAL_BIN="$WS_USER_HOME/.local/bin"

  # Resolve uvx — try the user's PATH first, then known install spots.
  WS_UVX=""
  for candidate in \
    "$WS_USER_LOCAL_BIN/uvx" \
    "/usr/local/bin/uvx" \
    "/usr/bin/uvx"; do
    if [[ -x "$candidate" ]]; then
      WS_UVX="$candidate"
      break
    fi
  done
  if [[ -z "$WS_UVX" ]]; then
    echo "ERROR: uvx not found. Install uv first (https://docs.astral.sh/uv/)." >&2
    echo "       Tried: $WS_USER_LOCAL_BIN/uvx, /usr/local/bin/uvx, /usr/bin/uvx" >&2
    exit 1
  fi

  RENDERED_MNEMORY="$(mktemp)"
  trap 'rm -f "$RENDERED_MNEMORY"' EXIT
  sed \
    -e "s|__WS_USER__|${WS_USER}|g" \
    -e "s|__WS_USER_HOME__|${WS_USER_HOME}|g" \
    -e "s|__WS_USER_LOCAL_BIN__|${WS_USER_LOCAL_BIN}|g" \
    -e "s|__WS_UVX__|${WS_UVX}|g" \
    "$UNIT_SRC/mnemory.service" > "$RENDERED_MNEMORY"

  if grep -q "__WS_" "$RENDERED_MNEMORY"; then
    echo "ERROR: mnemory.service template substitution failed (placeholder not replaced)" >&2
    grep "__WS_" "$RENDERED_MNEMORY" >&2
    exit 1
  fi

  sudo install -m 0644 "$RENDERED_MNEMORY" "$SYSTEM_UNIT_DST/mnemory.service"
fi

sudo systemctl daemon-reload

# ── llama.cpp-hip dynamic library path ────────────────────────────────────

# The HIP build at /usr/local/lib/llama.cpp-hip/ ships its own copies of
# libllama.so, libggml.so, libmtmd.so, etc. alongside the llama-server
# binary. The binary's baked RUNPATH points at the original build
# directory (typically /tmp/llama-hip-build/...), which is wiped on
# reboot. Without an ldconfig entry the dynamic loader can't find the
# libraries after that point and llama-server fails with:
#   "error while loading shared libraries: libllama-common.so.0:
#    cannot open shared object file: No such file or directory"
#
# This step idempotently installs an ld.so.conf.d entry pointing at the
# install dir and re-runs ldconfig. Safe to run on machines without the
# HIP build present -- the dir just won't exist, ldconfig ignores it.

LLAMA_HIP_LIB_DIR="/usr/local/lib/llama.cpp-hip"
LDCONF_DST="/etc/ld.so.conf.d/llama-hip.conf"

if [[ -d "$LLAMA_HIP_LIB_DIR" ]]; then
  if ! { [[ -f "$LDCONF_DST" ]] && grep -qx "$LLAMA_HIP_LIB_DIR" "$LDCONF_DST"; }; then
    echo "writing $LDCONF_DST -> $LLAMA_HIP_LIB_DIR"
    echo "$LLAMA_HIP_LIB_DIR" | sudo tee "$LDCONF_DST" >/dev/null
    sudo ldconfig
  fi
fi

# ── llama-shutdown helper script ──────────────────────────────────────────

# llama-shutdown is the polite-shutdown coordinator for the llama units.
# It lives at /usr/local/bin/ so both local users can invoke it directly.
# The script reads /etc/workstation/system.env for port numbers; same
# env-file dependency as the units.

LLAMA_SHUTDOWN_SRC="$UNIT_SRC/llama-shutdown"
LLAMA_SHUTDOWN_DST="/usr/local/bin/llama-shutdown"

if [[ ! -x "$LLAMA_SHUTDOWN_SRC" ]]; then
  echo "ERROR: $LLAMA_SHUTDOWN_SRC missing or not executable" >&2
  exit 1
fi
sudo install -m 0755 "$LLAMA_SHUTDOWN_SRC" "$LLAMA_SHUTDOWN_DST"

# ── polkit rule for passwordless systemctl on llama units ─────────────────

# Lets the local users run systemctl start/stop/restart on the llama
# services without sudo. Every llama unit must be listed in the rule's
# allowedUnits array; missing units silently fall through to the
# password prompt and break the launcher's polite-start path.
#
# The template ships with __WS_LLAMA_USERS__ as a placeholder for the
# allowedUsers list. We render it from WS_LLAMA_USERS in system.env so
# real usernames never enter the repo. WS_LLAMA_USERS is space-separated;
# we validate each token (alphanumerics, underscore, hyphen) and emit a
# JSON array.

POLKIT_SRC="$UNIT_SRC/polkit/10-llama-services.rules"
POLKIT_DST="/etc/polkit-1/rules.d/10-llama-services.rules"

if [[ ! -f "$POLKIT_SRC" ]]; then
  echo "ERROR: $POLKIT_SRC missing from repo" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/workstation/system.env
if [[ -z "${WS_LLAMA_USERS:-}" ]]; then
  echo "ERROR: WS_LLAMA_USERS not set in /etc/workstation/system.env" >&2
  echo "       Add it (see configs/workstation/system.env.example)." >&2
  exit 1
fi

POLKIT_USERS_JSON="["
first=1
for user in $WS_LLAMA_USERS; do
  if [[ ! "$user" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: WS_LLAMA_USERS contains invalid username: '$user'" >&2
    exit 1
  fi
  if (( first )); then first=0; else POLKIT_USERS_JSON+=", "; fi
  POLKIT_USERS_JSON+="\"$user\""
done
POLKIT_USERS_JSON+="]"

POLKIT_TMP="$(mktemp)"
trap 'rm -f "$POLKIT_TMP"' EXIT
# Replace only the code-line occurrence of the placeholder, not comments
# that reference the literal token name.
sed "s|var allowedUsers = __WS_LLAMA_USERS__;|var allowedUsers = ${POLKIT_USERS_JSON};|" \
  "$POLKIT_SRC" > "$POLKIT_TMP"
if grep -q "__WS_LLAMA_USERS__" "$POLKIT_TMP" && \
   ! grep -qE "var allowedUsers = \[" "$POLKIT_TMP"; then
  echo "ERROR: polkit template substitution failed (placeholder not replaced)" >&2
  exit 1
fi
sudo install -m 0644 "$POLKIT_TMP" "$POLKIT_DST"

# ── sysctl drop-in ────────────────────────────────────────────────────────

# Ubuntu 24.04 restricts unprivileged user namespaces by default, which
# triggers kernel traps in Electron apps during window transitions
# (Open Folder, reload). Turning the restriction off restores 22.04 behavior.
if [[ ! -f "$SYSCTL_DST" ]] || ! cmp -s "$SYSCTL_SRC" "$SYSCTL_DST"; then
  sudo install -m 0644 "$SYSCTL_SRC" "$SYSCTL_DST"
  sudo sysctl --system >/dev/null
fi

echo "Installed:"
echo "  $USER_UNIT_DST/searxng.service"
for unit in "${LLAMA_UNITS[@]}"; do
  echo "  $SYSTEM_UNIT_DST/${unit}.service"
done
if [[ -f "$SYSTEM_UNIT_DST/mnemory.service" ]]; then
  echo "  $SYSTEM_UNIT_DST/mnemory.service"
fi
echo "  $LLAMA_SHUTDOWN_DST"
echo "  $POLKIT_DST"
echo "  $SYSCTL_DST"
echo
echo "Note: the llama units were installed but not started. Start them"
echo "individually with: sudo systemctl start llama-primary.service"
echo "(or use the second-opinion launcher to bring them all up at once)."
echo
echo "For mnemory: install the env file first, then enable+start:"
echo "  scripts/install-mnemory-env.sh"
echo "  sudo systemctl enable --now mnemory.service"
