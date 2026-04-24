# SwDA — Switchboard Dialog Act Corpus

## Description

SwDA (Jurafsky, Shriberg, Biasca 1997) is the dialog-act-tagged layer on
top of the Switchboard-1 Telephone Speech Corpus. 1,155 five-minute
telephone conversations (~205K utterances, 1.4M words) between
strangers assigned a topic. Each utterance is tagged with a dialog act
from the SWBD-DAMSL tag set (≈42 labels in the standard "clustered"
version; ≈220 in the full).

## Annotation taxonomy

SWBD-DAMSL is a shallow dialog-act tagset with tags like:

| Tag  | Meaning              | Typical surface |
|------|----------------------|-----------------|
| sd   | Statement-non-opinion| "We keep our bags in the garage."|
| sv   | Statement-opinion    | "I think it's a splendid paper."|
| qw   | Wh-question          | "How do you gain your news?"|
| qy   | Yes/no question      | "Is that correct?"|
| qo   | Open-ended question  | "What kind of experience…?"|
| ad   | Action-directive     | "Hold it down a little longer."|
| aa   | Agree/accept         | "Right."|
| aap  | Accept-part          | partial agreement |
| b    | Backchannel          | "Uh-huh."|
| ba   | Appreciation         | "That's wonderful." |
| bk   | Acknowledge-answer   | "Oh, okay."|
| nn   | No answer            | "No."|
| ny   | Yes answer           | "Yeah."|
| ^h   | Hedge / floor-grabber| "Well, let's see,"|
| fc   | Conventional closing | "Good-bye."|
| ft   | Thanking             | "Thank you for calling."|
| fp   | Conventional opening | "Hi, how are you?"|
| o    | Other                | — |
| +    | Continuer            | utterance extending prior speaker's turn |

Full manual: <https://web.stanford.edu/~jurafsky/ws97/manual.august1.html>

## Source

- Project page: <https://compprag.christopherpotts.net/swda.html>
- Distribution repo: <https://github.com/cgpotts/swda>
- Underlying audio / original transcripts: LDC97S62 (LDC-licensed)
- The Potts GitHub release of the dialog-act CSV subset is the
  publicly-redistributable layer. Code is GPL-2.0. Annotation files
  themselves are distributed with the repo as `swda.zip`.

## How to reobtain

```
git clone --depth 1 https://github.com/cgpotts/swda.git
cd swda && python3 -c "import zipfile; zipfile.ZipFile('swda.zip').extractall('.')"
# per-conversation CSVs land under swda/sw??utt/sw_XXXX_YYYY.utt.csv
```

## Samples in this directory

- **sample-01**: conversation sw_0912_3267 (topic: news consumption; ~440 words of
  cleaned turn text, 110 SwDA lines). Short and conversational; strong closing
  sequence with mutual commitment to end the call.
- **sample-02**: conversation sw_0624_3557 (~1,080 words, 200+ SwDA lines).
  Longer, more opinion-rich, with several sv/sd alternations.

Both `.annotated.csv` files are verbatim copies from the SwDA distribution.
Column 5 `act_tag` is the dialog-act label. See the columns in each CSV header:

```
swda_filename, ptb_basename, conversation_no, transcript_index, act_tag,
caller, utterance_index, subutterance_index, text, pos, trees, ptb_treenumbers
```

## License note

SwDA code and annotations are GPL-2.0 per the repository's LICENSE.
The underlying Switchboard transcripts derive from LDC97S62; the SwDA
distribution is widely understood to be redistributable for research
use, which is how it has been mirrored on GitHub and Hugging Face since
~2011. For commercial use, verify separately with LDC.
