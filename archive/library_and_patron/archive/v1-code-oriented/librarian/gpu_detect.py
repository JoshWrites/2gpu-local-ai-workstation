"""GPU detection and role assignment.

Queries rocm-smi at startup to find which GPU index corresponds to each card,
then resolves two logical roles:

  GPU_INFER — the large card (7900 XTX or largest VRAM) — inference + initial indexing
  GPU_EMBED — the small card (5700 XT or second-largest VRAM) — delta embeds + queries

All other modules import GPU_INFER_URL and GPU_EMBED_URL from here instead of
reading environment variables directly. This means GPU indices are never hardcoded
anywhere in the application.

Environment variables (optional overrides — set these if auto-detection is wrong):
  LIBRARIAN_INFER_GPU_INDEX  — force the inference GPU index (e.g. "1")
  LIBRARIAN_EMBED_GPU_INDEX  — force the embed GPU index (e.g. "0")
  OLLAMA_GPU_INFER_URL       — force the inference Ollama URL
  OLLAMA_GPU_EMBED_URL       — force the embed Ollama URL

Detection strategy:
  1. If both URL overrides are set, use them directly (skip rocm-smi entirely).
  2. If index overrides are set, use them to build URLs from the port map in config.
  3. Otherwise, query rocm-smi --showmeminfo vram and sort GPUs by VRAM descending.
     Largest VRAM = INFER, second-largest = EMBED.
  4. If only one GPU is found, assign it to both roles (single-GPU fallback).
  5. If rocm-smi fails entirely, fall back to defaults (port 11434=infer, 11435=embed)
     and log a prominent warning.
"""

import logging
import os
import re
import subprocess
from dataclasses import dataclass
from typing import Dict, Optional

log = logging.getLogger(__name__)

# Default port map: GPU index → Ollama port
# These are the ports configured in the systemd service files.
# Override via GPU_PORT_MAP env var is not supported — just set the URL overrides.
_DEFAULT_PORT_MAP = {
    0: 11435,   # GPU0 (typically 5700 XT) — embed
    1: 11434,   # GPU1 (typically 7900 XTX) — infer
}


@dataclass
class GPUInfo:
    index: int
    vram_bytes: int
    name: str


def _query_rocm_smi() -> Dict[int, GPUInfo]:
    """Run rocm-smi and return a dict of GPU index → GPUInfo."""
    gpus: Dict[int, GPUInfo] = {}

    # Get VRAM sizes
    try:
        result = subprocess.run(
            ["rocm-smi", "--showmeminfo", "vram", "--json"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            import json
            data = json.loads(result.stdout)
            for key, val in data.items():
                # Key format: "card0", "card1", etc. or "GPU[0]"
                m = re.search(r"(\d+)", key)
                if not m:
                    continue
                idx = int(m.group(1))
                vram = int(val.get("VRAM Total Memory (B)", 0))
                gpus[idx] = GPUInfo(index=idx, vram_bytes=vram, name="")
    except Exception:
        # JSON mode not available on all rocm-smi versions — fall back to text
        try:
            result = subprocess.run(
                ["rocm-smi", "--showmeminfo", "vram"],
                capture_output=True, text=True, timeout=10
            )
            for line in result.stdout.splitlines():
                # "GPU[0]		: VRAM Total Memory (B): 8573157376"
                m = re.match(r"GPU\[(\d+)\]\s*:.*VRAM Total Memory.*?:\s*(\d+)", line)
                if m:
                    idx = int(m.group(1))
                    vram = int(m.group(2))
                    if idx not in gpus:
                        gpus[idx] = GPUInfo(index=idx, vram_bytes=vram, name="")
                    else:
                        gpus[idx].vram_bytes = vram
        except Exception as e:
            log.warning("[GPU] rocm-smi VRAM query failed: %s", e)

    # Get product names
    try:
        result = subprocess.run(
            ["rocm-smi", "--showproductname"],
            capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.splitlines():
            # "GPU[0]		: Card Series: 		AMD Radeon RX 5700 XT"
            m = re.match(r"GPU\[(\d+)\]\s*:.*Card Series:\s*(.+)", line)
            if m:
                idx = int(m.group(1))
                name = m.group(2).strip()
                if idx in gpus:
                    gpus[idx].name = name
                else:
                    gpus[idx] = GPUInfo(index=idx, vram_bytes=0, name=name)
    except Exception as e:
        log.warning("[GPU] rocm-smi product name query failed: %s", e)

    return gpus


def _index_to_url(index: int, gpus: Dict[int, GPUInfo]) -> str:
    port = _DEFAULT_PORT_MAP.get(index)
    if port:
        return f"http://localhost:{port}"
    # Unknown index — guess a port by offset from base
    return f"http://localhost:{11434 + index}"


def detect_gpus() -> tuple[str, str]:
    """
    Detect GPU roles and return (infer_url, embed_url).

    Checks environment overrides first, then auto-detects via rocm-smi.
    Logs the final assignment clearly so operators can verify.
    """
    # --- Hard overrides: both URLs set explicitly ---
    infer_url_override = os.environ.get("OLLAMA_GPU_INFER_URL")
    embed_url_override = os.environ.get("OLLAMA_GPU_EMBED_URL")
    if infer_url_override and embed_url_override:
        log.info("[GPU] Using explicit URL overrides: infer=%s embed=%s",
                 infer_url_override, embed_url_override)
        return infer_url_override, embed_url_override

    # --- Index overrides ---
    infer_idx_override = os.environ.get("LIBRARIAN_INFER_GPU_INDEX")
    embed_idx_override = os.environ.get("LIBRARIAN_EMBED_GPU_INDEX")

    gpus = _query_rocm_smi()

    if infer_idx_override is not None and embed_idx_override is not None:
        ii = int(infer_idx_override)
        ei = int(embed_idx_override)
        infer_url = infer_url_override or _index_to_url(ii, gpus)
        embed_url = embed_url_override or _index_to_url(ei, gpus)
        infer_name = gpus.get(ii, GPUInfo(ii, 0, f"GPU[{ii}]")).name or f"GPU[{ii}]"
        embed_name = gpus.get(ei, GPUInfo(ei, 0, f"GPU[{ei}]")).name or f"GPU[{ei}]"
        log.info("[GPU] Index overrides: INFER=GPU[%d] %s @ %s | EMBED=GPU[%d] %s @ %s",
                 ii, infer_name, infer_url, ei, embed_name, embed_url)
        return infer_url, embed_url

    # --- Auto-detection by VRAM ---
    if not gpus:
        log.warning(
            "[GPU] rocm-smi returned no GPU data. "
            "Falling back to defaults (infer=:11434, embed=:11435). "
            "Set OLLAMA_GPU_INFER_URL and OLLAMA_GPU_EMBED_URL to override."
        )
        return "http://localhost:11434", "http://localhost:11435"

    sorted_gpus = sorted(gpus.values(), key=lambda g: g.vram_bytes, reverse=True)

    infer_gpu = sorted_gpus[0]
    embed_gpu = sorted_gpus[1] if len(sorted_gpus) > 1 else sorted_gpus[0]

    infer_url = infer_url_override or _index_to_url(infer_gpu.index, gpus)
    embed_url = embed_url_override or _index_to_url(embed_gpu.index, gpus)

    _log_assignment(infer_gpu, infer_url, embed_gpu, embed_url)

    if infer_gpu.index == embed_gpu.index:
        log.warning(
            "[GPU] Only one GPU detected — both roles assigned to GPU[%d]. "
            "Indexing and inference will share VRAM.",
            infer_gpu.index
        )

    return infer_url, embed_url


def _log_assignment(infer: GPUInfo, infer_url: str, embed: GPUInfo, embed_url: str):
    infer_gb = round(infer.vram_bytes / 1e9, 1)
    embed_gb = round(embed.vram_bytes / 1e9, 1)
    log.info(
        "[GPU] Role assignment:\n"
        "        INFER  GPU[%d] %-30s %5.1f GB  %s\n"
        "        EMBED  GPU[%d] %-30s %5.1f GB  %s",
        infer.index, infer.name or "unknown", infer_gb, infer_url,
        embed.index, embed.name or "unknown", embed_gb, embed_url,
    )


def verify_or_abort(infer_url: str, embed_url: str) -> bool:
    """
    Ping both Ollama instances to confirm they're reachable.
    Returns True if both respond, False otherwise.
    Logs clearly for each failure.
    """
    import httpx
    ok = True
    for label, url in [("INFER", infer_url), ("EMBED", embed_url)]:
        try:
            r = httpx.get(f"{url}/api/version", timeout=5)
            r.raise_for_status()
            version = r.json().get("version", "?")
            log.info("[GPU] %s Ollama reachable at %s (v%s)", label, url, version)
        except Exception as e:
            log.error("[GPU] %s Ollama NOT reachable at %s: %s", label, url, e)
            ok = False
    return ok
