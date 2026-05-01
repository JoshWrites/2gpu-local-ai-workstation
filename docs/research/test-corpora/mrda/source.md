# MRDA -- ICSI Meeting Recorder Dialogue Act Corpus

## Description

Shriberg, Dhillon, Bhagat, Ang, Carvey (2004). 75 naturally-occurring
research-group meetings recorded at ICSI (International Computer
Science Institute), ~72 hours of audio, 53 unique speakers, ~180K
hand-annotated dialog-act tags plus adjacency-pair annotations.
Multi-party: each meeting has ~5-10 participants. Most annotated
meetings are research discussions of speech processing and dialogue
system research.

## Annotation taxonomy

MRDA uses a variation of SWBD-DAMSL but expanded for multi-party
meeting-style interaction. The processed version (NathanDuran) exposes
three tag levels per utterance:

- **Basic** (5 labels): S (Statement), B (BackChannel), D (Disruption),
  F (FloorGrabber), Q (Question)
- **General** (12 labels): s, b, fh (floor holder), qy (yes-no), qw
  (wh-question), qrr (or-clause), qh (rhetorical), qo (open-ended),
  qr (or-question), h (hold), fg (floor grabber), % (interrupted)
- **Full** (~52 labels): adds sub-types like `fg`, `fh`, `bk`
  (acknowledge-answer), `aa` (accept), `ar` (reject), `co` (command),
  `na` (affirmative non-yes), `ng` (negative non-no), `ad`
  (action-directive), `rt` (rising tone), `df` (defending),
  `e` (elaboration), `nd` (narrative description), `m` (mimic), etc.

Full manual: `mrda_manual.pdf` inside the NathanDuran repo.

## Source

- Processing utilities (GPL-3.0): <https://github.com/NathanDuran/MRDA-Corpus>
- Underlying audio/transcripts: <http://groups.inf.ed.ac.uk/ami/icsi/download/>
  (free for research with registration)
- Original paper: <https://aclanthology.org/W04-2319/>

## How to reobtain

```
git clone --depth 1 https://github.com/NathanDuran/MRDA-Corpus.git
# processed per-meeting files land under mrda_data/{train,test,val}/*.txt
# format: speaker|utterance|BasicDA|GeneralDA|FullDA   (pipe-delimited)
```

## Samples in this directory

- **sample-01**: First 200 utterances of meeting **Bdb001** (~1,500 words
  of cleaned text). A discussion among four participants (fe016, me011,
  me018, mn017) about a proposed XML format for meeting transcript
  annotation -- timeline references, utterance IDs, and how forced-
  alignment output maps into the format. The first speaker (fe016) has
  a stated goal ("main thing I was going to ask people to help with
  today is to give input on what kinds of database format we should
  use"); me011 walks through an existing proposal; the others ask
  clarifying questions and push back. Good mix of proposals,
  clarifications, concessions, and collaborative elaboration.

## License note

MRDA tooling is GPL-3.0. The underlying ICSI meetings are freely
available for research use through the Edinburgh mirror; refer to the
AMI/ICSI terms at the link above for commercial use.
