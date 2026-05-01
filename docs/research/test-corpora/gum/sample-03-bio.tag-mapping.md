# GUM sample-03 (bio_byron) -- tag mapping notes

Wikipedia biography of Lord Byron (edited excerpt). ~746 words.
Narrative prose with causal and temporal structure.

## Why this sample

Biographies are **narration-heavy** -- a genre underrepresented in
WSJ-trained parsers. RST's `joint-sequence` relation and PDTB's
`Temporal.Synchronous` / `Temporal.Asynchronous` senses are the
primary relation types here. It's a good test of whether a parser
over-predicts contrast/concession (as some neural models do when
overtrained on argumentative text).

## Expected distribution

| eRST relation              | Frequency in biography |
|----------------------------|------------------------|
| joint-sequence             | high                   |
| context-circumstance       | high                   |
| causal-cause, causal-result| medium                 |
| elaboration-additional     | high                   |
| elaboration-attribute      | high (descriptors for people/places) |
| adversative-contrast       | medium (narrative tension) |
| adversative-concession     | low                    |
| topic-question             | absent                 |
| attribution-positive       | medium (quoted letters) |

## Target tags mapping -- subset

Same mapping table applies as for the other GUM samples. The
**gap** this sample reveals is that our target taxonomy has no
clean slot for **temporal narration** or **biographical context**.
A retrieval-indexer that lumps these under "elaboration" will lose
chronological coherence -- exactly the failure mode flagged in
`docs/research/2026-04-24-session-as-artifact-and-temporal-retrieval-prior-art.md`
("chunking destroys chronological context").

## Takeaway

This sample is the calibration point for: "does the parser
distinguish narration from elaboration, or collapse them?" If it
collapses, the downstream indexer will need a separate
temporal-layer (as the session-state research already concluded).
