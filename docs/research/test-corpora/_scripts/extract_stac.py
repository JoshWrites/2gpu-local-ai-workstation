"""Extract a STAC dialogue as (a) clean speaker-labeled chat text and
(b) a self-contained JSON with just that dialogue's EDUs, CDUs, and
relations, preserving the original schema.
"""
import json, sys

src = sys.argv[1]
out_clean = sys.argv[2]
out_annot = sys.argv[3]
dialogue_id = sys.argv[4]

with open(src) as f:
    data = json.load(f)

target = None
for d in data['dialogues']:
    if d['dialogue_id'] == dialogue_id:
        target = d
        break
if target is None:
    print(f"Dialogue {dialogue_id} not found", file=sys.stderr)
    sys.exit(1)

# Write annotated JSON
with open(out_annot, 'w') as f:
    json.dump({
        'schema_source': 'STAC linguistic-only JSON format',
        'schema_doc': 'STAC json format.pdf (bundled with corpus)',
        'dialogue_id': target['dialogue_id'],
        'dialogue': target,
    }, f, indent=2)

# Write clean text (speaker: text), one EDU per line to preserve STAC
# segmentation (EDUs are atomic discourse units, not necessarily turns)
with open(out_clean, 'w') as f:
    f.write("# STAC (Strategic Conversation) linguistic-only corpus -- clean text\n")
    f.write(f"# Dialogue ID: {target['dialogue_id']}\n")
    f.write("# Source: https://www.irit.fr/STAC/ (CC BY-NC-SA 4.0)\n")
    f.write("# Context: chat logs from multi-player Settlers of Catan games.\n")
    f.write("# Players negotiate trades ('1 wheat for 1 clay?') and react to game events.\n")
    f.write("# Each line below is ONE STAC EDU (elementary discourse unit), tagged with\n")
    f.write("# (seg_id) at end for cross-reference to the annotated relations file.\n\n")
    current_turn = None
    for edu in target['edus']:
        turn = edu.get('turn_no', edu.get('turn_id'))
        if turn != current_turn:
            f.write('\n')
            current_turn = turn
        f.write(f"{edu['speaker']}: {edu['text']}    ({edu['seg_id']})\n")

print(f"Wrote {out_clean} and {out_annot} ({len(target['edus'])} EDUs, {len(target['relations'])} relations).")
