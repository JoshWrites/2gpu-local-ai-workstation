"""Ollama embedding client.

GPU_INFER (large card) — initial full repo indexing (fast, large VRAM).
GPU_EMBED (small card) — delta re-embeds and query embeds during normal operation.

URLs are resolved at import time via gpu_detect, which queries rocm-smi and
assigns roles by VRAM size rather than relying on fragile GPU index numbering.
"""

import logging
from typing import List

import ollama

log = logging.getLogger(__name__)

EMBED_MODEL = "mxbai-embed-large"
BATCH_SIZE = 16

# Resolved at import time — never hardcoded
_GPU_INFER_URL: str = ""
_GPU_EMBED_URL: str = ""


def init(infer_url: str, embed_url: str):
    """Set the Ollama URLs for each role. Called once by server.py at startup."""
    global _GPU_INFER_URL, _GPU_EMBED_URL
    _GPU_INFER_URL = infer_url
    _GPU_EMBED_URL = embed_url
    log.info("[Embed] URLs set — infer: %s  embed: %s", infer_url, embed_url)


class EmbedderError(Exception):
    pass


def _embed(texts: List[str], base_url: str, label: str) -> List[List[float]]:
    """Embed a list of texts using the Ollama instance at base_url."""
    if not base_url:
        raise EmbedderError(f"[Embed] {label}: embedder not initialised — call embedder.init() first")
    results = []
    client = ollama.Client(host=base_url)
    for i in range(0, len(texts), BATCH_SIZE):
        batch = texts[i : i + BATCH_SIZE]
        try:
            response = client.embed(model=EMBED_MODEL, input=batch)
            results.extend(response.embeddings)
            log.debug("[Embed] %s batch %d/%d done", label, i // BATCH_SIZE + 1, -(-len(texts) // BATCH_SIZE))
        except Exception as e:
            raise EmbedderError(f"[Embed] {label} failed at batch {i // BATCH_SIZE + 1}: {e}") from e
    return results


def embed_initial(texts: List[str]) -> List[List[float]]:
    """Embed texts using the inference GPU — for initial full repo indexing."""
    log.info("[Embed] Initial embed of %d texts via INFER GPU (%s)", len(texts), _GPU_INFER_URL)
    return _embed(texts, _GPU_INFER_URL, "INFER/initial")


def embed_delta(texts: List[str]) -> List[List[float]]:
    """Embed texts using the embed GPU — for delta re-embeds of changed files."""
    log.info("[Embed] Delta embed of %d texts via EMBED GPU (%s)", len(texts), _GPU_EMBED_URL)
    return _embed(texts, _GPU_EMBED_URL, "EMBED/delta")


def embed_query(text: str) -> List[float]:
    """Embed a single query string using the embed GPU."""
    log.info("[Embed] Query embed via EMBED GPU (%s)", _GPU_EMBED_URL)
    results = _embed([text], _GPU_EMBED_URL, "EMBED/query")
    return results[0]
