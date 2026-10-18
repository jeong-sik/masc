# One original status projection per synchronous chat draw

Source baseline: `84005ae0b9d9a03f75c9ce4d7b92f97a39582191` (#43830).
Scope: selected Keeper chat status preparation and the existing menu/history
row budget. No TUI, test, benchmark, model or performance trial was executed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Status preparation | Independent recursive helper calls rebuild the same original rows | One immutable projection supplies visible rows, hidden count, hint and reserved count |
| Command menu and history budget | Each can reselect and rebuild status | Both receive the draw's original frame |
| Compact Activity expansion keys | Rebuild folded count for each activity row | Read the same frame's folded count |
| Actual status display | Reselects, then rebuilds count, rows and hint | Uses the original frame's log and projection |
| No matching original execution | Checked separately by budget and display | Explicit empty frame shared by consumers |
| Frame lifetime | No shared status projection | Synchronous local value only; next draw observes current selection |
| CPU, input, paint and Loading delay | Unmeasured | Unmeasured |

## Source construction counts

Count calls to `keeper_message_unfolded_status_rows`, not HTTP requests,
terminal paints or independently timed work. On a selected full drawing path
with folded status and at least one hidden row, the old budget constructs
four lists and the status drawing constructs six. Each compact/results Activity
row constructs two more, and an applicable command-menu measurement constructs
four more. With `A` such Activity rows and `M` applicable menu measurements
(zero or one), this is `10 + 2*A + 4*M` constructions versus one in the new draw.
On the unfolded equivalent, it is `2 + M` versus one. These conditional source
counts do not apply to every frame or imply the same reduction in runtime cost.

The original list construction and filtering remain linear in the number of
status rows. The projection adds a small immutable record and frame variant.
One selected log and one status timestamp are reused inside the synchronous
draw. Other status-budget callers create a fresh projection for their own call;
input events and later frames never borrow the previous draw's value.

## Ownership and validation limits

Selection and the target-Keeper guard run at frame preparation. Both a present
original log and the absence of one are explicit values passed through menu
measurement and history budgeting to display. No asynchronous request,
preparation read/retry, workspace authority, cache or timer is added. Live and
saved preparation, partial coverage, failure, approval, interrupt and
continuation diagnostics keep the original row construction and fold policy.
The standalone hint still reserves a row only when hidden detail has no
visible progress row to carry it.

Existing scenarios keep their assertions and input transitions; only calls to
the removed recursive helper API are adapted to projection fields. No test or
expectation is added for layout, wording, row order, snapshots, PTY behavior or
helper invocation counts. All scenarios remain unexecuted. OCaml parsing proves
syntax only; typing, scenario continuity, visible behavior, input response and
measured CPU/Loading improvements remain unverified.
