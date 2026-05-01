# STAC -- Strategic Conversation Corpus (linguistic-only)

## Description

STAC (Asher, Hunter, Morey, Farah, Afantenos 2016) is a corpus of
multi-party online chat logs from games of *The Settlers of Catan*,
annotated under Segmented Discourse Representation Theory (SDRT).
Players negotiate trades, bluff, and react to game events -- the chat
alone is the "linguistic-only" version; a parallel "situated" version
also includes the non-linguistic game events as discourse units.

The corpus is (as of publication) the only SDRT-annotated corpus of
multi-party dialogue with full discourse structures (not just
adjacent-pair dialogue acts).

## Annotation format

- **EDUs** (Elementary Discourse Units): minimal units of discourse,
  each a span of one speaker's text. Each has `seg_id`, `speaker`,
  `text`, `turn_id`, `addressee`, `span_end`.
- **CDUs** (Complex Discourse Units): groups of EDUs treated as a
  single unit for relation-targeting. (Often empty in linguistic-only
  samples.)
- **Relations**: directed typed links between EDUs (or CDUs). Relation
  types in the STAC taxonomy:

  | SDRT relation            | Meaning                                         |
  |--------------------------|-------------------------------------------------|
  | Question_answer_pair     | Q -> A (direct answer)                           |
  | Q_Elab                   | question elaborating on a prior question        |
  | Clarification_question   | request for clarification                       |
  | Elaboration              | more detail on a prior EDU                      |
  | Continuation             | same-topic continuation by same or next speaker |
  | Explanation              | B explains A                                    |
  | Result                   | A causes B                                      |
  | Parallel                 | structurally parallel / analogous EDUs          |
  | Contrast                 | X but Y                                         |
  | Correction               | B corrects A (maps to our *supersession*)       |
  | Acknowledgement          | backchannel / uptake                             |
  | Conditional              | if-then                                         |
  | Alternation              | or / either                                     |
  | Narration                | sequential events                               |
  | Background               | scene-setting for a later EDU                   |
  | Comment                  | metacommentary                                   |

## Source

- Project site: <https://www.irit.fr/STAC/>
- Corpus page: <https://www.irit.fr/STAC/corpus.html>
- Paper: Asher et al. 2016 LREC -- <https://aclanthology.org/L16-1432/>

## How to reobtain

```
# JSON version (easiest to parse):
curl -LO https://www.irit.fr/STAC/stac_jsons.zip
python3 -c "import zipfile; zipfile.ZipFile('stac_jsons.zip').extractall('.')"
# yields stac_linguistic_only.json and stac_situated.json
# Each JSON: {"data_id": ..., "dialogues": [{dialogue_id, edus, cdus, relations}, ...]}

# Glozz XML version (for use with the Glozz annotation tool):
curl -LO https://www.irit.fr/STAC/stac-linguistic-2018-05-04.zip
```

## License

Creative Commons Attribution-NonCommercial-ShareAlike 4.0
(CC BY-NC-SA 4.0). Research use is explicitly permitted. Commercial
use requires permission from the STAC authors.

## Samples in this directory

- **sample-01**: dialogue **331_s1_league1_game4_1** (~754 words, 158
  EDUs, 166 relations). Three players settling into a Catan game.
  Contains every high-frequency SDRT relation (Acknowledgement,
  Alternation, Background, Clarification_question, Comment, Conditional,
  Continuation, Contrast, Correction, Elaboration, Explanation,
  Parallel, Q_Elab, Question_answer_pair, Result). Good test for
  parsers across the board.
- **sample-02**: dialogue **592_s1_league3_game6_1** (~502 words, 105
  EDUs, 108 relations). Shorter and more negotiation-heavy -- many
  trade proposals ("1 wheat for 1 clay?") and counter-proposals, with
  Correction/Contrast relations marking the bargaining back-and-forth.

Both `.annotated.json` files contain the dialogue's full SDRT structure
(edus, cdus, relations), verbatim from the corpus distribution. Each
EDU in `.clean.txt` is tagged with its `seg_id` in parens so you can
cross-reference to the relations file.
