# Original Task creation, input ownership and outcome visibility

The original six-axis Ask/Task/useful-work, preparation/discovery, Composition,
held/shared-backend, cold-input/readability/observation and matched actual
Before/After goal remains incomplete. This is a source implementation unit,
not a reproduced live Loading incident or measured performance result.

| Boundary | As-Is | To-Be in this source |
| --- | --- | --- |
| Created resource | Workspace-cancelled job and scoped/bounded notification | Original session-owned request outcome |
| Worker status | Generic creating notice | Not started, reserved, actual preparing, send callback, terminal |
| Footer | Temporary creation notice | Original active phase within existing footer fitting rules |
| Late error | Replaces current input unconditionally | Only Not_sent plus original editor/recipient/authority revision may auto-restore |
| Tool/transport error | All described as not-created | Server_error and Unconfirmed do not assert resource absence |
| Lost response | Original command can be overwritten/lost | Original intent retained, no automatic replay |
| Recovery | No explicit original command recovery | /task-recover copies latest matching failure into input only |
| Handoff | Original workspace/roster decision | Same fresh decision; created receipt cannot authorize foreign handoff |

`Masc_tui_task_dispatch` retains the immutable original request ID, Keeper,
title/body, command and expected workspace. One producer can claim each request.
Reserved dispatch is separate from actual worker preparation. Only after the
original prepare callback validates/selects the original MCP session does the
source enter the send callback. This is callback entry, not proof of physical
network write. Created includes the original returned Task ID and workspace.
Only a pre-send failure is Not_sent. A tool error is Server_error, not proof
that no Task exists. Transport/decoding/exception/cancellation after send entry
is Unconfirmed. Cancellation stores this stage evidence then propagates.

The same original Eio switch owns the work; it is not registered for workspace
observation cancellation or moved to a new/root switch. Initial Match/Some
identity, both workspace checks, existing session reuse/open, expected workspace,
argument ordering/body semantics and actual server FSM stay. Other precondition
notifications/auth/IO/callbacks can still block. There is no retry, resource
lookup by title, duplicate suppression or exact remote receipt reconciliation.

Each TUI request wraps its source with original workspace authority, recipient
and opaque input content-edit revision. UI collection appends one finite Task
group after existing owned groups, behind the existing captured shared FIFO
prefix; original receipt application requires the original pending wrapper.
It applies once. Created removes that intent and retains the existing fresh
handoff decision. Automatic chat focus additionally requires the original
editor authority/recipient/revision; actual queue handoff continues when newer
input forbids changing the screen. Failures remain available in original intent order. Active
requests and retained commands are separate lists: failed history is not scanned
on every frame. Cross-source ordering changes because Task completions leave
shared FIFO and join owned results. No single global-order claim.

All input content mutators, including clear/paste/edit back to empty, replace an
opaque token. Draft attachment/reference list assignments invalidate that same
revision, including adding then removing payload back to empty. The original
assignment stays a parenthesized unit expression; payload values/branches remain. Cursor/grapheme algorithms and cursor-only movement stay. Late
Not_sent restores only its original unedited input, recipient and authority.
Other errors keep new input and retain the original command. /task-recover is an
explicit copy from the latest original failed intent for the selected Keeper
and matching confirmed workspace. It never invokes creation or sends a message.
Server errors/unknown outcomes require inspecting Tasks before repeating. These
commands live in memory for this TUI session, not restart recovery.

The existing footer seam projects active requests from the current workspace
in original order. It distinguishes reservation, actual preparation, awaiting
reply and result awaiting UI. A ready result is not painted output, physical
worker exit, created Task proof or useful work. The footer uses its existing
width/retention rules and can omit facts in a narrow viewport. No new row,
reserved height, polling interval or UI wording/layout test.

## Source quantities and costs

Mandatory shared-capacity waits per Task creation terminal: 1 → 0. Unconditional
late-error editor replacement is removed. Shared notification capacity remains32;
no new cap, TTL, timer, auto retry, environment setting or authority knob.

Intent/body/original/root/outcome retention, two list references per active
request, CAS/stage values and O(1) token allocation per content edit or payload assignment are added.
Payload-edit protection has source-ingress evidence only; the authored cases
exercise text-edit ownership, not attachment staging execution.
Owned collection/footer scan O(A) active requests; UI membership/removal also
uses actual pending members. Explicit recovery searches O(H) retained intents.
Success removes its intent after receipt admission. Existing blocking callbacks,
auth, notifications and physical cleanup remain. Failed/cancelled/not-started/
unconfirmed/unfinished costs belong in actual matched cohorts. No elapsed-time,
heap, throughput, key/Loading/paint or speedup samples were collected.

## Authored resource/protocol cases — unexecuted

Two cases extend the existing actual in-process MCP/isolated persistent Task
fixture with real masc_add_task, production encoder/response/Task ID decoders,
the new producer, owned collection/Delivery_round and UI ownership decisions:

1. Actual creation held after resource commit survives workspace change and a
   full unrelated notification. Original Task/title/body are retained, foreign
   handoff is withdrawn and newer input/foreign Task resources remain unchanged.
   A second actual creation in the same workspace permits its fresh handoff
   while original editor ownership refuses automatic focus over a newer draft.
2. An actual committed Task with controlled lost response remains Unconfirmed.
   Parsed /task-recover copies the original without another resource mutation.
   No-switch is Not_sent; an edit then clear back to empty cannot borrow its old
   revision. Explicit recovery chooses the latest original failed intent.

These are authored, not executed. They do not exercise HTTP networking/session
opening, main prepare checks/full UI loop, cancellation/physical overlap,
provider, log, installed TUI, key or paint behavior. No private publication hooks,
helper-call counts, UI wording/layout/row-order/snapshot/PTY assertions.

Fifteen OCaml files passed parsing only, four interfaces first. Nine source
preservation sections include existing job/result ownership, wire/HTTP, fresh
handoff (only the new focus capability/predicate normalized), Delivery_round and input algorithms (only new token writes normalized).
The existing command test adapter accepts the new constructor; a stale text-input
test comment was updated without execution. Direct Dune consumers declared; no
new external packages. No types/warnings/link/build/tests/CI/native/model/
controller/audio/PTY/runtime execution, install/restart/live writes, self approval
or merge. Independent current-head source review and whole-stack acceptance
remain separate. Exact unknown-outcome reconciliation is still open.
