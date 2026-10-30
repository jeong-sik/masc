# Indexed original batch groups and one status frame per draw

Source baseline: `ec4534a0e93dd9abbf4fcffcca14a1395561babc` (#43832).
Scope: selected Keeper inflight batch grouping and status-adjacent preparation.
No TUI, test, benchmark, model or performance trial was executed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Each qualifying inflight member | Search all existing groups; map or append/copy the group list | Exact execution-ID lookup and immutable map update |
| Group presentation | First execution appearance | Same first appearance, retained as an ordinal |
| Representative original input | Strictly earlier submitted input replaces it | Same strict comparison; equal-time input keeps the prior representative |
| Group evidence | Every member and reconciling phase counted | Same counts; original inflight/log objects retained |
| Inflight, Activity and observed interrupt rows | Budget, applicable menu and display build independently | One synchronous frame supplies the same original rows |
| Source status projection | Already shared within a draw | Retained inside the expanded local frame |
| Width arguments | Threaded through width-independent inflight/status counts | Removed from helper APIs and all callers |
| Input, CPU, paint and Loading delay | Unmeasured | Unmeasured |

Let `N` be all inflight entries, `R` those remaining after the existing target
and current-live-execution filters, and `U` their distinct exact execution IDs.
The old grouping costs up to `O(R*U)` after the `O(N)` filters: with all-distinct
executions, searching and copying each growing prefix are quadratic. The new
grouping costs `O(R*log(U+1) + U*log(U+1))` plus those same filters, using an
immutable index and a final ordinal sort. It retains all `R` members without a
budget/cap, time heuristic or ID normalization. Empty candidates bypass the
index. Map nodes, bindings, sorting and the expanded frame add unmeasured
allocation/setup overhead; the common small case is not claimed faster.

For a selected complete drawing path, each of inflight, Activity and observed
interrupt row preparation changes from `2 + M` calls to one, where `M` is zero
or one applicable command-menu measurement. Inflight grouping is only nonempty
in the existing full diagnostic mode. These are conditional source call counts,
not HTTP counts, measured speedups or evidence of terminal paint.

The frame holds original source status and the three immutable row lists only
for one synchronous draw. The existing menu/history budget and display consume
that frame; other input/viewport callers create their own fresh frame. No state
slot, asynchronous request, timer, persistent cache or worker handoff is added.
The target/live-execution filters, compact/results/full distinction, original
batch identity, failure/continuation/reconciliation and interrupt semantics
are preserved. The original status-source variant is retained under its own
name inside the expanded frame; no duplicate legacy API is kept.

Existing batch scenarios already assert original execution binding, all member
counts, reconciliation and the oldest original submission. Their code remains
unchanged and unexecuted. Existing gate scenarios only lose the unused width
argument; assertions and transitions are unchanged. No test/assertion is added
for layout, wording, row order, snapshot, PTY, helper mirroring or invocation
counts. Parsing checks prove syntax only. Typing, scenario continuity, actual
UI/input/paint/useful-work and timing remain unverified.
