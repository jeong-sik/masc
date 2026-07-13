# RFC-0257 — Per-Keeper memory execution lane

- Status: Draft
- Updated: 2026-07-13
- Boundary: Memory work is lane-local; provider calls are OAS calls.

## Contract

Each Keeper owns one ordered memory lane, separate from its interactive turn
lane. Memory extraction, storage, compaction, and forgetting for Keeper A never
acquire a fleet-wide permit and never block Keeper B.

Submissions are durable FIFO work, not a bounded best-effort queue. Saturation,
provider latency, token use, and queue depth are observations only: work is not
dropped because a fixed count or timeout was reached. An OAS provider result is
recorded explicitly. A completed or failed long-running memory job wakes only
its originating Keeper lane.

The submitted unit closes over immutable turn input. Mutable on-disk state is
serialized within that Keeper's memory lane. Fibers are owned by a structured
`Eio.Switch`; cancellation records the unconsumed job so it can be resumed
rather than silently discarded.

There is no cross-Keeper provider slot, fixed wait window, environment-driven
capacity gate, or inline fallback that bypasses the lane.

## Verification

- Same-Keeper jobs execute in FIFO order.
- Different Keepers progress concurrently.
- Restart preserves unconsumed work.
- Provider failure is explicit and does not consume the job silently.
- Completion wakes only the originating Keeper.
