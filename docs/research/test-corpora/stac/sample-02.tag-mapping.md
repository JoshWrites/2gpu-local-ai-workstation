# STAC sample-02 (592_s1_league3_game6_1) — tag mapping notes

Shorter Catan dialogue, 502 words / 105 EDUs / 108 relations.
Relation types in this sample: Acknowledgement, Background,
Clarification_question, Comment, Conditional, Continuation, Contrast,
Correction, Elaboration, Explanation, Narration, Parallel,
Question_answer_pair, Result.

## Why this sample complements sample-01

Sample-01 is a game-setup conversation (meta-chat about scheduling,
yesterday's game, weather). Sample-02 is deeper into actual
negotiation — trade proposals and counterproposals, which amplify
`Correction`, `Contrast`, and `Question_answer_pair`.

## Same mapping table as sample-01 applies

See sample-01.tag-mapping.md for the STAC-relation → our-tag
correspondence. This sample provides additional confirmation of
`Correction` (i.e. supersession) in a negotiation context rather than
the social-chat context of sample-01.

## Concrete examples

Scanning the annotations JSON, watch for:

- `Correction` edges — these are the parser's supersession signal.
- `Contrast` edges paired with adjacent `Acknowledgement` edges —
  these are concessions.
- `Question_answer_pair` with a `target` that contains `"but"` or
  `"no, but"` — concession-inside-answer.

## Notes

Use sample-01 as the primary diversity-of-relations case and
sample-02 as the negotiation-specific stress test for Correction
detection.
