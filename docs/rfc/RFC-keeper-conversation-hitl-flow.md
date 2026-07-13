# RFC: Keeper conversation and non-blocking HITL

- Status: Accepted
- Updated: 2026-07-13

Conversation, Gate request list, and request detail are projections of the same
durable Gate journal. A deep link carries the opaque correlation id and exact
Keeper lane; it does not expose a product/tool authorization class.

Pending HITL is shown as one request-local activity. The Keeper can continue
other work, and unrelated Keepers remain active. Approve creates a one-shot
grant and wakes only the origin lane. Reject/Edit stores typed rationale/input
for the next LLM turn and does not grant execution.
