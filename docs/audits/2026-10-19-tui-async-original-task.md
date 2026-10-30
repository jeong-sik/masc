# Original request to original Task inspection

Relates #42799 and follows #43985. This is the actual source connection from
an async request detail to its original Task body and history. The complete
six-axis objective remains active.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Original Task | Request detail displays `source_task_id` as text. | `t` opens the exact original Task and history using confirmed original run evidence. No current Keeper Task or current list-row fallback. |
| Task outside current list | Existing Task detail rendering looks up a domain row in the current task list and falls back to that list when absent. | The Tools source reader uses the existing exact Task endpoint, retaining the captured request/run/Task provenance. It has its own body/history readings and does not replace global list selection or history. |
| Partial availability | No source Task reads exist in Tools. | Body and history have independent admitted jobs, fetched tickets, pending states and retained failures. Either can complete first; neither waits for the sibling's result to begin. |
| Requery and withdrawal | No source Task read ownership exists. | Cadence shares each in-flight reading. Explicit refresh replaces each original job. Esc cancels only these observations, returns to the original request, and refreshes that request. Workspace suspension retires tickets; withdrawal clears source and readings. Same-ID reentry cannot accept an old reply. |
| Source validation | Existing generic Task/history decoding is not bound to this request. | Exact body ID and canonical Goal observation are checked; history rows must identify the captured original Task and cannot contain a conflicting Task identity. Per-field Task decode diagnostics remain visible. |
| Complete document | Existing Task rendering depends on its global list/history state. | The immutable body and history document functions are shared by the actual Work and Tools consumers; full description, state, contract and evidence remain readable without borrowing another pane's state. |

The link may use a retained physical reading or the same request/context's
earlier confirmed logical reading. It is explicitly marked as earlier evidence
with its original run and logical observation time. Unavailable evidence without
that confirmed source, a non-Composition request, and a run recording no Task
remain distinct. Observation times do not select authority. The captured link
authorizes only inspection, never an effect, replay or completion.

## Actual producer and consumer path

`tools_async_source_task` derives the source from the strict request reading.
The root `t` handler captures it, retires the physical-request observation, and
launches exact body/history GETs through the existing workspace-admitted read
launcher. Each uses its original cancellation key and captured Task ID. Pure
decoding uses the existing CPU path, with separate `tools.original_task.decode_wait`
and `tools.original_task_history.decode_wait` observations. A missing Task is a
source failure; it does not switch to the current Keeper or another task list.

The source key includes original request context, run and Task. Read epoch,
opaque fetched ticket, current source and exact request selection must still
match at settlement. Body/history are independent store observations, not an
atomic Task snapshot. The history window reuses the existing Task-history HTTP
contract. No new history limit, executor, timer, runtime budget or retry gate is
introduced. The original request's logical observation time is not represented
as the Task body's or history's collection time.

## Evidence and remaining work

The existing real first-loss Composition/resource scenarios now continue
through actual exact status projection, TUI source selection, authoritative
Task storage, actual Task detail/history producers, strict decoders, and owned
TUI read settlement. They retain the original resource, source Task and logical
decision. Authored cases include a Task absent from UI list state, independent
history completion, body refresh failure retaining full description, wrong
Task/body/event rejection, suspension, and same-ID withdrawal/reentry.

These compound scenarios are **unexecuted**. No layout, wording, row-order,
snapshot, PTY, invocation-count or helper-mirror tests are added. Validation is
OCaml parsing and whitespace inspection only; no local build/typecheck/test,
CI dispatch/watch, native/model/PTY/controller/coordinator/report run, install,
restart, live prompt/config write or own merge is performed. Independent source
review, actual visible UI, usable-input/paint timing, runtime usefulness and
matched actual Before/After remain unverified. No measured speedup is claimed.

Original Ask to Task/useful work, preparation attribution/frozen discovery,
ordinary/nested/dynamic/effectful Composition resource continuity, held-job and
shared-backend continuity, cold-start/TUI visibility, and matched cohorts all
remain active. Failed, cancelled, interrupted and unfinished samples remain
required in future measurement denominators.
