---
status: withdrawn
updated: 2026-07-13
---

# Withdrawn external-attention policy store

Connector and channel input enters the originating Keeper's durable FIFO lane.
Exact external event ids provide replay idempotency only. Urgency scores,
dedupe content keys, stale-claim timeouts, cooldowns, and attention status bands
do not suppress, reprioritize, or auto-resolve input.
