# Queue layout comparison: candidate and observation protocol

Status: implemented candidate, not an observed layout winner. This follows the
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
| Bottom | Side does not fit, but caption + three conversation rows + divider leave three Queue rows after its possible fixed facts | Keep full item width and a short conversation context; fewer queue items are simultaneously visible. |
| Full | The documents cannot both fit, Queue is explicitly expanded, or an item is opened | More space for Queue/detail; the conversation is covered until returning. |

The minimum uses the existing chat fallback width rather than an arbitrary
80/120-column breakpoint. Twice that fallback is an initial reading-space
policy to evaluate, not a measured optimal width. Placement reserves the
possible receipt and selected-action note, so selecting an item or receiving
a result does not make the preview appear/disappear. Actual list height still
uses the facts currently displayed. Both key handling and rendering use that
remaining height.

`f` switches adaptive/expanded view; arrows or `j/k` select, Enter opens detail,
`?` opens Help and Esc returns. The key table drives both Help and the list and
detail footers. `f` is a local disclosed action, not a claim that every terminal
application uses that shortcut. Text input retains literal characters. Physical
Korean IME/chord behavior needs an actual operator-terminal observation.

Conversation and Queue have separate copy rectangles. Their headings,
boundaries and shared footer remain copyable. Pane geometry changes and
explicit layout changes retire the old gesture and quarantine observed
pending input through the existing presentation barrier. Terminal input and
output observations are not atomic; these source boundaries still need the
actual interaction comparison below.

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

No human task-time, error-rate, preference or pixel-readability claim has been
measured yet. Choose the default only after inspecting these candidate frames
and repeated-action results, and retain Full as an explicit task-dependent
alternative. Source review and parser checks are recorded in the PR; final-head
native execution and this comparison remain open.
