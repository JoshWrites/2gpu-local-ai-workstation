# Cross-pool guide: what to use for which task (2026-06-04)

The 4-model pool, run through ~14 real-use-case dimensions (single- and
multi-turn) via real opencode + Library, on the actual hardware (7900 XTX
+ 5700 XT, llama.cpp b9518). Speeds are wall-clock through opencode incl.
any tool round-trips. Quality is rubric-judged from saved raw outputs
(under `raw/`-style `xpool/<model>/`).

## Speed at a glance (wall-clock seconds, representative tasks)

| task | gemma | glm | 80b-instruct | 80b-thinking |
|------|------:|----:|-------------:|-------------:|
| format/extract (quick) |  2-3 |  3-5 |  3-4 | 12-24 |
| coding (inline)        |  3   |  8   |  4   | 45 |
| quick chat             |  9   |  3.5 |  4   | 18 |
| writing (80 words)     | 90   |  4   |  5   | 90 |
| creativity (poem)      | 32   | 27   | (164*) | 156 |
| decision/advice        | 31   |  9   |  6   | 98 |
| research (1 tool call) | 19   | 18   | 41   | 48 |
| shopping advise (turn) | 32-55| 28-86| 4-6  | 70-99 |
| D&D opening scene      | 90   |  6.6 | 7.6  | 210 |
| long-doc summarize     | 11   | 15   | 12   | 83 |

`*` instruct's 164s creativity was a one-off long generation; its other
creative tasks (D&D 7.6s) were fast. gemma's writing/creative slowness is
systematic (its thinking channel deliberates on open-ended prompts).

**Headline speed pattern:** 80b-instruct is the surprise — non-thinking,
so it is FAST (3-7s) on most tasks despite being 80B, only slow when it
chooses to generate a lot. gemma is fastest on short/structured tasks but
SLOW on open-ended writing/creative (thinking tax). glm is consistently
quick. 80b-thinking is slowest on everything (often 1-3 min) — it thinks
on every task.

## What to use for which task

| Task | Best pick | Why | Avoid |
|------|-----------|-----|-------|
| **Quick factual / chat** | glm or gemma | both ~3-9s, correct | thinking (18s+ for a one-liner) |
| **Format-following / JSON extract** | gemma | fastest (2-3s), exact | thinking (slow, over-thinks) |
| **Coding (inline snippets)** | glm | fast, correct, often thread-safe | — (all 4 are correct; thinking is just slow) |
| **Agentic coding (read/edit/test)** | glm | only model whose tool calls parse + drive edits | the others (gemma ok for small, 80bs slow) |
| **Writing (notes, emails, prose)** | glm or instruct | concise, natural, fast (4-5s) | gemma (good but ~90s), thinking (~90s) |
| **Creativity (poems, flavor)** | instruct or gemma | instruct best prose + usually fast; gemma evocative | thinking (best-ish but 2.5 min) |
| **Brainstorming** | glm or instruct | fast, distinct ideas | thinking (slow, not better) |
| **Research (single lookup)** | glm or gemma | fast + accurate; gemma most honest about gaps | — |
| **Research-check-recommend** | **80b-thinking** | most nuanced, catches the *right* risk; instruct a fast 2nd | glm (over-confident, fabricates precise stats) |
| **Decision / tradeoff advice** | **80b-instruct** | accurate (knows 80B-fits-24GB), fast, well-reasoned | gemma (got the hardware facts WRONG) |
| **Shopping advise (multi-turn)** | instruct | held context, revised correctly, FAST (4-6s/turn) | thinking (slow), gemma (slow on long answers) |
| **D&D / creative roleplay** | instruct | excellent atmospheric prose AND fast (7.6s) | thinking (210s/turn — unusable pace), glm (degrades past ~30K ctx in a long campaign) |
| **Long-document summarize/compare** | instruct or gemma | accurate, ~11-12s; both stable on long ctx | thinking (83s), glm past ~30K tokens |
| **Anything with an image** | **gemma** | only model that can see (the others can't) | n/a — gemma is the only option |
| **Hardest reasoning / proofs** | **80b-thinking** | depth is real and correct; worth the wait | — (this is the one place its slowness pays off) |
| **Multilingual / Hebrew/RTL** | gemma | cleanest; instruct also good | glm/coder weaker scripts |

## Per-model one-liners (what to expect)

- **gemma-4-12b** — the everyday default + the only eyes. Fast on short/
  structured/multilingual, has vision, honest about research gaps. BUT
  over-thinks open-ended writing/creative (slow), and got a
  hardware-decision fact wrong (doesn't fully know its own stack).
- **glm-4.7-flash** — the quick coder/agent. Fast, concise, tool calls
  work, strong code. Watch: occasionally over-confident, will state
  suspiciously precise stats that may be fabricated; degrades past ~30K
  context (bad for long campaigns/sessions).
- **qwen3-next-80b-instruct** — the dark-horse all-rounder. Non-thinking
  so it's FAST (3-7s) despite 80B, accurate (best on the stack-decision),
  excellent prose, held multi-turn context. The best default for
  writing, advice, shopping, and D&D. Slow only to load (~200s) and the
  occasional long generation.
- **qwen3-next-80b-thinking** — the specialist. Highest quality on the
  hardest reasoning and on research-check-recommend (catches the right
  risks). But slow on EVERYTHING (1-3 min/task) — only reach for it when
  depth matters more than time.

## Accuracy / honesty notes (research integrity)
- **Most honest about gaps:** gemma (says "sources don't cover it").
- **Most nuanced-correct:** 80b-thinking (right risks, cites env docs).
- **Watch glm:** twice produced confident, very specific numbers
  ("30× faster, 1.2 GB/s") that read like fabrication rather than sourced
  fact — trust but verify its quantitative claims.
- **Best factual recall on the stack itself:** 80b-instruct (knew the
  80B-in-24GB MoE-offload fact the others got wrong or vague).

## Practical default
For most day-to-day work, **glm** (fast, coding, quick turns) and
**80b-instruct** (writing, advice, multi-turn, creative — surprisingly
fast) cover the bulk. Reach for **gemma** when you need images or
multilingual, and **80b-thinking** only when a problem is genuinely hard
and you'll wait for it.
