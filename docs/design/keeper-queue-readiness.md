# Queue readiness and cooperative Keeper progress

Queue presence records an unresolved input. It does not, by itself, authorize
interrupting an autonomous turn. At a safe tool boundary, the Keeper yields to a
successor that the existing intake or Owner can actually claim.

## Chat operations

`Keeper_owner.operation_projection` separates durable `queued_count` from
`has_claimable_queued`. The latter uses the operation store's existing claim
predicate: unresolved Gate waits, incomplete Gate binding, and runtime retries
whose `not_before` has not passed cannot request a yield. The Owner refreshes
this immutable projection at startup, after mutations, and on drain wakes.
The tool-boundary reader performs no chat-store SQL. An unavailable chat store
provides no evidence for preemption; it leaves current autonomous work running.

Readiness and the next retry deadline use the same sampled time. The Owner
schedules that recorded deadline even when it passes before the sleeper is
armed. A due wake refreshes readiness while an autonomous turn holds the slot;
the next safe boundary can then checkpoint and release it for the original
operation. Claim still checks the authoritative store and preserves batch
membership, input, execution identity, and output route.

## Proactive and event intake

Proactive cycles already pass through `heartbeat_event_intake`, admitting the
ready durable snapshot in one batch. The shared `stimulus_ready_for_intake`
predicate also filters a proactive turn's successor-yield probe. In particular,
a HITL resolution still in the approval pending map cannot force a checkpoint
that intake has no way to advance. A later ready event can still request a turn;
yield diagnostics name only the ready successors.

Batch intake keeps the existing conversation routing boundary and one exact
HITL replay grant per turn. Reading or selecting events does not ACK them.
The exact source batch remains the authority for later settlement. Direct chat
requests remain Owner operations with their own completion and delivery
contracts; a proactive turn cannot silently mark all queued conversations done.

This distinction follows the separation between event notification and current
state reconciliation described by [Kubernetes controllers](https://kubernetes.io/docs/concepts/architecture/controller/).
MASC additionally preserves each command's execution and reply obligation.

## Verification scope

`test_keeper_owner` covers retained approval waits, autonomous progress during
backoff, readiness refresh, original operation identity, and retry wake timing.
`test_keeper_connector_attention_batch` exercises the actual proactive boundary
against a pending approval and a later ready event, checks agreement with batch
intake, and verifies both durable sources survive observation and selection.
Its existing scenarios cover all-ready batching and routing/ACK boundaries.

These source and test changes do not demonstrate a deployed binary, live Keeper
latency, or TUI status rendering. Those require separate runtime evidence.
