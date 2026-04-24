# Test Corpora for Discourse/Dialogue-Act Parser Evaluation

Assembled 2026-04-24 as part of the second-opinion project's
conversation-indexer design work.

## Purpose

This directory is a **parser-independent test set**. A sibling agent is
independently surveying candidate discourse/dialogue-act parsers; the
corpora here were selected without knowledge of which parsers are
under consideration. That separation means later parser evaluation
won't inadvertently test a parser against data it was trained on —
as long as whoever picks the parsers verifies the training-set
overlap at that point.

## Target tag set we care about

Derived from the conversation notes at
`../2026-04-24-conversation-notes-architecture-thinking.md`, these
are the discourse phenomena we expect the indexer to need to detect:

| Tag           | Rough definition                                                 |
|---------------|------------------------------------------------------------------|
| reversal      | "actually let's switch to X" — speaker reverses their own stance |
| supersession  | a later turn overrides a decision established earlier            |
| concession    | acknowledging a prior point while adjusting ("yes, but…")        |
| contrast      | X but Y                                                          |
| elaboration   | adding detail to a prior claim                                   |
| commitment    | decision being made, state changing                              |
| aside         | off-topic digression                                             |
| directive     | instruction to act                                               |
| question      | information-seeking                                              |
| unresolved    | open thread not yet closed                                       |

These are **not** taken from any parser's native taxonomy. Part of
the parser survey's job is to find parsers whose native output can
be mapped to these tags well.

## Corpora included

### `swda/` — Switchboard Dialog Act Corpus

- **Genre**: two-party telephone conversations.
- **Taxonomy**: SWBD-DAMSL (~42 dialog acts per utterance).
- **Strong for**: question, directive, commitment (via closing
  sequences); utterance-level dialogue-act classification.
- **Weak for**: reversal, supersession, contrast (these are cross-
  turn relations that SwDA does not encode).
- **Access**: free (GPL-2.0 code, corpus redistributable for
  research use).

### `mrda/` — ICSI Meeting Recorder Dialogue Act Corpus

- **Genre**: multi-party naturalistic meetings (3–10+ speakers).
- **Taxonomy**: MRDA (≈52 fine tags) extending SWBD-DAMSL with
  multi-party-specific tags (floor-holder, floor-grabber,
  back-channel).
- **Strong for**: question, directive, elaboration, multi-party
  floor dynamics.
- **Weak for**: reversal, supersession, commitment (implicit only),
  contrast (text-level only).
- **Access**: processed text free via NathanDuran/MRDA-Corpus
  (GPL-3.0); underlying audio free for research via AMI/ICSI.

### `stac/` — Strategic Conversation (Settlers of Catan)

- **Genre**: multi-party online chat during competitive game-play
  (negotiation).
- **Taxonomy**: SDRT (Segmented Discourse Representation Theory),
  with per-EDU discourse relations (Contrast, Correction,
  Question_answer_pair, etc.).
- **Strong for**: contrast, supersession (Correction relation),
  question/answer pairing, concession (Contrast + Acknowledgement
  pattern), elaboration.
- **Weak for**: directive (negotiation uses offers, not direct
  commands), commitment (trade acceptance is game-specific).
- **Access**: free under CC BY-NC-SA 4.0 for research use.

### `gum/` — Georgetown University Multilayer Corpus

- **Genres**: academic prose, biography, and face-to-face
  conversation (three samples).
- **Taxonomy**: BOTH eRST (enhanced RST, ~32 relations) AND GDTB
  (PDTB 3.0-style connective + sense) on the same texts.
- **Strong for**: contrast, concession, elaboration (in all three
  samples); narration (biography); academic argumentation
  (academic).
- **Weak for**: reversal, supersession, commitment (PDTB/RST do not
  encode these).
- **Access**: free; annotations CC BY 4.0, texts various CC variants.

## Corpora considered but NOT included

- **RST-DT** (Rhetorical Structure Theory Discourse Treebank;
  LDC2002T07) — the canonical WSJ-article RST corpus, but LDC-
  licensed (not freely redistributable). Users with an LDC account
  can obtain it from
  <https://catalog.ldc.upenn.edu/LDC2002T07>. The GUM eRST samples
  here use the same RST framework and are freely available; they
  provide an equivalent test surface without the license friction.
- **PDTB** (LDC2008T05, LDC2019T05) — likewise LDC-licensed. The
  GDTB annotations in `gum/` provide PDTB-3.0-compatible relations
  in a freely-redistributable form.
- **LongMemEval / LoCoMo** — these are long-conversation QA
  benchmarks referenced in our Pattern 1 research, but they don't
  carry discourse-relation annotations. They're valuable for
  retrieval evaluation, not for parser-evaluation.

## Known gaps in our target-tag coverage

Comparing the 10 target tags against the four corpora:

| Target tag    | SwDA     | MRDA     | STAC                     | GUM (eRST+GDTB)       |
|---------------|----------|----------|--------------------------|-----------------------|
| reversal      | absent   | absent   | weak (via self-Correction)| absent                |
| supersession  | absent   | weak     | direct (Correction)       | absent                |
| concession    | inferable| weak     | inferable (Contrast+Ack)  | direct (adversative-concession / Comparison.Concession) |
| contrast      | text only| text only| direct (Contrast)         | direct (adversative-contrast / Comparison.Contrast) |
| elaboration   | inferable| direct   | direct (Elaboration)      | direct                |
| commitment    | inferable| inferable| inferable (trade accept)  | absent                |
| aside         | weak     | weak     | direct (Comment)          | partial (evaluation-comment) |
| directive     | direct   | direct   | absent                    | absent                |
| question      | direct   | direct   | direct                    | direct (topic-question, Hypophora) |
| unresolved    | absent   | absent   | structural (unanswered Q) | absent (structural)   |

### Biggest gaps

1. **reversal** — no corpus we found tags it directly. STAC's
   `Correction` is the closest single-label proxy when a speaker
   corrects themselves. Parsers likely will need **two-stage**
   detection: first flag a candidate Correction / Contrast /
   Comparison; then check speaker identity to distinguish reversal
   (self) from supersession (other) from correction (other, small).
2. **commitment** — no discourse theory we surveyed has a first-class
   "commitment" relation. The closest signals are modality
   (declarative + future/decision verbs), speech-act tags, or
   downstream "action-taken" annotations (not present in any of the
   above corpora). Expect to need a supplementary classifier here.
3. **unresolved** — structural, not a tag. Detectable only by graph
   traversal of the SDRT-style annotations (STAC) or by checking for
   question EDUs without a Question_answer_pair target.

## Instructions for obtaining licensed corpora (if later needed)

- **RST-DT**: <https://catalog.ldc.upenn.edu/LDC2002T07> — LDC
  membership or per-corpus license (~$300 research tier at time of
  writing).
- **PDTB 3.0**: <https://catalog.ldc.upenn.edu/LDC2019T05> — same.
- **Switchboard audio** (for prosodic features): LDC97S62 —
  <https://catalog.ldc.upenn.edu/LDC97S62>.
- **ICSI Meeting audio**: free for research with registration at
  <http://groups.inf.ed.ac.uk/ami/icsi/download/>.

## Regenerating samples

Each corpus directory's `source.md` documents the re-obtaining
commands. Helper scripts used to slice samples from the full source
repos are in `_scripts/`. To regenerate any sample from scratch,
re-run the relevant clone/download from `source.md`, then run the
matching `_scripts/extract_*.py`. The full source repos are NOT
retained in this directory (they total ~1.2 GB); only the samples
and the scripts needed to recreate them.
