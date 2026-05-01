# MRDA sample-01 (Bdb001, first 200 utterances) -- tag mapping notes

Meeting: four ICSI researchers discussing a proposed XML format for
linking word transcripts with phone-level alignments and annotations.

## MRDA native coverage

MRDA gives per-utterance dialogue acts at three granularities. For our
purposes the **Full** column is richest; the **General** column gives
us question/statement structure; the **Basic** column gives us S / B /
D / F / Q buckets.

## Target tags observed

- **question**: very frequent. `qy`, `qw`, `qo`, `qrr` in the General
  column. e.g. me018 "can i see it?" (qy), fe016 "what what do you do
  with say a forced alignment?" (qw).
- **directive**: weak. Line "so you should definitely" (fe016, turn
  urging me011 to the board) is directive. `co` is the relevant Full
  tag; `ad` also possible.
- **elaboration**: extensive. me011's long explanation of the XML
  schema is a series of `s`/`e` tags (General=s, Full=s or e for
  elaborations within the same speaker). fe016's restating "so that's
  saying we know it starts at this particular time" is another
  elaboration. The Full tag `e` marks elaboration explicitly.
- **concession**: present. fe016 "it's an o. instead of an i. . but
  the d. is good" (corrects me011 on a letter mnemonic while
  accepting the broader idea). `ar` (reject) or `df` (defending) sub-
  tags may surface here; the "but" is the signal.
- **contrast**: embedded in statements -- "what do you do if you just
  conceptually if you get um transcriptions where the words are
  staying but the time boundaries are changing" -- not marked as a
  separate dialogue act. Text-level only.
- **commitment**: fe016's opening "I was going to ask people to help
  with today is to give input on what kinds of database format we
  should use" is a committing of the group to a task. Not directly
  tagged; framed as `s` (statement) in General, likely `rt` (rising
  topic) in Full. me011 "I sort of already have developed an x.m.l.
  format for this sort of stuff" is another commitment. The Full tag
  `cs` (commit speaker) is not part of the standard MRDA set -- MRDA
  does not explicitly mark commitment.
- **reversal**: not in this excerpt.
- **supersession**: fe016 "it's an o. instead of an i." corrects
  me011 mid-stream -- a small supersession of a detail. Not explicitly
  tagged; `%` (interrupted) or `ar` (reject) might be the closest
  native tags.
- **aside**: me011's "i don't i don't remember exactly what my
  notation was" is an aside during a longer explanation. `df`
  (defending/digressing) or `h` (hold) is the closest; Full MRDA tag
  `co` (commentary) is a match if the annotator chose it.
- **unresolved**: this is an excerpt -- the schema-format question isn't
  closed here. Many of fe016's follow-up questions are still being
  unpacked at the end of the 200-utterance window. Present by virtue
  of truncation.

## Mapping table

| Our tag       | MRDA native (Full column)                              | Coverage  |
|---------------|--------------------------------------------------------|-----------|
| question      | qy, qw, qo, qr, qh, qrr                                | direct    |
| directive     | co (command), ad (action-directive)                    | direct    |
| elaboration   | e (elaboration), s-runs by same speaker                 | direct    |
| commitment    | not explicit; `rt` (raise topic) + `s` statement close | inferred  |
| concession    | not explicit; `aa` then `ar` or text "but"              | weak      |
| contrast      | not tagged at DA level                                  | text only |
| reversal      | not tagged                                              | absent    |
| supersession  | `%` (interrupted), `ar` (reject) as a weak signal      | weak      |
| aside         | `df`, `h`, `co` (commentary)                            | weak      |
| unresolved    | not tagged; structural via absent closing               | absent    |

## Notes

MRDA's value is **multi-party dynamics** -- floor-grabbing, back-
channels, overlapping claims -- which SwDA (two-party telephone) lacks.
For a discourse-act parser, MRDA tests whether the parser can handle
floor-holder signals (`fh`, `fg`) that don't map cleanly to RST or
PDTB taxonomies. Expect poor mapping for RST-only parsers.
