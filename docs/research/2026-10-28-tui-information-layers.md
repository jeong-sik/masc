# TUI information, keyboard ownership and layers

Status: investigation in progress. This document separates observed terminal
behavior, source-level findings and design hypotheses. It does not establish a
best layout or a measured improvement in comprehension.

The follow-up candidate discussed below has been source-reviewed but has not
been built or observed in a terminal. It uses a post-presentation input barrier
to address a discovered transition race and presents recovery guidance for a
missing-tail control sequence. Some input and paste payloads can be rejected
during a transition rather than preserved. Terminal input and output remain
non-atomic, and the follow-up needs candidate-terminal verification before its
behavior can be treated as established.

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
for that commit. A subsequent [isolated candidate observation](../evidence/research/tui-information-layers-2026-10-28/populated-fixture/candidate-2732143/README.md)
of `2732143dfeac5d8a33de2e7e4ac6b9042b328ff6` confirmed that `?` did not change
the selected Queue frame; it did not measure the later local follow-up.

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

### Proposed layer combination

This ordering is a design hypothesis based on the scores above, not a result of
the static sketches or an operator preference study. A layer may display a
new fact without automatically taking input from the active editor.

| Layer or event | Proposed treatment | Reason |
| --- | --- | --- |
| Terminal recovery or an invalidated viewport | Own input until the display is usable or the operator exits | Hidden controls must not act; recovery instructions must remain visible. |
| Active text input and an explicitly opened decision | Keep the current input owner; show newly arrived questions or invites as a visible pending action | A high-importance arrival must be discoverable without redirecting a partially entered answer. |
| Help or item detail opened by the operator | Place above its parent; Esc returns to the same selection and scroll | The parent supplies the context of the explanation. |
| Queue list | Keep selected item, available action, result and read/identity status together; retain surrounding chat when it fits | These facts jointly explain what an action will affect and whether it worked. |
| Other waiting items, future schedules and exact identifiers | Show the list first and provide IDs and longer context on demand | Their relevance rises when selected; they need not displace an error or action result. |

For an asynchronously issued invite, a possible alternative to raising a modal
over active typing is a persistent notice with an explicit action to open the
retained card. That changes the existing interaction and has not been
implemented or tested here. It must keep the one-time link available and avoid
putting it in the notice or history. Likewise, an approval can be urgent without
making the answer field behind it silently lose typed characters.

### Unfinished input-ownership boundary

The follow-up groups the previously separate presented approval, hit zones,
panes and reader into one immutable snapshot. It rechecks input after output and
holds input already observed at that boundary before dispatching the next
owner's handlers. Rejected-input feedback now shares the existing mutable
notice slot with ordinary feedback as an immutable value. It stays pending
through later ordinary notices and input until a complete, identity-bound
notice reaches a successfully flushed frame. A rejected paste is not retained,
and a flush does not prove that a person saw the notice.

The follow-up gives Queue and supported Keeper chat their own notice space in
an existing border or padding row, leaving the footer and its confirmation
intact. A [manual observation of source 234b647](../evidence/research/tui-information-layers-2026-10-28/populated-fixture/candidate-234b647/README.md)
showed a rejected paste in each location in an isolated fixture; it is not proof
of every timing or terminal. Elsewhere, existing action and form/save feedback
keep priority so a pending retry or Ctrl-C recovery hint can remain out of view
even at a normal width. A one-off observation of the actual footer fitter with dependency
stubs found that, at 80 columns, a workspace-unconfirmed warning, Config's
Enter/Esc keys and a `/hello` search prefix leave no room for either complete
hint when offered. Unsupported chat, external image/MSX screens and very narrow
Queue widths also remain outside the separate-row coverage. If a displayed
notice is hidden immediately before its timeout but the next observation is
after it, the state transition cannot determine which event happened first.

A separate source review found an existing chat row-budget discrepancy: with
a folded turn, full tool visibility and pending gate effects, the budget omits
the gate row while the renderer draws it. That can push the footer past the
frame. This predates the separate-row change and was not reproduced in the
terminal fixture; it remains outside the evidence for this follow-up.

Another source-only concern predating the Help repair is that an asynchronous
Lane declaration editor handoff can open over a displayed Play card. It was
not reproduced in the terminal fixture and is not settled by the Help fix.

Input can still arrive after the post-output observation, and the terminal does
not report when the person saw the new frame. A late tail after a forced CSI
cancel also cannot be identified with certainty. These limits are distinct
from the source-level race the barrier addresses. Manual verification should
exercise queue close and Enter, selection and priority, a Play response during
typing, resize with a truncated sequence, and incomplete-paste recovery in an
isolated workspace.

To avoid opening a MIDI editor while terminal input is pending, the existing
pending-editor cancellation also applies during these transitions. The input
reader can conservatively treat a terminal protocol reply as pending input, so
it can cancel that open even without a decoded operator key. The cancellation
is recorded in chat and a bounded session event; immediate footer visibility
is not guaranteed.

### Synthetic comparison and provisional direction

The full-screen candidate was also measured against the populated fixture:
at 80×24, 10 of 18 waiting events were visible and all ten event lines were
truncated; at 120×36 and 160×40 all 18 were visible without event-line
truncation. The frame replaced the chat body at every measured size. These
observations use the real candidate binary, while the side and bottom
comparisons below are static sketches and do not have the same renderer.

The later [ab94e60 candidate observation](../evidence/research/tui-information-layers-2026-10-28/populated-fixture/candidate-ab94e60/README.md)
confirmed Queue Help and selection restoration, a literal Hangul key in Help,
detail, a read-only priority refusal, a rejected paste notice and retained chat
draft in the synthetic terminal. It does not cover the subsequent separate-row
change, successful server reordering or physical IME input.

The same candidate also exposed a negative ownership case: a synthetic paste
sent to Help over chat changed the underlying chat draft, while Help over Queue
rejected it. The later `234b647` candidate reproduced the Help-over-chat case.
The captures record the composer summary while Help was open and the retained
draft after Help closed. A subsequent source change gives Help a presented-frame
owner and rejects paste or transition input before it reaches the covered
surface; focused state and source-extraction probes passed. These are pre-fix
terminal observations, not evidence that the later change works in a terminal.

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
