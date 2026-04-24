# SwDA sample-01 (sw_0912_3267) — tag mapping notes

## What this corpus natively tags

Per-utterance SWBD-DAMSL dialog act. One-shot: the tag describes the
communicative function of the utterance in isolation, with some
context-sensitivity (e.g. `+` = continuer of prior speaker's turn).
It does NOT tag cross-turn discourse relations (that's PDTB's job).

## Mapping to our target tags

Our target taxonomy captures things at two levels: (a) per-utterance
speech-act-ish tags (directive, question) and (b) cross-turn discourse
moves (reversal, supersession, concession, contrast, elaboration,
commitment, aside, unresolved). SwDA gives us (a) cleanly; (b) we have
to infer from tag sequences plus text.

| Our tag       | Native SwDA equivalent                                   | Coverage |
|---------------|----------------------------------------------------------|----------|
| directive     | `ad` (action-directive), `co` (command), imperative `ad` | direct |
| question      | `qw`, `qy`, `qo`, `qr`, `qh` (rhetorical)                | direct |
| elaboration   | `sd` + same-speaker continuation of a prior `sd`         | inferrable from `+` continuer + speaker change |
| commitment    | no direct tag; evidenced by `aa`+`ft`+`fc` closings following a statement of resolution | inferrable |
| concession    | `sv` with concessive connectives ("well…"), or `aa` followed by `sv` diverging | inferrable |
| contrast      | not tagged; must be detected in text ("but", "though")  | absent at dialogue-act level |
| reversal      | not tagged; inferrable when a speaker issues `sd`/`sv` that contradicts a prior `sd`/`sv` of their own | absent |
| supersession  | not tagged; cross-turn phenomenon outside DA scope       | absent |
| aside         | sometimes `o` (other), or short `sd` bracketed by disfluencies | weak |
| unresolved    | not tagged; inferrable when closing tags (`fc`) absent or topic-opening `qo` goes unresolved | absent |

## Target tags present/absent in this sample

Going through sample-01 by turn:

- **question**: turn 1 A "Wondering how you keep up on the news" → `qo`.
  Turn 4 B "How do you gain your news?" → `qo`. Strongly present.
- **directive**: none in this short exchange. Absent.
- **elaboration**: turn 7 A elaborates on "I get the WASHINGTON POST" ("and
  that is a pretty big newspaper"). Present.
- **concession**: turn 10 B "that is one of the handicaps with both T V
  and radio" after A admits news doesn't hit. Present.
- **contrast**: turn 10 A "Though I have the radio on when I go to work,
  I don't think the news usually hits" — explicit "though". Present.
- **commitment**: turn 17 A "we've resolved the issue / and that's what
  we were asked to do" — decision to end the task. Present.
- **reversal / supersession**: absent in this sample (one-shot task).
- **aside**: turn 9 A "<laughter> because I'm not going right on the hour"
  — arguably an aside explaining why radio doesn't work. Weak.
- **unresolved**: absent; sample ends with mutual closing.

## Notes for the parser survey

SwDA is the best single corpus for **question/directive/commitment** as
explicit tags. It is **not useful for contrast/reversal/supersession**
— those are discourse-relation-level, which SwDA does not encode. A
parser whose native output is PDTB-style connective senses (Contingency,
Comparison, Expansion, Temporal) will map poorly to SwDA's tagset at
face value; a parser whose output is dialogue acts will map closely.
