# SwDA sample-02 (sw_0624_3557) — tag mapping notes

Topic: AIDS research funding and Magic Johnson. ~1,080 words.
Mix of opinion exchange, factual sourcing, concession, and
topic-shifting asides.

## Target tags observed

- **question**: multiple — turn 1 B "You think about AIDS research?"
  (`qo`), turn 10 B "That's in the world, or in America?" (`qr`, or
  alternative), turn 15 B "Whose figure is that?" (`qw`),
  turn 22 A "Do you think they should spend more?" (`qy`),
  turn 24 A "What do you think, Doug, of Mister Johnson?" (`qw`).
- **directive**: absent (chit-chat register).
- **elaboration**: turn 2 A builds out "AIDS is a nasty terrible disease"
  with supporting `sd` continuations; turn 35 B elaborates on Magic
  Johnson's actions. Present.
- **concession**: turn 29 B "I think he's probably doing the right
  thing… *but* I don't think it's anything exceptional" — classic
  concessive contrast. Present and strong.
- **contrast**: turn 29 B's "but" construction; turn 11 A "although it
  is not killing that many people now, it still has the opportunity to
  get out of control". Present.
- **commitment**: turn 40 A "I'm glad that Mister Johnson's changed his
  tune on safe sex to abstinence" — an evaluative commitment, not a
  decision. Weak. No strong task-commitment (chat is open-ended).
- **reversal**: turn 40 A "I'm glad that Mister Johnson's changed his
  tune" narrates a reversal (Magic Johnson's, not the speaker's). No
  within-speaker reversal in this sample.
- **supersession**: absent.
- **aside**: turn 22 A "Sometimes you hear things on the radio that,
  you know, could be true or couldn't be" — meta-comment on sourcing.
  Mild aside. Turn 44 A "let's see. What are some of the other
  questions… I don't have any friends that have the disease" — speaker
  checks the task list, then shifts. Strong aside / topic transition.
- **unresolved**: sample ends mid-conversation ("that sort of thing,"
  at turn 53). Unresolved by design. Present.

## Mapping to SwDA native

| Our tag       | How to spot in this sample                                     |
|---------------|----------------------------------------------------------------|
| question      | Rows where `act_tag` starts with `q` (qw, qy, qo, qr, qh)     |
| directive     | `ad` (none here) or imperative `co`                            |
| elaboration   | Same-caller `sd` runs under a single `utterance_index`; `+` continuer tags |
| commitment    | `sv` ("I think / I'm glad") framing a decision or endorsement |
| concession    | `sv` containing "although" / "but" connectives, often preceded by `aa` |
| contrast      | Text-level; not tagged. Look for "but", "though", "although" in `sd`/`sv` |
| reversal      | Text-level; not tagged. Requires semantic comparison of two statements by same speaker |
| supersession  | Text-level; not tagged                                         |
| aside         | `^q` (quotation), `o` (other), or short `sd` bracketed by disfluencies |
| unresolved    | No `fc` (closing) before end of transcript; `qo`/`qy` never answered |

## Notes

This sample is **stronger than sample-01 on concession and contrast**
because it's an opinion exchange with explicit concessive structure
("although", "but not exceptional"). It's **weaker on commitment**
because nothing gets decided — it's chit-chat. It exemplifies the
**limitation of SwDA**: the "but I don't think it's anything exceptional"
in turn 29 is a single `sv` tag; the *contrast* relation to the
preceding `sv` ("doing the right thing for a man in his position") is
invisible in SwDA output. A PDTB-style parser would mark that
"Comparison.Contrast" relation. Cross-checking both parsers' output
against this sample should surface which taxonomy detects the
concessive move more reliably.
