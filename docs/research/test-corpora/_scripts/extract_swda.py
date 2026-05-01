"""Extract clean speaker-labeled text and annotation-only view from a SwDA CSV.

Preserves original CSV untouched. Clean text collapses utterance_index
+subutterance_index runs so each "turn" is a speaker's group of
contiguous utterances, rendered verbatim from the `text` column with
SwDA disfluency markup preserved (it's part of the annotation format).
"""
import csv, sys, re, io

src = sys.argv[1]
out_clean = sys.argv[2]

rows = []
with open(src, newline='') as f:
    r = csv.DictReader(f)
    for row in r:
        rows.append(row)

# Group by (caller, utterance_index) -- that's one "turn" in the original
lines = []
current_caller = None
current_utt_idx = None
buf = []
for row in rows:
    caller = row['caller']
    utt_idx = row['utterance_index']
    text = row['text']
    if (caller, utt_idx) != (current_caller, current_utt_idx):
        if buf:
            lines.append(f"{current_caller}: " + " ".join(buf))
        buf = [text]
        current_caller = caller
        current_utt_idx = utt_idx
    else:
        buf.append(text)
if buf:
    lines.append(f"{current_caller}: " + " ".join(buf))

with open(out_clean, 'w') as f:
    f.write("# Switchboard Dialog Act Corpus: cleaned per-turn text\n")
    f.write(f"# Source CSV: {src.split('/')[-1]}\n")
    f.write("# Caller A / Caller B are two anonymous telephone participants.\n")
    f.write("# Disfluency markup ({D}, {F}, /, [, +, -, etc.) is verbatim from SwDA.\n")
    f.write("# See https://web.stanford.edu/~jurafsky/ws97/manual.august1.html for conventions.\n\n")
    for ln in lines:
        f.write(ln + "\n")

print(f"Wrote {out_clean} with {len(lines)} turns.")
