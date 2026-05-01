"""Extract an MRDA excerpt: N contiguous utterances with annotations,
plus a clean-text view (speaker + text only).

Input is MRDA's plain-text format:
  speaker|utterance text|Basic|General|Full
"""
import sys

src = sys.argv[1]
out_annot = sys.argv[2]
out_clean = sys.argv[3]
n_lines = int(sys.argv[4])

with open(src) as f:
    all_lines = [ln.rstrip('\n') for ln in f if ln.strip()]

# start at line 0, take n_lines
excerpt = all_lines[:n_lines]

with open(out_annot, 'w') as f:
    f.write("# MRDA (ICSI Meeting Recorder Dialogue Act Corpus) excerpt\n")
    f.write(f"# Source file: {src.split('/')[-1]}\n")
    f.write("# Format: speaker|utterance|BasicDA|GeneralDA|FullDA\n")
    f.write("# BasicDA in {S,B,D,F,Q} (Statement, BackChannel, Disruption, FloorGrabber, Question)\n")
    f.write("# See mrda_manual.pdf in NathanDuran/MRDA-Corpus for full DA taxonomy.\n")
    f.write("#\n")
    for line in excerpt:
        f.write(line + '\n')

# Clean text: speaker + utterance
with open(out_clean, 'w') as f:
    f.write("# MRDA (ICSI Meeting Recorder Dialogue Act Corpus) excerpt -- clean text\n")
    f.write(f"# Source file: {src.split('/')[-1]}\n")
    f.write("# Speakers: fe### = female, me### = male, with numeric ID.\n")
    f.write("# This is a naturalistic meeting transcript; disfluencies are minimally scrubbed.\n\n")
    last_speaker = None
    buf = []
    for line in excerpt:
        parts = line.split('|')
        if len(parts) < 5:
            continue
        speaker, text = parts[0], parts[1]
        if speaker != last_speaker:
            if buf:
                f.write(f"{last_speaker}: " + " ".join(buf) + "\n")
            buf = [text]
            last_speaker = speaker
        else:
            buf.append(text)
    if buf:
        f.write(f"{last_speaker}: " + " ".join(buf) + "\n")

print(f"Wrote {out_annot} and {out_clean} ({len(excerpt)} utterances).")
