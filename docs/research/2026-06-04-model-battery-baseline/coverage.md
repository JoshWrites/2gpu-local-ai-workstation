# Coverage analysis — pool + on-disk alternatives (2026-06-04)

## Strength coverage among the 5 pool models

| Dimension | Covered by | Gap? |
|-----------|-----------|------|
| Fast general chat | gemma, glm | well covered |
| Multilingual / RTL | gemma (strong), 80b-instruct (good) | covered |
| Code generation | coder (best), glm (strong) | covered |
| Agentic coding / file edits | coder | covered (single point) |
| Hard reasoning / math | 80b-thinking, glm (math) | covered |
| Logic puzzles | all pass; thinking strongest | covered |
| World knowledge | 80b-instruct/thinking (gemma ok) | covered; glm weak (known) |
| Long-context stability | 80b-instruct/thinking | covered |
| Tool use / RAG orchestration | 80b-instruct (best), gemma, glm | covered |
| Surfaced step-by-step reasoning | 80b-thinking | covered (single point) |

## Do strengths align, or is there an uncovered gap?

The pool is **well-aligned with no major capability hole** for text work.
Strengths overlap healthily (2+ models for most dimensions), and the two
single-point dimensions (agentic file-editing = coder; surfaced reasoning
= thinking) each have a clear owner.

### The one real gap: VISION / multimodal

No pool model accepts image input as deployed. This is the only
capability dimension with ZERO coverage. We have a runnable fix on hand:

- **gemma-4-12b is natively a vision-language model** — we simply did not
  download/wire the `mmproj` projector. Adding it would close the gap with
  a model already in the pool, with VRAM to spare (measured ~9 GB at 64K;
  vision tower adds ~1 GB). This is the highest-value coverage move.

### On-disk alternatives considered (and why not pool them now)

- **aya-expanse-8b** (multilingual, 23 langs incl. Hebrew): would deepen
  multilingual coverage, but gemma already covers it well and tested
  cleanest on Hebrew. Marginal benefit. Hold.
- **gpt-oss-120b** (60 GB on disk): larger reasoning, but 80b-thinking
  already owns hard reasoning and is faster. Hold unless thinking proves
  insufficient.
- **devstral-small-2 / qwen2.5-coder-7b**: smaller coding models;
  coder-30b dominates. No gap to fill.
- **qwen3.5-4b**: small generalist; gemma/glm faster-and-better. No gap.

## Recommendation
The pool covers text comprehensively. The single actionable coverage gap
is **vision**, closable by wiring gemma's mmproj — not by adding a new
model. Everything else is redundancy, not gap-filling.
