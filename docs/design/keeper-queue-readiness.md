# Queue readiness and the Keeper turn slot

Queue presence records an unresolved input. It does not interrupt a running
turn. A queued chat waits for the Owner's turn slot, and the running turn ends
on its own terms. Only an operator interrupt or a stop ends a running turn from
outside.

## Chat operations

`Keeper_owner.operation_projection` separates durable `queued_count` from
`has_claimable_queued`. The latter uses the operation store's claim predicate:
unresolved Gate waits, incomplete Gate binding, and runtime retries whose
`not_before` has not passed are not claimable. The Owner refreshes this
immutable projection at startup, after mutations, and on drain wakes.

When a turn settles, the Owner claims a claimable chat operation before it
signals that the slot is free, so queued chat starts ahead of the next
autonomous turn. Claim checks the authoritative store and preserves batch
membership, input, execution identity, and output route. Readiness and the next
retry deadline use the same sampled time; the Owner schedules that recorded
deadline even when it passes before the sleeper is armed.

## Proactive and event intake

Proactive cycles pass through `heartbeat_event_intake`, admitting the ready
durable snapshot in one batch. A HITL resolution still in the approval pending
map is not ready, so intake does not admit it. Rows that reach the queue while
a turn runs wait for the next intake.

Batch intake keeps the conversation routing boundary and one exact HITL replay
grant per turn. Reading or selecting events does not ACK them. The exact source
batch remains the authority for later settlement. Direct chat requests remain
Owner operations with their own completion and delivery contracts; a proactive
turn cannot mark queued conversations done.

This distinction follows the separation between event notification and current
state reconciliation described by [Kubernetes controllers](https://kubernetes.io/docs/concepts/architecture/controller/).
MASC additionally preserves each command's execution and reply obligation.

## Verification scope

`test_keeper_owner` covers retained approval waits, readiness refresh, original
operation identity, and retry wake timing. `test_keeper_connector_attention_batch`
covers batch intake against a pending approval and a ready source, and the
routing and ACK boundaries.

These tests do not demonstrate a deployed binary, live Keeper latency, or TUI
status rendering. Those require separate runtime evidence.
