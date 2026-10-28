# TUI information, keyboard ownership and layers

Status: investigation in progress. This document separates observed terminal
behavior, source-level findings and design hypotheses. It does not establish a
best layout or a measured improvement in comprehension.

The follow-up candidate discussed below is local work in progress and is not in
the published draft head. Source review found an unresolved input race between
checking for pending input and presenting a new frame, and a missing-tail CSI
sequence can prevent the recovery notice from being displayed. Some inputs and
paste payloads can be rejected during a transition rather than preserved. These
are not terminal reproductions; the follow-up needs further design, review and
candidate-terminal verification before it can be treated as finished.

## Observed baseline

The [isolated run record](../evidence/research/tui-information-layers-2026-10-28/README.md)
binds terminal captures to an installed baseline binary, its build commit and
hash, terminal sizes and an unavailable fixture server. On that baseline:

- With hints hidden, Agenda displayed `?:help` but `?` left the frame unchanged.
- Answering accepted `?`; Esc returned to the prior Answering frame. The
  fixture was empty, so populated selection and scroll were not measured.
- Agenda's full-width bordered region occupied 21/24, 33/36 and 37/40 rows at
  80×24, 120×36 and 160×40. The remaining rows were navigation, footer and
  composer/status. These counts say how much of the surface is replaced, not
  whether the replacement is easier to understand.
- Over an isolated chat, Help ignored the two-set jamo `ㅓ`, while Latin `j`
  scrolled it one line. This observes characters sent through tmux, not a
  physical keyboard or every IME.
- About also advertised `?:help` while `?` left its frame unchanged. About's
  drawing and key priority differ from Agenda's, so it needs its own repair;
  this change does not claim the footer is correct on every overlay.

The Queue panel in PR #46617 was not present in that binary. Source inspection
of the earlier parent commit `a3c351925b09341d5051b0dc3a0a35d3508fa1c8`
found that `?` was ignored in its list and detail modes, and Hangul-to-command
admission still tested the underlying chat surface. Those are source findings
for that commit, not observations of the later candidate in a terminal.

Another source-level layer mismatch was found for paste: an asynchronously
issued Play invite card is drawn above an existing reader, but reader paste
handling preceded the card's paste guard. The change uses the last presented
card's scroll report to give that card paste ownership ahead of the reader,
without consuming a reader's paste before the card is painted. This finding
and repair have not been exercised in a candidate terminal run.

## Information scores for a queue and adjacent decision surfaces

Scores are an analyst's first-pass ordering for the described context, not
measured user importance or a permanent property of a field. Reassess when an
operator selects an item or new evidence changes its relevance. Each row is
scored on decision consequence (0–3), time sensitivity (0–3), relevance to the
current activity (0–2), and cost of missing or misreading it (0–2); sum is
0–10. Unknown and stale observations are states to expose, not zeros to hide.

| Information in context | Consequence | Time | Relevance | Miss cost | Score |
| --- | ---: | ---: | ---: | ---: | ---: |
| Workspace identity unconfirmed or a change outcome unknown | 3 | 3 | 2 | 2 | 10 |
| A question or approval waiting on the operator | 3 | 3 | 2 | 2 | 10 |
| Selected item, available action and its confirmed or failed result | 3 | 2 | 2 | 2 | 9 |
| The currently running turn that queued messages wait behind | 2 | 2 | 2 | 1 | 7 |
| Other messages waiting for this Keeper | 2 | 1 | 2 | 1 | 6 |
| A known future scheduled occurrence | 1 | 0 | 1 | 1 | 3 |
| Exact IDs and provenance before the operator asks for detail | 1 | 0 | 1 | 1 | 3 |
| Repeated explanation of a stable generic rule | 0 | 0 | 1 | 0 | 1 |

An ID can become decisive when two entries must be distinguished; a future
schedule can become urgent near its due time. The score therefore informs
placement and progressive detail, not deletion or permission. The action
receipt must remain distinguishable from a subsequent failed read.

## Keyboard and layer decisions to investigate

Use the same visible vocabulary where the actions have the same meaning:
arrows or `j/k` to move, Page Up/Down to read a page, Enter to inspect, `?`
for help and Esc to return. Availability depends on the current input owner;
a text editor or search field must retain typed text, including `?` and Hangul.
Do not infer frequency from the existence of a shortcut: no key-use telemetry
or operator timing was collected here. The [W3C dialog pattern](https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/)
is web guidance, but its focus and return behavior is a useful comparison for
terminal overlays. [Apple's keyboard guidance](https://developer.apple.com/design/human-interface-guidelines/keyboards)
also recommends preserving familiar shortcuts and limiting custom ones to
frequent actions; terminal and OS reservations still have to be checked for
the actual emulator.

| Intent | Candidate keys | What the source says |
| --- | --- | --- |
| Open this Keeper's queue | Ctrl-T, or `/queue` then Enter | One chord versus six typed characters and Enter; delivery of the chord depends on the terminal. |
| Find an item | ↑/↓ or `j/k`; Page Up/Down to browse | One key per selection step; paging and selecting are distinct actions. |
| Read an item | Enter, then Esc | Detail is a reader above the list; this count does not include reading or scrolling. |
| Change a selected item's priority | `n` or `l` | One key submits a supported action. A server message waits for the current turn; event urgency does not promise exact order. |
| Read help and return | `?`, then Esc | Queue and Agenda support is a source change, not yet observed in a candidate binary. |

These are key counts and source contracts, not measured task duration or
evidence that the shortcuts are familiar to the operator. In the candidate,
selection and any resulting action must be bound to what has actually been
presented; asynchronous reads may alter the queue between keystrokes.

The current renderer's relative order, highest first, is: compact fallback;
Play invite; account login; palette; Collab; lane add-ons; detail readers;
About; Context; Keeper deletions; Help; Queue; Agenda; Answering; patch; link;
client detail; base surface. Image and MSX handling also have a separate
terminal-ownership path. This is the source's precedence, not a usability
ranking: notably About is above Help, so adding `?` to its key handler alone
would not make Help visible. A repair must align drawing, input and return
ownership, including changes that arrive between frames.

The candidate adds the advertised help path to Agenda and the new Queue panel,
with Help above the invoking panel and Esc returning to that panel. This still
needs a candidate terminal observation. A visible command-only panel should interpret a single
two-set Hangul key as its Latin shortcut even when chat is behind it. A composed
syllable must not be replayed as several queue mutations. The text field and
resize fallback remain separate owners.

The candidate also places a change receipt before explanatory guidance and
shows only the relevant guidance for a selected server message or event. From
the shared row-budget projection, the list gains one row when neither is
selected; it gains none when that guidance is relevant. This is a source-derived
budget comparison against the parent candidate, not a terminal measurement or
a demonstrated improvement in comprehension.

### Synthetic comparison and provisional direction

The [static sketches](../evidence/research/tui-information-layers-2026-10-28/prototype/README.md)
put the same synthetic chat and 18 queue rows into three arrangements. They
are not product screens. At 80×24, the side sketch shows 15 queue rows and 12
chat rows, but clips the selected queue row and five chat rows. The bottom
sketch shows six queue rows and eight chat rows without clipping those rows;
the full sketch shows 15 queue rows and no chat. At 160×40, the side sketch
shows all 18 queue rows and 12 chat rows without clipping; the bottom shows 16
queue rows and 12 chat rows. The proportions and sample text determine these
counts, and there was no timed task or preference study.

For this fixture, a wide side panel is the strongest candidate for keeping the
conversation and queue visible together. On the narrow sketch the bottom sheet
preserves the selected text but gives up nine visible queue rows. A full reader
remains a candidate for long item detail or help. None of this establishes a
general width breakpoint, which layout communicates best, or that a layout
can safely own input while chat is visible. Compare populated interactive
implementations, including resizing, selection, key ownership and return,
before changing the common compositor or asserting a general rule.
