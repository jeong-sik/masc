# RFC: Keeper conversation and non-blocking HITL

- Status: Accepted
- Updated: 2026-07-21 (approval-wake settlement: delivery, not consumption)

Conversation, Gate request list, and request detail are projections of the same
durable Gate journal. A deep link carries the opaque correlation id and exact
Keeper lane; it does not expose a product/tool authorization class.

Pending HITL is shown as one request-local activity. The Keeper can continue
other work, and unrelated Keepers remain active. Approve creates a one-shot
grant and wakes only the origin lane. Reject/Edit stores typed rationale/input
for the next LLM turn and does not grant execution.

## Approval-wake settlement (2026-07-21 amendment, #25539)

The approval wake's job is DELIVERY, not consumption. Whether the model spends
the grant during the woken turn is the model's own non-deterministic decision
and never a settlement condition.

- A wake turn that completes settles as Ack regardless of grant state. The
  original settlement requeued whenever the grant was still unconsumed, so a
  keeper that kept doing other work re-fired on every heartbeat cycle —
  measured: 8,349 requeue receipts across 8 keepers over ~42h, one grant
  spinning 657 times. The same applies when the grant store cannot be read at
  settlement time: the grant is durable either way and the completed turn is
  the settlement authority.
- A wake turn that does not complete (busy, cancelled, failed, skipped)
  follows its ordinary typed settlement, so delivery itself is retried.
- Ack does not spend or expire the authorization. The one-shot grant remains
  durably spendable in the approval store, observable via
  `approved_resolution_state` and the resolved surface; a later attempt whose
  keeper, opaque operation identity, and canonical input match still consumes
  it exactly once. An authorization the keeper never re-attempts stays
  recorded rather than silently vanishing.
- Retry ceilings or time-based cooldowns on the wake are rejected shapes for
  this boundary: the root cause was the settlement condition (consumption)
  belonging to the model, not an unbounded-retry defect in the queue.
