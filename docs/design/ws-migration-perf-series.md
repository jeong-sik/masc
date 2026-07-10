---
status: superseded
last_verified: 2026-07-10
code_refs:
  - lib/server/server_mcp_transport_ws.ml
  - lib/sse.ml
  - lib/transport_metrics.ml
  - lib/server/masc_grpc_service.ml
  - dashboard/src/dashboard-ws.ts
  - dashboard/src/sse.ts
  - dashboard/src/components/transport-health.ts
---

# WS Migration Performance Series

> Status: Superseded by the WS-primary/authenticated-SSE fallback lifecycle in
> `docs/sse-ws-cutover.md`. The analysis below is retained as historical
> performance context and is not a current transport topology description.
> Date: 2026-04-25
> PRs: #10089, #10096, #10098, #10102, #10104, #10106, #10107,
> #10112, #10114, #10117, #10119 (RFC), #10120 (chore)

## 1. Context

The dashboard originally consumed server push traffic over Server-Sent
Events (`/sse`).  The migration to a long-lived WebSocket channel
(`/ws`) has been under way for weeks, but the work landed as many
small slices and left the system in a **parallel mode**:

- `dashboard/src/app.ts:111-112` opens the WS connection and then
  `connectSSE()` opens the SSE EventSource as well.
- On the server, `broadcast_impl` (`lib/sse.ml:640-655`) fans every
  event through two paths:
  1. The `clients_snapshot` loop delivers to direct SSE subscribers.
  2. `notify_external_subscribers event` delivers to every registered
     external subscriber.  **WS sessions are registered as external
     subscribers** (`server_ws_standalone.ml:43-54` and
     `server_mcp_transport_ws.ml:424-435`), so every broadcast also
     fires the WS fan-out.

The combined effect is that a dashboard tab receives every event
twice, processes it twice, and hydrates its store twice.  The
delivery works, but the migration is not finished — the whole point
of WS is to make SSE redundant, and right now the server is paying
for both.

This document describes the perf/observability series that addresses
the measurable symptoms of the parallel mode and sets the stage for
cutover.

## 2. Problem decomposition

Three categories of cost were identified:

| Category | Where it happens | Symptom |
|----------|------------------|---------|
| Parse amplification | `dashboard_delta_for_sse` was called per session per event and called `Yojson.Safe.from_string` every time on the identical string. | CPU scales with `sessions × events/s`. |
| Byte-copy amplification | Same shape as parse amplification, but at the `Bytes.of_string sse_event` layer for the raw-forward path. | GC pressure scales with `sessions × events/s × event_size`. |
| Unbounded client buffer growth | The server had no way to know when a client was falling behind.  A slow tab accumulated deltas in `WebSocket.bufferedAmount` without any backpressure. | Browser OOM / connection drops under chronic slowness. |
| Duplicate delivery | Parallel SSE + WS means the same data lands on the client twice. | Wasted bandwidth, double store hydration. |
| Opaque operational state | Every optimisation and backpressure signal was invisible except via external telemetry. | Operators could not tell the optimisations from a fresh idle server. |

## 3. The seven PRs

Each PR targets one of the problems above.  They are deliberately
narrow so review can land in any order.

### 3.1 #10089 — parse cache (server→client, CPU)

Introduces a module-local
`parse_cache : (string * parsed_sse_event option) Atomic.t` keyed by
physical equality on the event string.
`Sse.notify_external_subscribers` delivers the same `string`
reference to every subscriber callback in sequence, so the first
session in the fan-out parses and stores; every subsequent session
reads the cached `(event_type, slice, payload)` tuple.

Per-session work drops from a full `Yojson.Safe.from_string` to a
`Hashtbl.mem` slice filter plus a `seq` allocation.

**Safety anchor**: parse is idempotent; the cache never returns a
different logical result for a distinct event.  Physical equality is
safe because the SSE fan-out loop holds the event string alive for
the duration of its iteration.

Counters added in the same PR:

- `masc_ws_parse_cache_hits_total`
- `masc_ws_parse_cache_misses_total`

Steady-state hit ratio approaches `(N-1)/N` as sessions grow.

### 3.2 #10096 — `bufferedAmount` observability (client→server, telemetry)

The TypeScript client already sends `WebSocket.bufferedAmount` in
every `dashboard/ack` notification.  The server used to discard the
field; this PR records it:

- `ws_session.dashboard_last_ack_seq` (monotonic — out-of-order acks
  never rewind).
- `ws_session.dashboard_last_buffered_amount`.

Dispatcher (`mcp_server_eio_protocol.handle_dashboard_ack_eio`)
accepts both `Int` and `Float` for JSON numeric latitude and drops
negative or non-finite values silently so a malformed client cannot
poison the histogram sum.

Counters added:

- `masc_ws_client_buffered_bytes` (Histogram — sum + auto `_count`)
- `masc_ws_client_acks_total` (Counter)

Nothing acts on these values yet; the PR is pure observation.

### 3.3 #10098 — bytes cache (server→client, GC)

Parallel structural fix to #10089, one layer down.  Where #10089
collapses JSON parses, #10098 collapses `Bytes.of_string sse_event`
allocations on the raw-SSE-forward path.

Safety was verified by reading `httpun-ws 0.2.0 Serialize.serialize_bytes`:

- `Server` mode does not call `apply_mask_bytes`, so the payload is
  never mutated.
- `Faraday.write_bytes` copies synchronously into the serializer's
  internal buffer, so the `Bytes.t` need only be valid during the
  synchronous `Wsd.send_bytes` call.

Both conditions hold on the server send path.

Delta sends stay on the allocating path because each session's delta
carries a unique `seq` and therefore a unique encoded string.

Counters added:

- `masc_ws_bytes_cache_hits_total`
- `masc_ws_bytes_cache_misses_total`

### 3.4 #10102 — WS-only cutover flag (client transport)

Attacks the parallel mode directly.  Adds a single resolver
(`dashboard/src/dashboard-ws-cutover.ts`) with three-level precedence:

1. `window.__MASC_DASHBOARD_WS_ONLY__ === true` — runtime injection
   for staged rollout.
2. `import.meta.env.VITE_DASHBOARD_WS_ONLY === 'true' | '1'` —
   build-time opt-in for per-deployment control.
3. `false` — default, existing behaviour preserved.

When the flag is on, `app.ts` skips `connectSSE()` and
`disconnectSSE()`.  `connectDashboardWS` is always called.

**Safety anchor**: the WS session is registered as an SSE external
subscriber, and `send_dashboard_or_raw_sse` routes every event either
as a `dashboard/delta` (for subscribed slices) or as a raw SSE text
forward (otherwise).  Both paths feed the same client-side store
hydration that `/sse` would have driven.  Every event the direct SSE
connection would have delivered is already delivered through the WS
channel.

### 3.5 #10104 — backpressure gate (server→client, safety)

Stacked on #10096.  Uses the `dashboard_last_buffered_amount` field
to gate outbound deliveries:

- `MASC_WS_CLIENT_BUFFER_LIMIT_BYTES` (default 1 MiB).  `0` disables
  the gate entirely.
- When `session.dashboard_last_buffered_amount >= limit`,
  `send_dashboard_or_raw_sse` short-circuits with `true` and bumps
  `masc_ws_throttled_deliveries_total`.
- Returning `true` keeps the SSE external-subscriber loop from
  treating this as a fatal send failure.  The session is still live;
  the next ack after the client drains lets traffic resume.

Design decision — **skip rather than queue server-side**: queueing
would move the backlog from the client's transport buffer to the
server's OCaml heap, which is worse (unbounded server growth instead
of bounded client staleness).  The client's periodic refresh catches
up after silences, so bounded staleness is the safer failure mode.

### 3.6 #10106 — transport-health payload expansion (wire format)

Surfaces all the counters added above inline in the existing
`transport_health_snapshot` event, under a new `websocket.delivery`
sub-object.  Read by **literal metric name** via
`metric_value_or_zero`, so this PR does not take a compile-time
dependency on any particular other WS PR.  If the underlying metric
has not been registered yet the read returns 0.0, which surfaces as
"nothing observed" rather than a schema error.

The client schema
(`dashboard/src/api/schemas/transport-health.ts`) adds
`WebsocketDeliverySchema` with a matching zero default via
`fallback(...)`.  Older servers that do not know the field still
parse cleanly.

### 3.7 #10107 — dashboard UI hookup (rendering)

Stacked on #10106.  Adds four rows to the WebSocket card in the
transport-health strip:

| label | value | sub |
|-------|-------|-----|
| 파싱 캐시 | hit % | `"{hits} 히트 / {misses} 미스"` |
| 바이트 캐시 | hit % | same pattern |
| 클라이언트 드레인 | avg buffered bytes per ack | `"{acks} ack"` |
| 억제된 전달 | throttled counter | `정상` / `서킷 오픈` |

`websocketTone` downgrades `'ok'` → `'warn'` when
`throttled_deliveries > 0`.  A `'bad'` base (listener down) stays
`'bad'`.

Two format helpers (`formatHitRate`, `formatAvgBufferedBytes`) return
`"—"` on idle inputs so a freshly-started server does not render
`0%` as if the cache were failing.

### 3.8 #10112 — gRPC events_dropped counter (server, observability)

Mirrors #10104's drop signal for the gRPC subscriber path.  The
gRPC callback in `lib/server/masc_grpc_service.ml:484` already drops
events when its output stream's buffer is near capacity, but the
drop was visible only in logs.

Adds `masc_grpc_events_dropped_total` (Counter) and surfaces it in
the `grpc` section of `transport_health_json` alongside
`events_delivered`.  The client schema's `GrpcSchema` gains
`events_dropped` with `fallback(number(), 0)` for cross-version
compatibility.

No behaviour change in the drop path itself — same threshold, same
log line.  The PR only makes the existing pressure visible in
metrics.

### 3.9 #10114 — dashboard UI for gRPC drops (rendering)

Stacked on #10112.  Adds an `Events Dropped` row to the gRPC
SectionCard:

| label | value | sub |
|-------|-------|-----|
| Events Dropped | counter | `정상` / `버퍼 포화` |

`grpcTone` downgrades `'ok'` → `'warn'` on `events_dropped > 0`,
matching the `websocketTone` behaviour from #10107.

The sub text uses `'버퍼 포화'` for gRPC vs `'서킷 오픈'` for WS
deliberately — both mean "capacity pressure, attention required",
but they describe the actual mechanism faithfully (gate threshold
vs buffer-full drop).  Same word for different mechanisms would
obscure the distinction operators need when triaging.

### 3.10 #10117 — gRPC stream buffer threshold tunable (server, control)

Closes the WS/gRPC symmetry on the control side.  WS got
`MASC_WS_CLIENT_BUFFER_LIMIT_BYTES` in #10104; gRPC's drop
threshold remained hard-coded at 48.

Adds `MASC_GRPC_STREAM_MAX_BUFFER` (default 48) read once per
subscribe — existing streams are not disturbed mid-flight by a
config change; newly-subscribing clients pick up the new value.
Exported as `Masc_grpc_service.stream_max_buffer ()` so tests can
assert the effective value without instrumenting the full subscribe
handler.

Together with #10112's counter and #10114's UI, this completes the
operator-visible "observe + control" pair for the gRPC drop path
that mirrors the WS path.

### 3.11 #10119 — slice-indexed fanout RFC (design)

Documentation only.  Captures the proposal for the largest deferred
perf lever — replacing `Sse.notify_external_subscribers`'s `O(N)`
iteration with a `slice → session set` side index in the WS
transport, so slice-scoped events skip the `N - S` unnecessary
raw-SSE-forward writes.

Phased: bookkeeping (Phase 1) and fanout rewiring (Phase 2) can
land independently.  Includes alternatives considered, concurrency
analysis, performance projection (`N=20, S=5` → 75% fewer Wsd
writes per slice-scoped event), and a flagged rollout plan.

No code change.  See §5 for status against the deferred-decisions
list.

### 3.12 #10120 — micro-cleanup in dashboard_snapshot (chore)

One-line chore.  Removes an identity `List.map` that was a no-op
at the end of `dashboard_snapshot`'s pipeline and switches the
sort comparator from polymorphic `compare` to typed
`String.compare`.  No behaviour change.

Standalone PR rather than bundling into a larger one keeps each
PR's scope honest — the cleanup is reviewable in 30 seconds and
mixing it into a parse-cache or schema PR would have made those
slightly less reviewable.

## 4. Design principles applied

### Physical equality on the broadcast reference

Both #10089 and #10098 key their caches by `==` on the input string.
This is safe because `Sse.notify_external_subscribers` delivers the
same reference to every subscriber callback in one fan-out, and
OCaml strings are immutable.  Fresh broadcasts invalidate naturally
— a new event has a new string identity.

The alternative (structural equality or content hash) would catch
more cases but also re-use stale payloads across distinct events.
Physical equality has tight-enough hit rate in practice (the common
case) and zero risk of false reuse.

### Read configuration on every call

`client_buffer_limit_bytes ()` in #10104 calls
`Env_config_core.get_int` on every send.  The lookup is an atomic
hashtable hit — cheap enough to not bother caching.  The upside is
that operators can retune without a restart; the downside is a few
cycles per send, which disappears into the `Wsd.send_bytes` cost.

### Drop, do not queue

#10104's gate drops over-threshold deliveries instead of queueing
server-side.  Queueing moves the backlog from the client's bounded
browser buffer to the server's unbounded OCaml heap — strictly
worse.  The client's periodic refresh catches up after silences, so
bounded client staleness is the safer failure mode.

### Literal-name metric reads at surface boundaries

#10106 reads the WS delivery counters by string constant rather than
by backend module-level constants.  This decouples the
consumer (transport-health) from the producers (the various WS PRs)
so they can merge in any order.  If a metric has not been registered
yet, `metric_value_or_zero` returns 0.0 — a semantically honest "no
data".

### Observation before action

#10096 ships pure observation before #10104 ships the gate that acts
on it.  This lets us pick the threshold from production distribution
rather than guessing.  The first conservative default (1 MiB) is a
starting point, tunable from the env at any time.

### Idle state reads as idle, not zero

Both the transport-health UI (#10107) and the cache helpers use
`"—"` or equivalent em-dash formatting when the observation count is
zero.  Rendering `0%` or `0 B` on a cold cache would look like a
failure; the dash reads as "nothing has happened yet", matching the
actual state of the system.

## 5. Deferred decisions

### Slice-indexed fan-out (RFC: #10119)

`Sse.notify_external_subscribers` still iterates every external
subscriber per broadcast.  Each WS session's callback runs the
`Hashtbl.mem session.dashboard_slices slice` filter individually, so
with `N` sessions there are `N` filter checks per event — and, more
costly, the catch-all `send_text_shared_checked` issues `N - S`
unnecessary `Wsd.send_bytes` writes for sessions whose route does
not match the event's slice.

A slice-indexed fan-out (`slice → session set` index, deliver only
to matching sessions) would eliminate the `N - S` writes.  The
detailed proposal — including the catch-all preservation strategy
for events without a slice mapping, the concurrency model that
reuses `sessions_mutex`, the phased rollout (Phase 1 bookkeeping,
Phase 2 rewiring), and the new `masc_ws_slice_fanout_skipped_total`
counter for verifying the win — lives in the RFC at
`docs/design/ws-slice-indexed-fanout-rfc.md` (#10119).

Status: proposal published, awaiting design review before
implementation.  Not in scope for the current series.

### Deletion of `/sse` and the direct SSE client path

#10102 adds a flag to skip the parallel `/sse` open but does not
remove the code.  Once operators have validated WS-only in
production and held at it for a sustained period, a follow-up should:

1. Default `wsOnly` to `true`.
2. Remove `connectSSE`, `disconnectSSE`, and the direct
   `/sse` HTTP handler.
3. Keep `dashboard/src/sse-store.ts` (the store itself is still
   consumed by the WS path via `routeServerPushEvent`).

No timeline; depends on production confidence in the WS path.

### gRPC subscriber symmetry (addressed in #10112, #10114, #10117)

The gRPC subscriber in `lib/server/masc_grpc_service.ml:477` had a
similar fan-out shape to WS but no drop signal.  This is now
covered:

- #10112 — `masc_grpc_events_dropped_total` counter and
  `grpc.events_dropped` payload field.
- #10114 — operator-visible row in the dashboard gRPC card.
- #10117 — `MASC_GRPC_STREAM_MAX_BUFFER` env knob to retune the
  drop threshold.

A wider `delivery` sub-object covering parse / encoding stats was
considered but skipped: gRPC has no parse cache (the SSE event is
forwarded as-is in the protobuf payload), and the encoding cost is
per-subscriber unique because of the per-session `seq` counter.
The four counters above are the meaningful surface; mirroring the
full WS `delivery` block would have added zero-valued fields.

## 6. Operational playbook

### Rolling out to production

1. Merge #10089 (parse cache + counters).  Watch
   `masc_ws_parse_cache_hits_total / (hits + misses)` settle near
   `(N-1)/N` during steady-state dashboard traffic.
2. Merge #10098 (bytes cache + counters).  Same pattern for
   `masc_ws_bytes_cache_*`.
3. Merge #10096 (bufferedAmount observation).  Let it run for at
   least a few days to establish the distribution of
   `masc_ws_client_buffered_bytes`.  Pick a threshold from the p99.
4. Merge #10104 (backpressure gate), setting
   `MASC_WS_CLIENT_BUFFER_LIMIT_BYTES` to the chosen threshold.
   Keep 0 (disabled) if operators prefer observation-only first.
5. Merge #10106 and #10107 together (server payload + UI).
   Dashboard now displays the full delivery picture.
6. Merge #10102 (WS-only flag).  Roll out behind
   `VITE_DASHBOARD_WS_ONLY=1` in one environment; watch for event
   loss in the store relative to parallel mode.

### Incident handling

| symptom | metric | remedy |
|---------|--------|--------|
| Dashboard not updating | `masc_ws_sessions_total == 0` | WS listener down; check server logs and `listen_status`. |
| Dashboard stale despite WS up | `masc_ws_throttled_deliveries_total` climbing | Gate firing; inspect client with high `bufferedAmount`.  Consider raising the limit if a legitimate client. |
| High server CPU | `masc_ws_parse_cache_hits_total / total` low | Cache not effective; likely broadcast fan-out delivering distinct event strings (investigate if upstream is regenerating events). |
| High server GC | `masc_ws_bytes_cache_hits_total / total` low | Same analysis for the bytes layer. |

### Rolling back

All seven PRs are additive and flagged.  Emergency rollback steps:

- `MASC_WS_CLIENT_BUFFER_LIMIT_BYTES=0` disables the gate without a
  deploy (#10104).
- Unsetting `VITE_DASHBOARD_WS_ONLY` reverts to parallel mode on the
  next dashboard refresh (#10102).
- The other five PRs are pure perf/observability layers; disabling
  them requires a revert, but none of them change wire format or
  client behaviour.

## 7. References

- `lib/sse.ml` — the broadcast mechanism this series optimises around.
- `lib/server/server_mcp_transport_ws.ml` — WS session state, parse
  cache, bytes cache, delta construction, backpressure gate.
- `lib/server/server_ws_standalone.ml` — handshake and subscriber
  registration for the standalone WS port.
- `lib/transport_metrics.ml` — transport metric helpers and the
  `transport_health_json` payload.
- `dashboard/src/dashboard-ws.ts` — client WS handshake, ack,
  subscribe/delta handling.
- `dashboard/src/sse.ts` — legacy SSE client (still active in
  parallel mode; cutover lever in #10102).
- `dashboard/src/components/transport-health.ts` — operator-facing
  UI.

## 8. Change log

| Date | Change |
|------|--------|
| 2026-04-25 | Initial draft, covers #10089 through #10107. |
| 2026-04-25 | Add §3.8–§3.12 for the four post-draft PRs (gRPC observability triple #10112/#10114/#10117, the slice-indexed RFC #10119, and the dashboard_snapshot chore #10120).  Update §5 deferred decisions: slice-indexed fan-out has an RFC (#10119); gRPC subscriber symmetry has landed.  Add `lib/server/masc_grpc_service.ml` to `code_refs`. |
