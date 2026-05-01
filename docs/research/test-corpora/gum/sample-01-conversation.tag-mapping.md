# GUM sample-01 (conversation_christmas) -- tag mapping notes

A family gift-opening conversation transcribed with discourse
structure. ~1,112 words. Multi-party dialogue (Mom, Dad, Judy,
Dan, etc.), naturalistic, full of asides and topic shifts -- the hard
case for discourse parsers.

## Target tags present

Scanning the PDTB-style gold annotations in
`sample-01-conversation.annotated.pdtb.txt`, I see:

- `Expansion.Conjunction` (many) -- multi-clause additions, typically
  text-level **elaboration** or **continuation**.
- `Expansion.Equivalence` -- "in other words" style restatements.
  Maps to **elaboration** in our taxonomy.
- `Comparison.Contrast` -- "but" and "though" linked clauses.
  Maps directly to our **contrast**.
- `Contingency.Cause.Reason` -- "cause", "because" clauses.
  Explanation / reason; does not map to any of our tags directly.
- `Contingency.Cause.Result` -- "so" clauses. Commitment-adjacent if
  the result clause is a decision.
- `Contingency.Condition.Arg1-as-cond` / `.Arg2-as-cond` -- "if"
  conditionals.
- `Contingency.Purpose.Arg2-as-goal` -- "in order to" structures.
- `Temporal.Synchronous` -- "when" clauses.
- `Hypophora` -- speaker asks and answers own question. Partial
  overlap with our **question** tag.
- `EntRel` -- entity-based coherence (anaphora-driven) without an
  explicit relation.
- `NoRel` -- annotator marked no discourse relation.

## Mapping table

| Our tag       | PDTB-3.0 sense (in GUM's gold)                              | eRST relation (from .rs4)                    |
|---------------|-------------------------------------------------------------|----------------------------------------------|
| contrast      | Comparison.Contrast                                         | adversative-contrast                         |
| concession    | Comparison.Concession, Comparison.Concession+SpeechAct      | adversative-concession                       |
| elaboration   | Expansion.Conjunction, Expansion.Equivalence, Expansion.Level-of-detail | elaboration-additional, elaboration-attribute |
| directive     | -- (not encoded at discourse-relation level)                 | -- (encoded in topic-solutionhood if paired with question) |
| question      | Hypophora + question mark; see also topic-question in RST   | topic-question                               |
| commitment    | -- (no direct PDTB sense)                                    | -- (no direct eRST relation; evaluation-comment + declarative mood approximates) |
| reversal      | -- (no direct PDTB sense)                                    | -- (no direct eRST relation)                  |
| supersession  | -- (no direct PDTB sense)                                    | -- (no direct eRST relation)                  |
| aside         | -- (not distinguished from elaboration/comment)              | evaluation-comment                           |
| unresolved    | -- (structural absence of answer / purpose / result)         | -- (structural)                               |

## Structural note: what PDTB & RST miss

Neither PDTB nor RST (including eRST) have a relation that
distinguishes **reversal** from **correction** from **supersession**.
They group all three under `adversative-contrast` / `Comparison.Contrast`
at best, and may leave within-speaker self-corrections entirely
unannotated if there's no discourse connective. This is the gap STAC
fills.

## Why conversation text matters

This sample will stress-test parsers that were trained mostly on
written news (WSJ RST-DT, WSJ PDTB). Spoken conversational text has
more `organization-phatic` ("okay", "mhm") and `EntRel` no-connective
transitions. A parser that only fires on explicit connectives will
miss most of the discourse structure here.
