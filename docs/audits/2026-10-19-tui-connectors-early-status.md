# Deliver Connector status before directory enrichment

Source comparison base: `d8505286bf5a7f26ad2cb549a10b832929391a4e`
(#43880). This layer keeps the original Connector request and structured
workspace read while removing directory completion as a prerequisite for
delivering the already-received status and binding data.

Follow-up: [write reactivation](2026-10-19-tui-connectors-write-reactivation.md)
changes later-write behavior to retire the original names work. This document's
write-during-names scenario describes the #43887 layer; its operation-preserving
test now places the later write after enrichment, while a separate real-job
scenario covers retirement during names and before delayed status application.

## As-Is / To-Be

`load_connectors` decoded a valid status snapshot, then joined every Connector's
server/channel/person name chains before returning its one aggregate. Both
Connectors and Keeper Channels read `state.connectors`. A slow name chain could
therefore hold back useful status and bindings that the loader already had.
This is a source dependency finding, not a measured production delay.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Status delivery | Wait for every directory chain and projection | Publish decoded status before starting directory work |
| Ownership | One opaque original request | Same request owns status and final enrichment |
| Read scope | One workspace JSON observation job | Same one job; intermediate envelope captures original authority/read epoch |
| Stage | Active read until aggregate returns | Status pending, then status received with names pending |
| Status application | Final handler changes snapshot and selection | Original status changes them once; duplicate status rejected |
| Prepared binding action | Final snapshot clears it | Final name enrichment preserves the action prepared after status |
| Pending unbind offers | Wait for names | Original status can answer them; final result can answer later pending offers |
| Later write | Owes a subsequent fresh read | Neither early status nor old enrichment consumes that later demand |
| Directory failure | Previous snapshot plus failure | Received current status remains usable with failure; normal per-chain partial results retained |
| Retired stages | Final owner/authority admission | Same exact admission also guards early status |

## Original resource and operation continuity

The loader's required `on_status` callback runs on the original read fiber,
after status GET receipt and shared CPU decoding, before directory loading.
It enqueues `Connectors_status_loaded` through a UI-captured `workspace_enqueue`
envelope. The shared launcher still owns the only observation daemon, binding,
cancellation registry and final result. There is no second fork, duplicate
health/status GET, detached name worker or new timer/cache/generation limit.

`Connector_read` retains its immutable request/demand state. Its active stage
begins at `Status_pending`; accepting the exact original status moves it to
`Names_pending` without settling the read or post-write demand. Duplicate
status and retired request callbacks are rejected. A not-started callback
cannot release a request that has already produced status. Suspension still
retires the original request and preserves owed demand; confirmed other-root
reset still clears it. A later write still coalesces into a fresh follow-up.

The UI edge owns actual snapshot application after admission. A full status
preserves the selected Connector ID where present and resets the binding
selection/action as before. After that status, final `Names_only` application
uses the same immutable status with its projected names, without resetting
binding selection or the armed exact unbind target. The loader constructs that
enrichment from the original snapshot; it does not fetch another status or
borrow a sibling request's data. Current production assignments to the
Connector snapshot are these admitted stages and workspace resets.

The existing unbind-offer interpretation is shared by both accepted stages.
The status can settle already-pending offers immediately. Final names can
settle offers queued after status (pause itself does not change bindings),
while an empty pending list does not repeat an offer. The existing selected
Keeper, composer, already-armed bulk action and frame/key checks remain. Actual
binding writes still use the existing conditional server operation and its
receipt; a read never authorizes replay or substitutes for that receipt.

The async protocol interface is changed before implementation. The new message
is classified as a workspace observation in every existing exhaustive
classifier. Stages and application variants are internal OCaml control data;
no public JSON/dashboard/TLA+ enum or endpoint changes.

## Before / After quantities and observability

For one nominal attempt, explicit GETs remain **P + 1 -> P + 1**, where P is all
directory pages. Observation jobs remain one. Source delivery changes from
one final aggregate to an early status plus that final aggregate. No
invocation-count tests are added and no delivery count is a speed metric.

Before, status eligibility depended on status GET/decode, all directory chains
and name projection. After, status eligibility depends on its own GET/decode
and enqueue/admission; directory work remains independently outstanding. This
removes that prerequisite, not IO/CPU pool contention, mailbox scheduling or
terminal paint. A cache-only/inline read might finish both stages before the
next frame; enqueue is not a guarantee of a separately painted intermediate
frame. No elapsed-time or throughput improvement is asserted.

Both existing surfaces derive their notice from the typed stage: received
status with names pending differs from a first status read showing the last
observation. Existing decode/project wait measurements keep their prior
meaning, including pool wait/return scheduling. No new runtime cohort was run.

## Authored scenario and evidence limits

The existing two compound request/demand scenarios now decode actual temporary
binding descriptors and use the same typed snapshot application as production,
instead of passing raw JSON through a generic completion boundary. A third
compound scenario is authored, unexecuted:

1. Persist two real Slack bindings and admit their actual decoded status before
   directory completion. Prepare an exact unbind target from a received binding.
2. Decode a clearly identified name-page protocol fixture for that binding ID
   and use the production name projection. Change the other real persisted
   binding during names, queue its fresh-read demand, and reject duplicate
   status and an impossible late start-failure callback.
3. Apply the original enrichment, retain the prepared target, and use that
   actual target to conditionally remove its real store member. Begin the owed
   fresh read and observe the original removal plus the other member's change.
4. Reject old status and names against that newer observation. Fail the newer
   read's remaining directory work without losing its received status or
   immediately retrying.

Identity and name-page records are fixtures. The binding store, descriptors,
decoders/projection and production TUI state transitions are real. No private
Main loop, offer-key routing, actual HTTP/cache, worker cancellation/cleanup,
model or terminal executes in these scenarios. Tests are authored, not PASS.
No wording/layout/row-order/snapshot/PTY/helper-mirror/invocation-count tests
are added. Parsing is not typechecking, compilation or behavior proof.

Later matched Before/After should hold a directory chain while receiving
status, prepare a real binding operation, write during names, and replace
authority including same-endpoint A -> B -> A/cache/304. Retain original
request, stage, actual membership, operation receipt, worker cleanup and every
failed/cancelled/interrupted/unfinished sample. Actual status paint and useful
Task progress need their own evidence. The broader six-part goal remains open.
