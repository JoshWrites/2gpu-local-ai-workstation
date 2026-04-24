"""Find SwDA files whose clean-text word count falls in a target range."""
import csv, os, glob

root = '/home/levine/Documents/Repos/Workstation/second-opinion/docs/research/test-corpora/_staging/swda-repo/swda'
candidates = []
for d in sorted(os.listdir(root))[:15]:
    dp = os.path.join(root, d)
    if not os.path.isdir(dp):
        continue
    for f in sorted(os.listdir(dp))[:50]:
        p = os.path.join(dp, f)
        words = 0
        with open(p, newline='', encoding='latin-1') as fh:
            r = csv.DictReader(fh)
            for row in r:
                words += len(row.get('text', '').split())
        if 300 <= words <= 1400:
            candidates.append((words, p))

candidates.sort()
for w, p in candidates[:30]:
    print(w, p)
