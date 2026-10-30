# Selected live context: ownership and responsiveness

Source baseline: `b41a0966c431873c426d8d934d134f4c8249a991` (Keeper/Work isolation).
This document describes source changes, not measured performance or an installed TUI.

## Before / after

| Path | Before | After |
| --- | --- | --- |
| Admitted Keeper metadata | Read selected context before input/detail follow-up | Admit metadata, continue follow-up, schedule an independent context read |
| Keeper row movement | Synchronously resolve and read the selected trace | Move cursor; render owner reconciles an asynchronous read |
| Open/move Keeper detail | Read context in the input handler | Shared I/O job owns config resolution and the context store read |
| Same-owner refresh | Replace the context snapshot | Keep last observed value while pending; retain value and failure after a failed refresh |
| Identity | Keeper name on the returned snapshot | Workspace read scope, base path, Keeper, trace and monotonic request generation |
| Chat context | Read selection from the roster cursor | The explicit chat target owns context, independent of roster movement |
| Supersession | Completed snapshots replace one another | Retire request authority and request cancellation; late/duplicate results cannot settle a successor |
| Diagnostics | No separate context dispatch/admission receipt | Started, worker returned, superseded and admitted/discarded observations carry original request/key and clocks |

`masc_tui_context_state` uses the shared immutable fetched-state machine. Clear
preserves its generation. Workspace suspension changes read scope, so returning
to the same path cannot revive a previous read. Existing generic fetched-state
semantics are unchanged. No context source read is issued on unrelated surfaces.
Same-key metadata cadence and explicit refresh may revalidate; redraws alone do
not retry completed or failed reads. The common executor owns actual worker
cancellation and cleanup; a supersession diagnostic means cancellation requested.

The four former direct call sites (metadata admission, row movement, detail
selection, detail opening), and the explicit local reload helper, no longer call
the context store on the render/input owner. The work still exists in an I/O
job. This is a structural removal from the UI path, not an elapsed-time saving.
The standard launcher installs the shared pool; pool-absent inline entry policy
remains part of the common executor and is not a background-execution guarantee.

## Verification scope

Parser-only checks cover changed OCaml source/interfaces. Four context ownership
scenarios and three state integration scenarios are authored but unexecuted:
exact trace projection; A/B/A and clear; scope/base/trace isolation; retained value
with failure and suspension; queued old trace before reconciliation; chat target
versus roster cursor; cancellation request and same-path workspace reconfirmation.
They assert source ownership and state, not screen wording, row layout or PTY
frames. Typing, functional execution, actual worker cancellation, runtime and
painted UI behavior remain unverified. No CI or install is part of this unit.

## Next implementation priorities

1. Replace synchronous explicit post-action `load_from_masc_dir` calls with
   source-owned metadata/Work reads. Preserve new-Keeper opening, deletion,
   queued drafts and original Task handoff while waiting for the required source.
2. Finish first-usable-input independence across remaining panels. Record initial
   identity, required metadata, input availability and full refresh as separate
   boundaries; avoid treating the slowest optional panel as input readiness.
3. Extend exact Task/Skill/tool preparation reuse using original Task and immutable
   catalog/config revisions. Existing one-call recipe and frozen descriptor
   mechanisms remain the basis; inspect actual reuse gaps before adding caches.
4. Continue resource-owned nested/dynamic/effectful Composition and held-job shared
   backend batching. Distinguish independent branches from shared-resource
   conflicts; retain original job/result identity and cancellation authority.
5. Carry Ask answer through the original Task to useful work. Answer persistence,
   wake acceptance, resumed execution and committed result are separate facts.

For a future authorized matched comparison, keep objective, workspace, data,
source cohort and clock definitions fixed. Report first input and first useful
physical tool commit p50/p95, duplicate preparation reads, critical-path wait,
full-refresh duration, and counts of failed/cancelled/unfinished samples. Worker
read completion does not establish paint time or model progress. Timing targets
must not become runtime deadlines or action gates. No speedup percentage is
inferred from fewer synchronous call sites.
