import json, sys

with open('/home/levine/Documents/Repos/Workstation/second-opinion/docs/research/test-corpora/_staging/stac_jsons/stac_jsons/stac_linguistic_only.json') as f:
    data = json.load(f)


def score(d):
    edus = d.get('edus', [])
    rels = d.get('relations', [])
    rtypes = set(r.get('type', '') for r in rels)
    want = {'Contrast', 'Result', 'Correction', 'Q-Elab', 'Alternation',
            'Conditional', 'Commentary', 'Continuation', 'Acknowledgement',
            'Question-answer_pair', 'Elaboration', 'Explanation', 'Parallel'}
    coverage = len(rtypes & want)
    words = sum(len(e.get('text', '').split()) for e in edus)
    return (coverage, words, len(edus), len(rels), d['dialogue_id'], sorted(rtypes))


scored = [score(d) for d in data['dialogues']]
# Filter to dialogues in the 200-1500 word range
scored = [s for s in scored if 180 <= s[1] <= 1500]
scored.sort(reverse=True)
for s in scored[:15]:
    print(s)
