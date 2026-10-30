# Original Task creation inspector

This source unit connects #44569's exact creation facts to the TUI. The original
six-axis Keeper/TUI goal and matched actual Before/After remain incomplete.

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Unconfirmed original creation | Footer and copy-only /task-recover; manual MCP lookup | /task-inspect opens its original request and exact creation lookup |
| Older failed originals | Latest copy recovery only | Explicit [ / ] selection preserves each original wrapper, title, body and transport fact |
| Creation/lookup certainty | No original lookup source in UI | Separate typed unobserved / recorded / ambiguous receipt and typed failure |
| Refresh failed | No inspector observation | Last fact plus refusal/failure retained; explicit r only |
| Late reply | No inspection request/ticket | Original viewer, wrapper, workspace authority/read epoch and current ticket/pending identity all required |
| Inspect current Task | Manual search | Explicit o after one ready fact opens existing Task view/history; no automatic handoff/replay |

## Implementation and authority

`Masc_tui_task_creation_read` is an immutable source using the existing fetched
state machine and detail-reading document/viewport. The original creation
transport remains untouched, including Unconfirmed after a later recorded fact.
The decoder validates the exact original request id, both original workspace
paths, positive backlog revision and receipt cardinality. Server tool errors,
invalid replies, workspace unconfirmation and interruption have closed error
variants; strings are only parsed at the JSON boundary and rendered for display.
Unobserved is inconclusive; recorded is creation evidence, not current Task
existence/status or useful-work completion. Ambiguous facts never select a Task.

New Task requests use the existing UUID v7 generator instead of a timestamp-only
identity, reducing accidental correlation collisions. Existing original IDs
remain unchanged.

Each original request retains its own source and last observation. Uninspected
creations allocate an unread source and do not prepare a full document. Explicit
open/read/state changes prepare the document once; rendering and scrolling use
the same existing detail viewport. Observation documents use their source refresh controls instead of the static
capture/reopen hint. The existing original-call reader uses this same explicit
observation document mode. The original body, refusal and every returned
Task id remain scrollable. Technical request/workspace/revision evidence lives
in this explicit diagnostic reader, not in the original user message body.

`/task-inspect` admits retained requests for the selected Keeper and confirmed
original workspace without needing Keeper roster availability to perform a
read. [ / ] walk original identities in retained order. Current viewer selection
is O(1); explicit history selection scans retained requests. r supersedes a
lookup and cancels only its owned observation job. Closing/changing scope
retires the pending UI source; physical worker cleanup follows the existing
workspace job policy. Workspace withdrawal retires the selected inspector,
without walking all historical originals. Completed original facts are not
rewritten or moved to a successor workspace.

The MCP read uses the original request/workspace arguments and existing session,
preflight checks and common session-owned result registry. Immutable response
interpretation uses the shared CPU decode policy; endpoint/session and UI
admission stay with their original callers. The protocol marks the completion
as a read. No terminal shared queue-capacity wait is added. Ready lookup data
cannot overwrite new input/attachments/references. The only navigation is the
operator's explicit o on a current ready single fact; it follows the existing
Task detail/history path for a matching loaded Task row. If the row is absent,
the inspector stays open and reports unconfirmed current presence instead of
silently falling back to the generic Task list. A dedicated original-Task detail
read independent of global Task rows remains next work. No automatic
creation, retransmission, recovery copy, Keeper queue/handoff or status mutation.

## Costs and structural Before/After

New sources per original creation: 0 -> 1 lightweight unread source; full
inspector document preparation occurs only on explicit inspection/state changes.
New effectful creation calls from inspector: 0 -> 0. Each explicit lookup uses
one MCP tool read plus existing workspace/session preparation, which can include
health/session I/O. These are source quantities, not latency measurements.

Retained source/last receipt/document costs belong to each inspected original;
explicit [ / ] and eligibility scan the retained history, ambiguity keeps every
returned Task id, and document wrapping/scrolling uses the existing viewport.
Explicit retries can overlap old worker cleanup; cancellation is not physical
termination proof. No new cache lifetime, polling cadence, timer, limit, retry
loop, provider/model gate or environment setting is introduced. Cold input,
network/paint/worker latency, heap cost and Loading causality are unmeasured.

## Authored actual protocol/resource cases (unexecuted)

Two cases extend test/test_tui_task_cancel_result.ml:

1. Actually create a Task and discard its response; keep original Unconfirmed,
   inspect through production MCP/strict backlog/typed decoder and common owned
   result registry, then verify exact Task selection and unchanged newer input,
   actual Task resources and absent handoff. A real reply for a different
   creation request is refused and retained beside the prior fact; it grants
   no ready Task-open decision.
2. Hold an actual completed MCP lookup before UI application, close/reopen the
   same original and complete the fresh read, then refuse the old ticket. Create
   another same-title actual Task and select its original history identity.
   Withdraw the workspace before applying another completed read and refuse its
   foreign-scope admission while retaining the original fact and both workspaces'
   actual Task resources.

The fixture does not run the Main key loop, actual HTTP networking, a TUI/PTY,
provider/controller, physical paint/input measurement or a process restart.
It does not prove prompt cancellation/cleanup or a runtime speedup. Existing
command-describe fixture only gets the new constructor; no new helper/count,
wording, layout, snapshot or PTY test is added. Checks are parsing only (four
interfaces first), source preservation/direct dependencies and diff whitespace.
No typing/warnings/link/build/tests/CI execution or installed/live write.
Independent current-head source review, stack ancestry and integration remain
separate; external lower refs and the #44199 -> #44211 recorded gap are preserved.
