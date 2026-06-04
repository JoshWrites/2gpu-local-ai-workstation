#!/usr/bin/env bash
# Run the full battery against whatever model is currently loaded + active
# in opencode.json. Saves raw outputs to /tmp/battery/results/<model>/.
# Each task runs through `opencode run` so the real Library MCP tool path
# is exercised.
set -uo pipefail
cd /home/levine/Documents/Repos/2gpu-local-ai-workstation

MODEL="$(jq -r '.model' ~/.config/opencode/opencode.json | sed 's|llama-primary/||')"
OUT="/tmp/battery/results/${MODEL}"
mkdir -p "$OUT"
echo "=== BATTERY for ${MODEL} ===" | tee "$OUT/_summary.txt"

# task id | prompt
run_task() {
  local id="$1"; shift
  local prompt="$1"; shift
  local t0 t1 dt
  t0=$(date +%s.%N)
  # --- run through opencode (real tool path), capture everything
  printf '%s' "$prompt" | timeout 240 opencode run > "$OUT/${id}.out" 2>"$OUT/${id}.err"
  local rc=$?
  t1=$(date +%s.%N)
  dt=$(echo "$t1 - $t0" | bc)
  local chars; chars=$(wc -c < "$OUT/${id}.out" | tr -d ' ')
  printf "%-18s rc=%s wall=%5.1fs out=%sB\n" "$id" "$rc" "$dt" "$chars" | tee -a "$OUT/_summary.txt"
}

# 1. MULTILINGUAL / RTL
run_task "01-hebrew" "Translate to Hebrew, output only the Hebrew: 'The new server has two graphics cards and runs very fast.'"
# 2. MULTILINGUAL spread
run_task "02-multiling" "Translate 'Where is the train station?' into French, Japanese, Arabic, and Russian. One line each, label the language."
# 3. CODE GENERATION
run_task "03-code-gen" "Write a Python function rate_limit(max_calls, period_seconds) as a decorator that limits how often the wrapped function can be called. Code only, no explanation."
# 4. CODE DEBUG
run_task "04-code-debug" "This Python is buggy: 'def avg(xs):\n    return sum(xs)/len(xs)'. It crashes on empty input. Give the corrected function only."
# 5. HARD MATH
run_task "05-math" "If 3 machines make 3 widgets in 3 minutes, how long do 100 machines take to make 100 widgets? Give the number and one line of reasoning."
# 6. LOGIC PUZZLE
run_task "06-logic" "A man looks at a portrait. 'Brothers and sisters I have none, but this man's father is my father's son.' Who is in the portrait? Answer and brief why."
# 7. GENERAL WORLD KNOWLEDGE
run_task "07-knowledge" "Name the three classical branches of government and one check each branch holds over another. Be concise."
# 8. REASONING MODULATION (should be FAST/direct for a well-tuned model)
run_task "08-trivial" "What is the capital of Australia?"
# 9. TOOL USE - real Library research
run_task "09-tool-research" "Use the library to research: what is llama.cpp's --n-cpu-moe flag for? Summarize in two sentences."
# 10. TOOL USE - real Library file read (a known repo file)
run_task "10-tool-file" "Use the library to read configs/workstation/llama-router.ini and tell me what reasoning-format the gemma-4-12b section uses."
# 11. INSTRUCTION FOLLOWING / FORMATTING
run_task "11-format" "List exactly 4 prime numbers between 10 and 30, as a JSON array of integers. Output only the JSON."
# 12. LONG-ish CONTEXT + SUMMARY
run_task "12-summarize" "Summarize in exactly one sentence: 'The mitochondrion is a double-membrane-bound organelle found in most eukaryotic cells. It generates most of the cell's supply of ATP, used as a source of chemical energy. Mitochondria have their own DNA and ribosomes, supporting the endosymbiotic theory of their origin.'"

echo "=== DONE ${MODEL} ===" | tee -a "$OUT/_summary.txt"
