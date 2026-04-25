---
status: rfc
last_verified: 2026-04-25
code_refs:
  - lib/sse.ml
  - lib/server/server_mcp_transport_ws.ml
  - lib/server/server_ws_standalone.ml
  - lib/grpc/masc_grpc_service.ml
---

# WS Slice-Indexed Fan-Out (RFC)

> Status: RFC — proposal only, no code
> Date: 2026-04-25
> Depends on: `ws-migration-perf-series.md` (#10110)
> Successor to: deferred decision in the migration perf series

## 1. Problem

`Sse.notify_external_subscribers` iterates every registered external
subscriber for every broadcast, regardless of whether that subscriber
cares about the event:

```ocaml
(* lib/sse.ml:537 *)
let notify_external_subscribers event =
  let snapshot =
    SMap.fold (fun _ v acc -> v :: acc)
      (Atomic.get external_subscribers).subscribers []
  in
  ...
  List.iter (fun (sub : external_subscriber) ->
    if not (sub.is_alive ()) then dead := sub.sub_id :: !dead
    else begin try sub.callback event with ...
    end
  ) snapshot;
```

Each WS session's callback filters internally via
`Hashtbl.mem session.dashboard_slices slice`.  For `N` WS sessions
and `M` events per second, the server runs `N × M` `is_alive` calls
and slice-filter checks.  With the parse cache (#10089) and bytes
cache (#10098) the *work per iteration* is cheap, but the iteration
itself is `O(N × M)` — an upper bound the series has not addressed.

When the dashboard fleet grows (multi-tab operator, multiple
operators), the proportionality becomes visible:

- 20 authenticated WS sessions, each subscribed to the default
  `{shell, namespace, transport}` plus a route-specific slice.
- An `operator_snapshot` event fires every 30s per keeper; 9 keepers
  → 0.3 events/s.
- Cache-effective work: 20 × 0.3 = 6 `Hashtbl.mem` checks/s — fine.

But for traffic-heavy slices like `execution_snapshot` at 5 events/s
with 20 sessions, that's `20 × 5 = 100` iteration ticks/s — still
cheap, but now consider the `send_text_shared_checked` path: every
session that authenticated but doesn't match the slice receives the
event as a raw SSE forward.  For an event that maps to `execution`
but only 5 sessions subscribe to `execution`, 15 sessions still send
a frame.  That's 15 unnecessary Wsd writes/event.

The per-event raw-forward path is the real cost, not the filter
check.

## 2. Goals

1. Eliminate the raw-SSE-forward writes to sessions whose route does
   not subscribe to the event's slice.
2. Preserve existing semantics for subscribers that *should* receive
   an event (authenticated sessions whose slice set includes the
   event's slice; unauthenticated sessions; gRPC subscribers).
3. No regression in parse cache / bytes cache hit rates.
4. No wire format change.

## 3. Non-goals

- Parallel fanout (`Eio.Fiber.List.iter`).  Current callbacks are
  non-blocking (`Wsd.send_bytes` enqueues into faraday, gRPC uses a
  capacity-gated stream).  Serial is fine for the common case, and
  moving to parallel adds fiber setup cost that dominates for small
  fanouts.
- Changing `Sse.subscribe_external` signature.  That module is
  shared with gRPC (`lib/grpc/masc_grpc_service.ml:477`) and other
  non-dashboard subscribers.  Changing its contract ripples to code
  not covered by this migration.
- Deleting the raw-SSE-forward path for unauthenticated sessions.
  Anonymous WS connections still exist for legacy reasons and should
  continue to receive all events.

## 4. Proposal

Maintain a **side index** within `server_mcp_transport_ws.ml` that
maps each active dashboard slice to the subset of sessions currently
subscribed to it.  The SSE fanout still calls every registered
external subscriber, but the WS callback is split into two phases:

### 4.1 Registration time

`dashboard_subscribe ~session_id ?route ~slices` already writes to
`session.dashboard_slices`.  It would additionally:

- For each slice being added: insert the session into
  `slice_index.(slice)`.
- For each slice being removed: remove the session from
  `slice_index.(slice)`.

`dashboard_unsubscribe` follows the same pattern on removal.
`cleanup_session` must also remove the session from every slice it
was subscribed to, to avoid stale entries.

### 4.2 Fanout time

The existing callback stays registered with `Sse.subscribe_external`.
When called:

1. Parse the event via `parse_sse_dashboard_event` (cached).
2. If the parse yields a known slice, look up
   `slice_index.(slice)` → session set.  For each session in that
   set, build and send the delta.  **Skip raw-forward.**
3. If the parse yields no slice (event_type not in the table) or
   the parse failed, fall back to the current behaviour: raw-forward
   via `send_text_shared_checked`.

Step 3 preserves correctness for events outside the slice vocabulary.
Step 2 eliminates the N-M raw-forward writes.

One subtlety: the current code forwards raw SSE to **authenticated**
sessions whose slice filter missed.  With the proposal,
authenticated sessions subscribed to any slice that *is* in the
vocabulary would no longer receive non-matching events.  The client
today uses `handleRawPush` to hydrate the store for such events,
so this is a behaviour change.

The mitigation: define a "catch-all" implicit subscription.  Every
authenticated session is implicitly subscribed to a synthetic
`*` (or equivalently, a "default" entry in the index keyed by
session set).  Events whose slice parse miss fanout to this set.
This matches the current behaviour byte-for-byte while still letting
slice-matching events skip non-subscribers.

### 4.3 Data structure choice

Two candidates:

- **`(string, session Queue.t) Hashtbl.t`** — simple, but removal
  requires a linear scan of the Queue.
- **`(string, session IntMap.t) Hashtbl.t` keyed by session's int id** —
  O(log n) add/remove, ordered iteration.

The session count is small (tens, not thousands).  A Queue with
rebuild-on-remove is likely simpler and faster in practice, at the
cost of some per-remove allocation.  Benchmarks would decide; either
fits the interface.

### 4.4 Concurrency

The index lives in the same mutex domain as `sessions` itself:
`sessions_mutex`.  All index mutations go through
`with_sessions_rw`, the same helper that guards `sessions`.

Reads during fanout would be a snapshot-at-start-of-iteration, which
is already how `notify_external_subscribers` reads its subscriber
list (`SMap.fold` under `Atomic.get`).  The index snapshot would
likewise fold under the lock and iterate after release, so a
concurrent subscribe/unsubscribe during a fanout affects the *next*
fanout, not the current one.

## 5. Performance analysis

### 5.1 What changes

For a slice-scoped event with `S` subscribers out of `N` total
authenticated sessions:

| metric | before | after |
|--------|--------|-------|
| `Hashtbl.mem` slice filter checks | N | 0 (replaced by set lookup) |
| `Wsd.send_bytes` calls | N (S deltas + (N-S) raw forwards) | S deltas |
| `Bytes.of_string` allocations | S + 1 (one shared bytes for raw-forward) | S (delta is per-session unique) |
| Delta JSON encodes | S | S (unchanged — each is unique seq) |

The wire-level savings are the `(N - S)` raw forwards per event.
For `N = 20, S = 5` that is 75% fewer Wsd writes per slice-scoped
event.

### 5.2 What does not change

- Parse cache and bytes cache behaviour are identical.  The parse
  cache already pays `O(1)` per broadcast; the bytes cache still
  serves the catch-all raw-forward path.
- gRPC subscribers.  The index is WS-only; gRPC continues through
  `notify_external_subscribers`.  Their path is already capacity-
  gated (`MASC_GRPC_STREAM_MAX_BUFFER`, #10117) so the performance
  profile is different.
- Delivery semantics for the catch-all (non-slice) events.

### 5.3 What might get worse

- Index maintenance adds a small cost to subscribe/unsubscribe.
  Subscribes are rare (once per route change, ~seconds apart), so
  this is negligible.
- Catch-all fanout still iterates every authenticated session,
  same as today.  No regression, no improvement.
- If subscribe has a race with a concurrent cleanup (session is
  being torn down while subscribing), the index needs the same
  is-alive check the existing callback uses.  See §6.

## 6. Concerns

### 6.1 Liveness check

The existing callback does `if not (sub.is_alive ()) then
dead := sub.sub_id :: !dead`.  A dead subscriber is reaped by SSE.

In the slice-indexed path, a session in `slice_index.(slice)` that
has since been closed should not receive a delta attempt.  Two
options:

- Cross-check `session.closed` and `Httpun_ws.Wsd.is_closed
  session.wsd` at fanout time (same check `send_frame_bytes`
  already does).  Dead sessions are skipped without failure.
- Remove from the index at `cleanup_session` time.  Needed anyway
  to avoid memory growth.

Both are cheap.  Do both.

### 6.2 Catch-all fanout regression

The catch-all (events without a slice mapping) still needs to reach
every authenticated session.  The simplest implementation iterates
`sessions` under the mutex, same as the current
`notify_external_subscribers` path.  No regression.

### 6.3 Route change mid-broadcast

If a session changes its subscription via `dashboard/subscribe` in
the middle of a fanout, the snapshot-at-start model means the
session receives events matching the **old** subscription until the
fanout ends.  This is consistent with the current behaviour —
`Hashtbl` reads in the WS callback are not synchronised with
subscribe writes.

### 6.4 Parse cache coupling

`parse_sse_dashboard_event` is currently a private helper in
`server_mcp_transport_ws.ml`.  The slice-indexed fanout would
consume its output (the parsed slice) *before* iterating.  No
visibility change needed — both the consumer (new fanout loop) and
the producer (parse cache) live in the same module.

### 6.5 Telemetry

The existing counters (`parse_cache_*`, `bytes_cache_*`,
`throttled_deliveries`) continue to work.  A new counter
`masc_ws_slice_fanout_skipped_total` would surface the number of
sessions skipped per slice-scoped event — the direct measure of
this proposal's benefit.

## 7. Test strategy

The current test suite covers:

- parse cache hit/miss behaviour (`test_ws_transport.ml parse_cache`)
- bytes cache reuse (`test_ws_transport.ml bytes_cache`)
- ack observability (`test_ws_transport.ml ack_observability`)
- backpressure gate (`test_ws_transport.ml backpressure_gate`)
- SSE external subscriber fanout (`test_sse_external_sub.ml`)
- WS + SSE forwarding integration (`test_transport_integration.ml
  ws_sse`)

New test cases needed:

- `slice_index` maintenance:
  - subscribe adds session to index entry.
  - unsubscribe removes it.
  - cleanup removes from all slice entries.
- Slice-scoped event fanout:
  - 3 sessions, 2 subscribed to `execution`, 1 not.  Broadcast an
    `execution_snapshot`.  Assert only the 2 subscribed sessions
    saw a delta, the third received nothing.
- Catch-all fanout regression:
  - 3 sessions.  Broadcast an event whose type is not in the slice
    vocabulary.  Assert all 3 received the raw forward.
- Skipped-counter observability:
  - `masc_ws_slice_fanout_skipped_total` advances by `N - S` for a
    slice-scoped event.

## 8. Implementation phasing

This RFC describes a single coherent change but the implementation
could land in two PRs:

- **Phase 1** — add the index and maintain it (subscribe /
  unsubscribe / cleanup hooks) but keep the fanout path unchanged.
  This lands the bookkeeping without changing behaviour, so any
  regression is obviously not from the index.
- **Phase 2** — rewire the WS callback to consult the index for
  slice-scoped events.  This is where the behaviour change is.

Phase 1 can also expose a new `dashboard/diagnostics` field that
echoes the index state, useful for debugging a production issue
without a server-side print.

## 9. Alternatives considered

### 9.1 Inline slice filter in `Sse.subscribe_external`

Extend `subscribe_external` to accept an optional
`slice_filter : string option -> bool`.  The SSE fanout would skip
subscribers whose filter returns false.

Rejected: changes the shared `Sse` API for a WS-specific concern.
Bleeds into `grpc`, `webrtc`, and any future subscriber.

### 9.2 Make the parse cache produce (slice × payload) pairs consumed by the fanout

Instead of each session re-filtering, the fanout layer could look
up the session set once.  But this is exactly what the proposed
slice-index does; the difference is just where the index lives.

### 9.3 Remove raw-SSE-forward for authenticated sessions entirely

Require the client to subscribe to every slice it cares about.
Rejected: breaks the current `handleRawPush` path that hydrates the
store for events outside the slice vocabulary, and would require a
client-side migration to fully enumerate slice subscriptions.

## 10. Rollout plan

1. Land Phase 1 (index bookkeeping) behind a flag
   `MASC_WS_SLICE_INDEX_ENABLED` (default off).  Tests exercise
   both on and off.
2. Enable the flag in one environment, watch
   `masc_ws_slice_fanout_skipped_total` to confirm skips are
   happening.  Compare dashboard freshness with and without the flag.
3. Land Phase 2 (fanout rewiring) behind the same flag.
4. Flip the default on after a sustained period.
5. Remove the flag once no rollback is needed.

## 11. References

- `docs/design/ws-migration-perf-series.md` — parent series that
  defers this decision.
- `lib/sse.ml` — broadcast and external subscriber mechanism.
- `lib/server/server_mcp_transport_ws.ml` — parse cache, bytes
  cache, subscribe/unsubscribe, send paths.
- `lib/grpc/masc_grpc_service.ml` — the other external subscriber
  (not affected by this RFC, but a shape reference for why the
  proposal stays WS-only).

## 12. Change log

| Date | Change |
|------|--------|
| 2026-04-25 | Initial RFC draft. |
