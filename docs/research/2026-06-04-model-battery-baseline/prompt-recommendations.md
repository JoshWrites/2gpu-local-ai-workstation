# Per-model prompt improvement targets (from round-1 baseline)

Ranked by evidence strength. These are hypotheses for the overnight
automode tuning pass; the baseline above is what to measure against.

## 1. coder — tool discipline (HIGHEST VALUE, clearest evidence)
The coder is the only model with a tool-use problem, and it has TWO
opposite failure modes:
- **Over-acts:** asked to "write a function," it called the `write` tool
  to create a file (rejected by the non-interactive harness). In an
  interactive Zed session this would silently create files the user did
  not ask for.
- **Under-acts:** on the read-a-file task it narrated "First, I need to
  read this file" but never emitted the tool call.

Prompt fix to test: add explicit tool-use guidance —
"When asked to produce code, output it inline in your reply unless the
user explicitly asks you to create or edit a file. When you need
information from a file or the web, CALL the tool — do not describe the
call you intend to make."

## 2. coder + thinking — multilingual degradation (MEDIUM)
Both showed minor RTL/Hebrew degradation (truncated/garbled tokens).
Their prompts could add: "For non-English output, prefer to defer to
gemma-4-12b; if you must translate, double-check non-Latin scripts."
Lower value — they already suggest switching, and translation is not
their lane.

## 3. thinking — speed-awareness on tool tasks (MEDIUM)
Tool tasks on the thinking model were very slow (66-80s) partly because
it reasons about every tool result. Prompt could add: "For routine tool
calls (file reads, lookups), do not deliberate on the result — report it
directly." Test whether this cuts tool-task latency without hurting the
hard-reasoning quality that justifies the model.

## 4. gemma — research-result skepticism (LOW)
On the thin-source research task, gemma synthesized a plausible-sounding
answer where coder/thinking flagged uncertainty. Gemma's confident
answer was arguably LESS honest. Consider adding: "When library_research
returns thin or low-confidence results, say so rather than synthesizing a
confident answer." (Trade-off: may make it more hedgy.)

## 5. glm — the card says English/Chinese-only but it did Hebrew fine
NOT a prompt change — a note. GLM's real multilingual ability exceeds its
card. Do not add a false "you only speak English/Chinese" limitation to
its prompt; observed behavior contradicts the card.

## What NOT to change
- Reasoning modulation (gemma): already working — trivial tasks fast,
  hard tasks correct. Leave it.
- Self-routing (all): working, including spontaneously on the thinking
  model. Leave the structure; only tune wording if it nags.
