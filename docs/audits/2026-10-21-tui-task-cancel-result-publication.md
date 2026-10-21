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

The dedicated Task cancellation retains its initial authority gate and uses
main's authenticated operator cancellation endpoint, original reason and
expected workspace. Confirmed, refused and unanswered outcomes remain distinct;
ordinary exceptions inside an attempted request remain unconfirmed, while
no-switch/launch refusal never becomes success. The server's FSM still decides
whether cancellation is allowed. Original UI receipt/follow-up decisions and
foreign withdrawal remain unchanged. An accepted operation's receipt does not
authorize a foreign read, reopening another detail, repeating the cancellation
or clearing a new composer draft. No automatic resend or replacement operation
is added. This source integration does not prove restart recovery.

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
Tasks in isolated persistent workspaces. Cancellation uses the actual operator
route parser/commit with its expected-workspace precondition, Task readback,
typed receipt, retained-result producer and Delivery_round:

1. An actual accepted cancellation is held at a controlled post-commit boundary.
   Workspace authority/root changes while a full unrelated notification remains.
   The original unscoped Task/workspace receipt survives, its actual cancellation
   owner/reason persists, production follow-up projection withdraws the foreign
   refresh, and foreign Task resources stay unchanged.
2. No-switch and ended-session launches leave the original actual Task claimed.
   A separate live producer receives an actual foreign-workspace precondition
   refusal as an error for the original intent; both Tasks remain claimed.

These are authored cases, not executed results. They do not exercise HTTP
authentication/networking/session opening, the main launcher/workspace checks/full UI loop,
physical overlap/cleanup, logs, visible TUI, input or paint. No private registry
hooks or helper-count/UI wording/layout/row-order/snapshot/PTY assertions.

The original unit recorded parsing-only evidence before integration. The
main/stack integration combines the operator cancellation contract with owned
result publication and adapts the resource fixture to that contract. Historical
source-preservation counts do not certify this integrated candidate. Direct test libraries are declared;
no new product dependencies. No typing/warning/link/build/tests/CI/native/model/
controller/audio/PTY/runtime execution, install/restart/live writes, self
approval or merge. Independent current-head source review and whole-stack
acceptance remain separate; no measured performance improvement is claimed.
