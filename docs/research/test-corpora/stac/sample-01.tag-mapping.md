# STAC sample-01 (331_s1_league1_game4_1) -- tag mapping notes

Three-player Settlers of Catan chat. 754 words, 158 EDUs, 166
relations. Includes 15 distinct SDRT relation types.

## Target tags -- how STAC covers them

Because STAC annotates cross-EDU discourse relations directly, it
covers **more** of our target tags than dialogue-act-only corpora.

| Our tag        | STAC relation(s) / mechanism                                   | Coverage      |
|----------------|----------------------------------------------------------------|---------------|
| reversal       | no direct label, but sequences of `Correction` edges from a speaker against their own earlier EDU approximate it | weak-to-medium |
| supersession   | `Correction` relation -- the later EDU supersedes the earlier    | direct        |
| concession     | `Contrast` + `Acknowledgement` pattern (accept X, push Y)       | inferrable    |
| contrast       | `Contrast` -- exactly this                                       | direct        |
| elaboration    | `Elaboration`, `Q_Elab`                                         | direct        |
| commitment     | no direct label; trade acceptances are a context-specific case  | inferrable    |
| aside          | `Comment` (metacommentary)                                      | direct        |
| directive      | no SDRT relation tags this; observed in EDU surface text (e.g. "give me wheat") | absent at relation level |
| question       | `Question_answer_pair` source, `Clarification_question`, `Q_Elab` | direct       |
| unresolved     | any EDU that is the source of a question with no target relation = unanswered question | direct (via graph) |

## Concrete examples in sample-01

From the dialogue:

- `ljaybrad123: though technically it was yesterday` -- a classic
  **contrast** (and very likely tagged with a Contrast relation to
  gotwood4sheep's "having the best midsummer evar").
- `ljaybrad123: it fell on the 20th this year which was odd` --
  **elaboration** of the "yesterday" EDU.
- Trade proposals in the later part of the dialogue generate
  sequences of Question_answer_pair and Correction -- the negotiation
  back-and-forth that is STAC's signature.

## Why this corpus is uniquely useful

STAC is the **only** corpus we have that natively tags `Correction`
(~= supersession) and `Contrast` as first-class cross-turn discourse
relations in a multi-party dialogue setting. It will expose parsers
that don't track speaker state or that collapse rhetorical contrast
to mere semantic negation.

## Notes for the parser survey

Parsers whose native output is SDRT (e.g. Asher/Hunter-lineage
parsers, some ShARC / deep-discourse models) will map directly. RST
parsers will need rejoining -- RST's "Contrast" and "Concession"
relations overlap STAC's but aren't identical. PDTB parsers will need
to bridge from connective-based relations to the more abstract SDRT
types; PDTB's `Comparison.Contrast` <-> STAC `Contrast` is the cleanest
correspondence. Expect worst mapping for shallow dialogue-act
classifiers -- they'd miss `Correction` entirely.
