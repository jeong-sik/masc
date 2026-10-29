# Queue layout comparison: candidate and observation protocol

Status: final source compiled and manually observed with synthetic data;
conditional placement revised from actual same-data comparisons.
This follows the
[information-priority study](2026-10-29-tui-panel-input-observation.md) and
[retained baseline observations](../evidence/research/tui-panel-input-2026-10-29/README.md).
The candidate is [PR #46699](https://github.com/jeong-sik/masc/pull/46699), above
the separate Queue panel and common input-ownership repairs.

## The candidate

The open Queue retains keyboard ownership. Its conversation preview uses the
same Keeper, chat projection, source-pin mapping and wrapping as chat, without
writing the chat's draft, scroll or pin. A shorter preview does not promise to
show every source row surrounding a pin. History/memory/older-page read errors
and omitted rows are summarized in the preview caption; loading is a
different state. Full chat still owns detailed tool-evidence diagnostics.

| Placement | Condition | Tradeoff to observe |
| --- | --- | --- |
| Side | Both panes can retain twice chat's existing hard minimum width | Retain conversation and Queue height; narrower item text may need detail. |
| Bottom | Side does not fit, but all Queue items and reserved fixed facts fit below caption + three conversation rows + divider | Spend otherwise unused rows on context; never add narrow-list scrolling merely to show the preview. |
| Full | The documents cannot both fit, Queue is explicitly expanded, or an item is opened | More space for Queue/detail; the conversation is covered until returning. |

The width minimum uses the existing chat fallback width rather than an arbitrary
80/120-column breakpoint. Twice that fallback is an initial reading-space
policy to evaluate, not a measured optimal width. Placement reserves the
possible receipt and selected-action note, so selecting an item or receiving
a result does not make the preview appear/disappear. Actual list height still
uses the facts currently displayed. Both key handling and rendering use that
remaining height.

`f` changes the preference between automatic layout and a full reader. Its
labels are `prefer full` and `allow context`; the title appends the preference
after the Keeper name so it does not displace the target. That suffix can be
clipped; narrow/hints-off footers can require Help to inspect the command.
Allowing context does not force it into a viewport where both documents do
not fit. Arrows or `j/k` select, Enter opens detail,
`?` opens Help and Esc returns. The key table drives both Help and the list and
detail footers. `f` is a local disclosed action, not a claim that every terminal
application uses that shortcut. Text input retains literal characters. Physical
Korean IME/chord behavior needs an actual operator-terminal observation.

Conversation and Queue have separate copy rectangles. Their headings,
boundaries and shared footer remain copyable. On presentation, pane geometry changes and
explicit layout changes retire the old gesture and quarantine observed
pending input through the existing presentation barrier. Terminal input and
output observations are not atomic; these source boundaries still need the
actual interaction comparison below.

The presented Queue owner also retains placement, available content height
and document length. Navigation waits for a replacement frame if an async
read or receipt changes these values. Fast queued navigation can therefore
be rejected with the common transition feedback. This does not freeze item
order or prove that all input/output is atomic. Exact selected-row authority
continues to guard changes. A Queue placement, content-height or document-count
change also cancels an in-progress copy gesture, including a drag in the
conversation pane whose coordinates did not change. This is a conservative
shared-frame policy; the operator must repeat the gesture after redraw.
Rejection happens before notice acknowledgement, so rejected navigation or
clicks cannot dismiss a previously displayed paste-loss notice.

## What the importance scores mean here

The earlier 0–10 analyst rubric ranks workspace/read uncertainty and pending
operator decisions at 10; selected target, action and result at 9; current
running turn at 7; other waiting items at 6; future schedules and unsolicited
technical IDs at 3; repeated stable rules at 1. These are design judgments,
not user-study ratings or numbers stored in product state.

The candidate gives the active Queue its own document and keyboard, keeps
read/result facts ahead of the list, and offers long content through detail.
The preview provides conversation context without adding editable controls.
The Queue footer orders the selected action before generic movement hints;
the global navigation-first grouping would otherwise hide next/last first.
Critical workspace notices and the common pinned exit/read keys retain their
existing precedence. Very narrow footers can still require Help.
This alone does not establish that lower-priority generic explanations occupy
the right number of rows, or that the layout is best for repeated reorder work.

## Comparable terminal patterns

[Tig's manual](https://jonas.github.io/tig/doc/manual.html) describes splitting
the parent log and selected diff, changing focus with Tab, and maximizing a
view. Its [configuration reference](https://jonas.github.io/tig/doc/tigrc.5.html)
documents automatic split orientation based on window dimensions. This supports
offering context and an explicit expanded reader; it does not establish MASC's
width or height policy.

Lazygit's [context types](https://github.com/jesseduffield/lazygit/blob/master/pkg/gui/types/context.go)
distinguish a persistent popup that Esc can return to from a display-only context
that cannot receive focus. Its [generated key reference](https://github.com/jesseduffield/lazygit/blob/master/docs/keybindings/Keybindings_en.md)
documents Enter and Esc for confirmation and returning from detail to its panel.
The useful inference here is a retained Queue parent, explicit Help/detail
children, and a conversation preview with no editable controls. Copying another
application's numeric layer order would not establish input ownership.

An [installed Lazygit 0.59.0 observation](../evidence/research/tui-queue-layout-2026-10-29/lazygit/README.md)
subsequently exercised these relationships in a private synthetic repository.
`j` updated Patch; Enter/Esc and Help/Esc retained the parent commit. At 80
columns, a side pane retained all 18 commit rows but metadata truncated their
subjects; full mode exposed subjects and covered Patch. Keeping rows is
different from preserving the information needed for the current task. Tab
moved to another application panel; it does not establish that a display-only
Queue preview needs focus. No human speed or preference comparison was made.

## Same-data comparison

Observe adaptive and expanded views on one exact executable, with the same
fixture, selected item, hints setting and draft. Compare 80×24, 120×36 and
160×40 as samples, not breakpoint definitions; also narrow the height until
Full is required. Repeat with no queue item, one item and a multi-page queue.
Keep each capture's source/binary/fixture hashes, viewport, selection and input
sequence. Text captures are actual terminal rows; browser sketches or geometry
arithmetic are not executed TUI proof.

| Question | Authoritative observation |
| --- | --- |
| Does the high-priority target/action/result remain readable? | Manual terminal capture at each selected/read/result state, including read failures. |
| What conversation context remains? | Actual authored rows visible in the preview, distinguishing omitted/partial sources from an empty conversation. |
| How much Queue fits? | Analyst count of visible selectable rows in saved frames, with the same selection and facts. This is not a layout assertion test. |
| Can familiar keys repeat the intended action? | Record operator inputs and exact request path/body for the selected synthetic event; distinguish HTTP acknowledgement from scheduling/execution. |
| Does selection survive layout, Help and resize? | Observe identity before/after each transition; inspect the sent target, not just a cursor's row number. |
| Does copying stay in its document? | Manually drag across multiple rows in each pane and inspect the terminal's copy request. An OSC 52 request does not prove OS clipboard acceptance. |
| Does a stale gesture act after geometry changes? | Start a drag, change placement and release; inspect the interaction outcome and any copy request. |

The prepared fixture has eight fabricated conversation messages and 18 pending
events. It logs POST path/body without headers and can acknowledge an event
request without executing or rescheduling anything. This can verify TUI wire
targeting and receipt presentation, not real-server urgency semantics or exact
queue execution order. It has no model, real Keeper, production workspace or
bearer credential. Hints are enabled for key discoverability comparisons;
the earlier hints-off baseline is not a controlled before/after experiment.

## Observation and resulting decision

The actual macOS executable for `38b6edd82eaac14cf7141fb83988108b7883f1dd`
was run with hints enabled and synthetic data; the
[retained observation bundle](../evidence/research/tui-queue-layout-2026-10-29/README.md)
contains capture bytes, provenance and request records. Each adaptive/expanded pair uses
the same executable, fixture, selected item and receipt state. At 120×36, both
showed 18 pending events; Side also retained the eight authored conversation
messages, while truncating event text sooner. Detail exposed the complete
selected item. At 80×24 with the first event selected and no receipt, Bottom
showed five events versus ten in Full. With a receipt it showed four. Its
three-row preview showed only trailing read diagnostics, not authored messages.
At 160×40, Side and Full both retained all 18 events with a receipt. At 80×16,
the earlier candidate already fell back to Full.

Separate zero/one-event fixtures retained all their Queue rows in Bottom at
80×24. They varied only the explicit event count and omitted the running and
scheduled rows; they are not comparisons against the 18-event fixture.

This supports Side as the wide default for the observed work, and Full for a
narrow overflowing queue. The revised source therefore allows Bottom only if
the entire Queue document, including reserved status/receipt/action-note rows,
still fits. It retains Bottom where it consumes spare space rather than list
capacity. Placement was subsequently observed on c2 and on final source as
recorded below. A small preview may still
show only diagnostics; the partial caption and Esc to full chat make that limit
explicit rather than selecting content by guessed importance.

A [later c2bdd3c executable](../evidence/research/tui-queue-layout-2026-10-29/revised-placement/README.md)
confirmed the revised narrow policy: at 80×24, a one-event queue with running
and scheduled rows retained Bottom; refreshing to 18 events switched to Full
with ten pending events visible. Its layout module is unchanged through d84,
but its execution does not validate subsequent input-ownership changes. A
separate synthetic health condition showed n/l hints at 80 columns when the
fixture generation warning was absent. Warning and ordinary footer conditions
must remain distinct.

Help and item detail opened above Queue and returned to it. After Help, detail,
layout and size changes, `n` then `l` sent `immediate` and `low` for the same
`fixture-event-01`, incarnation `1`. The fixture acknowledged the requests but
did not apply or execute them. These observations establish targeting in this
sequence, not real-server urgency semantics, physical IME/chord delivery or
human task time. Browser pixel comparison remains unperformed;
no user preference or general comprehension
improvement has been measured.

Synthetic SGR mouse reports also produced two OSC 52 copy requests: one
conversation drag across the pane boundary contained only the left document;
one Queue drag contained only the right document. A third drag, held while
`f` changed placement and released after the replacement frame, produced no
copy request. These are injected protocol observations of `38b6edd`, not a
physical pointer study or proof that an operating-system clipboard accepted
the requests.

## Final-source confirmation and decision boundary

The [final-source observation](../evidence/research/tui-queue-layout-2026-10-29/final-23c/README.md)
uses source `23c5ea834f89a0988c02ffe3e492980152869179` and an actual macOS
executable from **Minimal manual checks**
[40739146379](https://github.com/jeong-sik/masc/actions/runs/40739146379), workflow
ref `main` / `00559066e16f85e397786d64312b0a4b8f874dc2`.
Both the overall run and native job succeeded. Its source includes the later
viewport, footer and orphan-pointer repairs. Subsequent branch commits at
retention contain documentation/evidence/changelog only. The native receipt's
three suites are separate from this manual Queue observation and from full
regression, which was not run for this candidate.

At 80×24 final source kept the one-event queue in Bottom and showed ten pending
events in Full for the 18-event queue. At 120×36 and 160×40, Side and Full both
showed all 18; Side also retained the eight authored conversation messages.
The ordinary footer exposed n/l for a selected event even at 80×16. That
footer condition uses a synthetic matching health claim, not a matching real
server binary; warnings retain priority over those hints.

Help/detail return and repeated n/l targeted the same exact synthetic event.
Queue, Context and Help consumed their pastes while the covered draft survived.
Two single delivered jamo selected running then first-event rows; a composed
syllable did not replay multiple commands. The same target received n/l after
that sequence. These are delivered protocol inputs, not physical IME/chord or
human repeated-task measurements. A confirmed synthetic response remained
visible after deliberately stopping the fixture made both subsequent reads
unavailable: result and read failure retained separate meanings.

The paired orphan-pointer probe reproduced a lost paste notice on `38b6edd`
and retained it on final source. Positive pane-copy requests and a held
layout-changing gesture were also observed on final source. The replacement
frame's late drag/release did not clear the new paste-loss notice or issue a
third copy request. This covers the observed protocol sequence, not every
input/output interleaving or OS clipboard acceptance. The focused
`test_tui_server_identity_refresh` run
[40735405483](https://github.com/jeong-sik/masc/actions/runs/40735405483), ref
`feat/tui-queue-layout-20261029` / `b4f1466a3eb5236195694f903ae59f128fa5e4bb`,
passed 128 state/decision cases including viewport admission. It predates the
later root-loop pointer repairs and does not execute that loop.

For the observed queue-management task, the resulting choice is Side when
both documents have reading width, Bottom only when every Queue item still
fits, and Full for overflow or explicit detail. The active panel owns keys;
Help/detail form explicit children and the conversation preview stays read
only. This is a supported engineering choice under these conditions, not a
universal best layout or a measured improvement in human comprehension.
