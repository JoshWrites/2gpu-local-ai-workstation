#!/usr/bin/env bash
# preflight.sh -- ~30s precondition check for a fresh install.
#
# Verifies hardware (two AMD GPUs of plausible shapes), drivers
# (ROCm + Vulkan), required system packages, and disk space. Prints
# a green/red checklist; non-zero exit if any HARD check fails.
#
# Soft checks (warnings only) are flagged and don't fail the script.
# Pass --strict to make warnings hard.
#
# This does NOT verify model GGUFs are downloaded; run
# scripts/download-models.sh after this passes.

set -uo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

PASS=0
WARN=0
FAIL=0

ok()   { printf "  \e[32m✓\e[0m %s\n" "$*"; PASS=$((PASS + 1)); }
warn() { printf "  \e[33m!\e[0m %s\n" "$*"; WARN=$((WARN + 1)); }
bad()  { printf "  \e[31m✗\e[0m %s\n" "$*"; FAIL=$((FAIL + 1)); }
hdr()  { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }

# ── 1. Operating system ──────────────────────────────────────────────────────

hdr "Operating system"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  ok "${PRETTY_NAME:-unknown distribution}"
else
  warn "/etc/os-release missing; cannot identify distribution"
fi

systemd_v=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')
if [[ -z "$systemd_v" ]]; then
  bad "systemctl not found (this stack uses systemd-managed services)"
elif (( systemd_v >= 255 )); then
  ok "systemd $systemd_v (>= 255 required)"
else
  bad "systemd $systemd_v -- need 255 or newer"
fi

# ── 2. AMD GPUs ──────────────────────────────────────────────────────────────

hdr "GPUs"

# Need lspci to see the cards even if no driver is loaded.
if command -v lspci >/dev/null 2>&1; then
  amd_gpu_count=$(lspci -nn | grep -iE 'VGA|3D' | grep -ciE 'AMD|Radeon' || echo 0)
  if (( amd_gpu_count >= 2 )); then
    ok "found $amd_gpu_count AMD GPUs via lspci"
  elif (( amd_gpu_count == 1 )); then
    warn "found only 1 AMD GPU; the stack assumes 2 (one big, one small)"
  else
    bad "no AMD GPUs detected via lspci"
  fi
else
  warn "lspci not available; skipping the lspci probe"
fi

if command -v rocm-smi >/dev/null 2>&1; then
  rocm_gpu_count=$(rocm-smi --showproductname 2>/dev/null | grep -oE '^GPU\[[0-9]+\]' | sort -u | wc -l)
  if (( rocm_gpu_count >= 2 )); then
    ok "rocm-smi sees $rocm_gpu_count GPUs"
    rocm-smi --showproductname --showmeminfo vram 2>/dev/null | \
      awk '/Card series/{name=$0} /Total Memory/{print "    " name " -- " $0; name=""}' | head -8
  elif (( rocm_gpu_count == 1 )); then
    warn "rocm-smi sees only 1 GPU; the stack assumes 2"
  else
    bad "rocm-smi found 0 GPUs (kernel module loaded? amdgpu in lsmod?)"
  fi
else
  bad "rocm-smi not found -- ROCm 7.2+ required for build and diagnostics"
fi

if lsmod 2>/dev/null | grep -q '^amdgpu'; then
  ok "amdgpu kernel module loaded"
else
  bad "amdgpu kernel module not loaded"
fi

# ── 3. Vulkan ────────────────────────────────────────────────────────────────

hdr "Vulkan"
if command -v vulkaninfo >/dev/null 2>&1; then
  vk_devices=$(vulkaninfo --summary 2>/dev/null | grep -c 'deviceName')
  if (( vk_devices >= 2 )); then
    ok "vulkaninfo reports $vk_devices Vulkan devices"
  elif (( vk_devices == 1 )); then
    warn "vulkaninfo reports only 1 Vulkan device"
  else
    bad "vulkaninfo found no devices -- mesa-vulkan-drivers installed?"
  fi
else
  bad "vulkaninfo not found -- install vulkan-tools and mesa-vulkan-drivers"
fi

# ── 4. Build toolchain ───────────────────────────────────────────────────────

hdr "Build toolchain"
for cmd in cmake make hipcc bun uv huggingface-cli git python3 jq curl envsubst yad notify-send; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd: $(command -v "$cmd")"
  else
    case "$cmd" in
      yad|notify-send|hipcc)
        warn "$cmd not found"
        ;;
      *)
        bad "$cmd not found (required)"
        ;;
    esac
  fi
done

if command -v python3 >/dev/null 2>&1; then
  py_v=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  if python3 -c 'import tomllib' 2>/dev/null; then
    ok "python3 $py_v includes tomllib (>= 3.11)"
  else
    bad "python3 $py_v lacks tomllib -- need 3.11 or newer (or install tomli)"
  fi
fi

if command -v bun >/dev/null 2>&1; then
  bun_v=$(bun --version 2>/dev/null)
  # Compare version to 1.3.13 lexically per major.minor.patch.
  if printf '%s\n%s\n' "1.3.13" "$bun_v" | sort -V -C; then
    ok "bun version $bun_v (>= 1.3.13)"
  else
    warn "bun version $bun_v (1.3.13+ recommended for the opencode patch build)"
  fi
fi

# ── 5. Disk space ────────────────────────────────────────────────────────────

hdr "Disk"
# Models go under /var/lib/llama-models. Check /var or /, whichever
# applies on this system.
target=/var
if [[ ! -d /var ]]; then target=/; fi
free_gb=$(df --output=avail -BG "$target" 2>/dev/null | tail -1 | tr -dc '0-9')
if (( free_gb >= 120 )); then
  ok "$target has ${free_gb} GB free (>= 120 GB recommended for default model set)"
elif (( free_gb >= 50 )); then
  warn "$target has ${free_gb} GB free; default model set is ~100 GB. Pick smaller models or free space."
else
  bad "$target has only ${free_gb} GB free"
fi

# ── 6. Repo state ────────────────────────────────────────────────────────────

hdr "Repository"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok "repo root: $REPO"

if [[ -f "$REPO/configs/workstation/models.toml" ]]; then
  ok "configs/workstation/models.toml present"
else
  if [[ -f "$REPO/configs/workstation/models.toml.example" ]]; then
    warn "configs/workstation/models.toml not found; copy from models.toml.example"
  else
    bad "neither models.toml nor models.toml.example found in configs/workstation/"
  fi
fi

if [[ -d "$REPO/Library" ]] && [[ -f "$REPO/Library/pyproject.toml" ]]; then
  ok "Library submodule populated"
else
  bad "Library submodule not populated -- run: git submodule update --init"
fi

if [[ -f "$REPO/configs/workstation/system.env.example" ]]; then
  ok "configs/workstation/system.env.example present"
else
  bad "configs/workstation/system.env.example missing"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

hdr "Summary"
echo "  passed:   $PASS"
echo "  warnings: $WARN"
echo "  failed:   $FAIL"

if (( FAIL > 0 )); then
  echo
  echo "  Hard failures above. Resolve them before running install.md."
  exit 1
fi
if (( STRICT == 1 && WARN > 0 )); then
  echo
  echo "  Strict mode: warnings count as failures. Resolve them or omit --strict."
  exit 2
fi
echo
echo "  Preflight passed. You can proceed with docs/install.md step 1."
exit 0
