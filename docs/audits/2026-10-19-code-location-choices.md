# Code location choices and input ownership

Issue #43931 follows the owned different-file navigation in #43919. This is
another music and nonmusic rich TUI increment, not completion of that goal.

Previously every nonempty LSP locations answer followed its first entry.
References could therefore return many useful addresses while Code offered
only one. A same-file answer also moved the cursor in the async handler,
before queued input, paste or incomplete terminal sequences had priority.

Location answers now stage an immutable offer bound to the actual question
request, original workspace/read authority, scope, directory and source file
ticket. The event loop consumes the offer at its existing input-priority
boundary. One result follows there; several results open a filterable picker.
Filtering retains the actual returned location objects. Choosing a location
requires the same current offer, its open picker and an actual member of that
offer, then uses the owned navigation read and success-only B history.
Outside-workspace results report their address without issuing a file read.

Operator input retires an unanswered question and an unopened offer. Input
within an already open, current result picker retains that picker's filter.
Esc closes it. Another modal cannot be replaced by a delayed offer, and stale
source/view/authority or a new question cannot grant an old offer ownership.
The original query captures authority before dispatch rather than borrowing
the workspace that happens to be current when its answer arrives.

An ordinary Open callback can reset a source position. A question about an
already readable file retires that Open reply admission; ordinary Refresh
recovery remains available. Location admission retires remaining source reads
before capturing the offer. This retains existing observations and the Refresh
resume intent; it neither fabricates an HTTP completion nor claims physical
worker cancellation.

The existing workspace-entry target now links the palette projection and adds
semantic cases for selecting a filtered non-first Korean/space path, preserved
B history, single-result input deferral, input before/after receipt, changed
source and authority, cancelled/copied/invented offers and outside addresses.
Earlier location scenarios now explicitly consume staged answers. Checks
inspect requests, saved state and decisions, not screen wording or row order.

Independent review found two defects in the initial candidate. First, three
existing finder matches omitted the new location-palette constructor. The main
idle path opens that palette immediately before consuming finder results, so
the omission could fail on the next step. Those matches now refuse location
palettes explicitly. A state case follows that actual idle ordering and checks
that late catalog and finder success/failure callbacks cannot replace choices.

Second, cancelling a query left its recovery key available to workspace
reconfirmation. Explicit input cancellation now clears that key as well as its
unopened offer. An open, current picker retains its ticket while filtering;
closing it clears the query key. Ordinary file Refresh recovery remains
available. State cases cover cancellation before/after receipt, close followed
by recovery, and an uncancelled question resuming with a fresh source ticket.
The recovery fixture checks request/state decisions; it does not execute a
live server-disconnect cycle.

Changed OCaml files parse and whitespace checks pass. No local Dune build was
run. The new cases, native compilation and actual candidate behavior require
their own evidence. Predecessor source 731c791 and its native run are not
execution proof for these changes. Independent source review, guarded GitHub
approval, integration and operator installation remain distinct stages.
