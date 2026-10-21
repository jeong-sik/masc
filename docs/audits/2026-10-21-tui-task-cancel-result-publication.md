# Original Task cancellation receipt publication

This unit extends the prior common-result layer to the dedicated Task
cancellation producer. The original Ask/Task, preparation/discovery,
Composition, held/shared-backend, cold-input/readability/observation and matched
actual Before/After goal remains incomplete. No live Loading incident was
reproduced or timed here.

| Boundary | As-Is | To-Be in this source |
| --- | --- | --- |
| Dedicated terminal result | Raw bounded notification enqueue | Existing session-owned terminal publication |
| No Eio switch | UI caller enqueues failure and can wait for capacity | Original error retained without terminal queue-capacity wait |
| Workspace withdrawal | Original unregistered operation switch | Same original switch; no workspace cancellation registration |
| Receipt | Original Task and expected workspace, unscoped | Same original identity and unscoped receipt |
| Synchronous fork error | Could escape the dedicated launch site | Existing result error channel retains it |
| Follow-up | Temporary hold or foreign-workspace withdrawal | Same production decision and selected-detail check |
| Ended session | Session lifetime | Shared registry refuses new/late results |

The existing result library now shares registration, exception conversion,
no-switch handling and terminal publication between two explicit producers.
`launch` keeps the original workspace-job registration/cancellation contract.
`launch_session` forks on the same current Eio switch as the original dedicated
Task producer, without workspace cancellation registration or scope wrapping.
It does not move work to a new/root switch or extend the original switch's
lifetime. Runtime cancellation still propagates; it does not become a success
or failure receipt.

The dedicated Task cancellation keeps its original initial authority gate,
two pre-dispatch workspace checks, MCP session, request ID, cancel arguments,
reason/handoff, expected workspace and typed tool verdict. The server's FSM
still decides whether cancellation is allowed. The existing UI handler,
follow-up retention and foreign withdrawal remain unchanged. An accepted
operation's receipt does not authorize reading a foreign workspace, reopening
another detail, repeating the cancellation or clearing a new composer draft.
No automatic resend, fallback or replacement operation is added. A transport
failure after a send remains the existing error channel; this unit does not
solve uncertain remote outcomes or prove restart recovery.

The original immutable Atomic core and finite Delivery_round are unchanged.
Terminal results now join the existing owned batch after the captured shared
notification prefix and prior owned groups. Original ready timestamps remain
available to existing UI application-delay observations. These cancellation
completions move out of shared FIFO, so relative ordering across sources
changes. Publication is not source admission, paint or physical worker exit.

## Quantities and costs

Mandatory shared-capacity waits per dedicated terminal delivery: 1 → 0, for
both actual worker result and no-switch failure. This is a source-path count,
not measured occupancy, elapsed time, throughput or speedup. Shared notification
capacity remains 32; no new limit, timer, retry loop, cache or authority policy.

Task cancellations now pay the existing registry's token/Atomic/list allocation,
O(P) pending traversal during publication/retirement, CAS retry allocation,
ready payload retention and O(R) batch reversal/mapping/append. Sharing the
launch body adds a small dispatch closure to the workspace producer as well.
Failed/no-start/cancelled/closed/refused operations remain in actual comparison
cohorts. Other notifications, workspace precondition reporting, arbitrary work,
callbacks, deliver and cleanup can still block. Removing the terminal queue
wait does not make the entire Task cancellation or input path nonblocking.

## Authored protocol/resource cases — unexecuted

A dedicated fixture initializes real in-process MCP sessions and creates claimed
Tasks in isolated persistent workspaces. It uses the production TUI request and
cancel argument encoders, actual `masc_transition`, response decoder, Task
readback, retained-result producer and Delivery_round:

1. An actual accepted cancellation is held at a controlled post-commit boundary.
   Workspace authority/root changes while a full unrelated notification remains.
   The original unscoped Task/workspace receipt survives, its actual cancellation
   owner/reason persists, production follow-up projection withdraws the foreign
   refresh, and foreign Task resources stay unchanged.
2. No-switch and ended-session launches leave the original actual Task claimed.
   A separate live producer receives an actual foreign-workspace precondition
   refusal as an error for the original intent; both Tasks remain claimed.

These are authored cases, not executed results. They do not exercise HTTP
networking/session opening, the main launcher/workspace checks/full UI loop,
physical overlap/cleanup, logs, visible TUI, input or paint. No private registry
hooks or helper-count/UI wording/layout/row-order/snapshot/PTY assertions.

Four changed OCaml files passed parsing only, interface first. Twelve exact
source-preservation sections include the original Atomic core, Task cancellation
work body, UI receipt/follow-up decisions, drain, source types/protocol,
workspace job and MCP/HTTP implementation. Direct test libraries are declared;
no new product dependencies. No typing/warning/link/build/tests/CI/native/model/
controller/audio/PTY/runtime execution, install/restart/live writes, self
approval or merge. Independent current-head source review and whole-stack
acceptance remain separate; no measured performance improvement is claimed.
