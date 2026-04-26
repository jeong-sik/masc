# System Event and Snapshot Inventory

Validated against the current code on 2026-04-16.

This document is the operator-facing SSOT for:

- dashboard-visible system events
- snapshot surfaces and their refresh timing
- the actual trigger semantics of `keeper_composite_changed`
- when `operator_digest` is computed versus when it is broadcast

## Scope

- Dashboard event type union: `dashboard/src/types/sse.ts`
- Keeper composite signal path: `lib/keeper/keeper_registry.ml`
- Keeper heartbeat snapshot path: `lib/keeper/keeper_keepalive.ml`
- Server-push snapshot loops: `lib/server/server_dashboard_http_core.ml`, `lib/server/server_dashboard_http_execution_surfaces.ml`
- OAS Event_bus bridge: `lib/oas_events.ml`, `lib/oas_event_bridge.ml`

## Read Model Rules

- SSE is freshness transport, not the authoritative read model.
- `keeper_composite_changed` is signal-only. Consumers re-fetch `/api/v1/keepers/:name/composite`.
- `operator_snapshot` and `operator_digest` are cached server-push surfaces. Default HTTP reads usually return the cache.
- OAS bridge events are replayable because `oas_event_bridge` persists them under `.masc/oas-events/`.

## Timing and Trigger Semantics

| Surface / event | When it happens | Payload model | Notes |
| --- | --- | --- | --- |
| `keeper_composite_changed` | After every successful `Keeper_registry.dispatch_event*` application, including no-phase-change updates | Signal-only: `{name, ts_unix}` | Consumers must re-fetch the full composite payload. |
| `keeper_heartbeat` | When a heartbeat snapshot is actually written | Lightweight SSE envelope | Not emitted on every keepalive cycle. |
| `oas:masc:keeper:snapshot` | Same moment as `keeper_heartbeat` | OAS Event_bus custom event relayed to SSE | Durable via `.masc/oas-events/`. |
| `operator_snapshot` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Default root/summary HTTP path returns cache. |
| `operator_digest` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Default root HTTP path returns cache; non-default requests recompute. |
| `execution_snapshot` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Used by execution dashboard surfaces. |
| `transport_health_snapshot` | Background proactive refresh loop | Cached payload wrapped as `{type, payload, ts_unix}` | Used for transport diagnostics. |
| `namespace_truth_snapshot` | After namespace-truth recomposition from cached surfaces | Cached payload wrapped as `{type, payload, ts_unix}` | `room_truth_snapshot` is the legacy alias. |
| `room_truth_snapshot` | Emitted together with `namespace_truth_snapshot` | Same payload as namespace truth | Compatibility alias; not a distinct read model. |

## `keeper_composite_changed`

### What it really means

- It means “a keeper registry state-machine event was applied; the composite view may have changed.”
- It does not carry the composite snapshot itself.
- It is emitted both when phase changes and when the event updates conditions without a phase change.

### Exact producer

- `Keeper_registry.dispatch_event_with_audit` emits `keeper_composite_changed` after the registry entry is updated.
- This happens in both the phase-change branch and the no-phase-change success branch.
- Turn sub-FSM mutation helpers also emit `keeper_composite_changed` after they update observer-visible turn/composite fields.

### Direct turn helper trigger cases

The following direct registry mutation helpers update fields that the composite observer reads, and now emit `keeper_composite_changed` when they actually change a live turn observation:

- `mark_turn_started`
- `mark_turn_measurement`
- `set_turn_decision_stage`
- `set_turn_cascade_state`
- `set_turn_phase`
- `set_turn_selected_model`
- `mark_turn_finished`

Current code cross-check: `keeper_unified_turn.ml` still calls these helpers directly in the live turn path
(`mark_turn_started`, `mark_turn_measurement`, `set_turn_*`, `mark_turn_finished`), so this is not dead API surface. The helpers are active and are part of the composite freshness contract.

| Helper | Current direct caller(s) | Composite fields touched | Emits `keeper_composite_changed`? |
| --- | --- | --- | --- |
| `mark_turn_started` | live turn entry | installs `current_turn_observation`, initializes `turn_phase=prompting`, resets compaction stage | Yes |
| `mark_turn_measurement` | live turn measurement bind | binds pending measurement into the current turn snapshot | Yes, when a pending measurement exists |
| `set_turn_decision_stage` | live turn decision path | updates `decision_stage` to `guard_ok` when measurement is present | Yes, when a live turn exists |
| `set_turn_cascade_state` | cascade attempt path | updates `cascade_state`, and via `turn_phase_of_cascade_state` also changes `turn_phase` | Yes, when a live turn exists |
| `set_turn_phase` | terminal/compaction/error paths | forces `turn_phase` during terminal/compaction/error paths | Yes, when a live turn exists |
| `set_turn_selected_model` | successful cascade attempt path | stores `selected_model` after a successful cascade attempt | Yes, when a live turn exists |
| `mark_turn_finished` | turn finally block | clears `current_turn_observation`, ending the live turn snapshot and freezing `last_completed_turn` | Yes, when a live turn exists |

By contrast, the nearby `dispatch_keeper_phase_event` calls in the overflow-retry path
(`keeper_unified_turn.ml:1939-1946`) eventually go through
`Keeper_registry.dispatch_event_with_audit`, so those phase-machine events *do* emit
`keeper_composite_changed`. Direct turn-mutation helpers and state-machine dispatch now both produce the same signal-only tick, while consumers still re-fetch `/api/v1/keepers/:name/composite` for the authoritative payload.

## Keeper Heartbeat Snapshot Timing

### Base timing

- Keepalive loop base interval: `30s`
- Keepalive jitter: `base * 20%`
- Snapshot write interval: runtime param `keeper.snapshot_sec`
- Current default `keeper.snapshot_sec`: `300s`

### Actual behavior

- The keepalive loop wakes roughly every `30s + jitter`.
- Snapshot write is gated by `now_ts - last_snapshot_ts >= snapshot_interval_sec`.
- Smart heartbeat may skip busy or idle cycles, so wall-clock distance between snapshots can exceed the base keepalive interval.
- When a snapshot is written, three things happen together:
  - JSONL metrics append
  - `keeper_heartbeat` SSE broadcast
  - `masc:keeper:snapshot` OAS custom event publish, later relayed as `oas:masc:keeper:snapshot`

### Practical consequence

If you are watching dashboard freshness:

- `keeper_heartbeat` is a snapshot cadence signal, not a raw “loop tick” signal.
- absence of `keeper_heartbeat` for under `300s` is not automatically suspicious
- absence beyond the expected snapshot interval should be interpreted together with smart-heartbeat gating and lifecycle events

## `operator_digest`

### Background refresh path

- Refresh interval source: `MASC_OPERATOR_REFRESH_INTERVAL_S`
- Default interval: `60s`
- Warm-cache delay on cold start: `150s`
- Refresh loop uses `Proactive_refresh`

### HTTP read path

- Default namespace/root request returns `_operator_digest_cache`.
- Non-default requests recompute immediately:
  - non-root `target_type`
  - `target_id`
  - explicit `include_workers`
  - explicit actor override

### Broadcast path

- Successful recompute stores the cache first, then calls the operator digest broadcast hook.
- Broadcast is changed-only.
- If the JSON payload hash matches the previous payload, SSE broadcast is skipped.

### Practical consequence

- “digest happened” and “`operator_digest` SSE arrived” are different events.
- The digest may recompute without any outbound SSE if the payload is unchanged.
- A default HTTP read may return a fresh-enough cached digest even if no recent SSE was emitted.

## Termination Semantics

### Graceful shutdown

- Process-level graceful shutdown handles `SIGTERM` and `SIGINT`.
- Structured shutdown phases are `Notify -> Drain -> Cleanup -> Exit`.
- Cleanup closes SSE/WS sessions and flushes in-memory buffers.

### Crash and force-kill

- There is no dedicated `*_shutdown_snapshot` or `*_sigkill_snapshot` event.
- Keeper crash state is recorded via lifecycle and crash persistence, not via a special shutdown snapshot.
- Crash persistence uses an in-memory queue drained every `2s`.
- A hard `SIGKILL` can bypass cleanup and can lose queued-but-not-yet-flushed crash records.

### Operator interpretation

- Graceful stop should show lifecycle transitions and normal cleanup.
- Abrupt termination should be diagnosed from:
  - `oas:masc:keeper:lifecycle` / crash detail
  - registry crash state
  - `crash-events/` durable records
  - missing follow-up snapshot traffic

## Event Inventory by Family

### 1. Dashboard typed SSE union

Source of accepted event names on the dashboard side: `dashboard/src/types/sse.ts`.

| Family | Event names |
| --- | --- |
| Coordination / room | `agent_joined`, `agent_left`, `broadcast`, `task_update` |
| Board and notification compatibility | `board_post`, `masc/board_post`, `board_comment`, `masc/board_comment`, `board_delete`, `masc/board_delete`, `post_created`, `comment_added`, `post_voted`, `comment_voted` |
| Keeper direct SSE | `keeper_heartbeat`, `keeper_handoff`, `masc/keeper_handoff`, `keeper_compaction`, `masc/keeper_compaction`, `keeper_guardrail`, `masc/keeper_guardrail`, `keeper_phase_changed`, `keeper_composite_changed`, `keeper_tool_call`, `masc/keeper_tool_call`, `keeper_tool_skipped`, `keeper_turn_complete`, `masc/keeper_turn_complete` |
| Approval / governance | `client_input_approved`, `client_input_rejected`, `client_input_updated`, `governance_param_changed`, `approval:pending`, `approval:resolved` |
| OAS bridge | `oas:masc:autonomy:agent_selected`, `oas:masc:autonomy:agent_decision`, `oas:masc:autonomy:agent_action_executed`, `oas:masc:keeper:snapshot`, `oas:masc:keeper:lifecycle`, `oas:masc:trust_updated`, `oas:masc:reputation_changed`, `oas:agent_started`, `oas:agent_completed`, `oas:tool_called`, `oas:tool_completed`, `oas:turn_started`, `oas:turn_completed`, `oas:context_compacted`, `oas:task_state_changed`, `oas:masc:harness:verdict_recorded`, `oas:masc:harness:pre_compact`, `oas:masc:harness:handoff` |
| Server-push snapshots | `room_truth_snapshot`, `namespace_truth_snapshot`, `execution_snapshot`, `operator_snapshot`, `operator_digest`, `transport_health_snapshot` |

### 2. OAS custom events published by MASC

These originate in `lib/oas_events.ml` and are later relayed by `oas_event_bridge`.

| Event name | Meaning |
| --- | --- |
| `masc:broadcast` | room broadcast observed via Event_bus |
| `masc:heartbeat` | generic heartbeat event |
| `masc:board_post` | board post created |
| `masc:task_transition` | task state transition |
| `masc:heartbeat_recovered` | agent recovered from timeout |
| `masc:autonomy:agent_selected` | autonomy selector chose an agent |
| `masc:autonomy:agent_decision` | autonomy decision chosen |
| `masc:autonomy:agent_action_executed` | autonomy action executed |
| `masc:keeper:snapshot` | keeper heartbeat snapshot |
| `masc:keeper:lifecycle` | keeper lifecycle update |
| `masc:trust_updated` | trust score changed |
| `masc:reputation_changed` | reputation changed |
| `masc:institution_episode` | institution episode recorded |
| `masc:harness:verdict_recorded` | harness verdict persisted |
| `masc:harness:pre_compact` | pre-compaction observation |
| `masc:harness:handoff` | harness handoff observation |

### 3. Legacy / compatibility cases

| Event name | Status | Notes |
| --- | --- | --- |
| `keeper_lifecycle` | removed legacy direct SSE | Replaced by `keeper_phase_changed` for observer-facing FSM transitions and `oas:masc:keeper:lifecycle` for lifecycle detail. |
| `room_truth_snapshot` | compatibility alias | Emitted together with `namespace_truth_snapshot`; same payload, different name. |

## Representative Messages

These examples are shaped directly from the current producers.

### 1. Direct SSE: `keeper_composite_changed`

```json
{
  "type": "keeper_composite_changed",
  "name": "keeper-a",
  "ts_unix": 1710000000.123
}
```

Meaning:

- signal-only tick
- downstream must fetch `/api/v1/keepers/keeper-a/composite`

### 2. Direct SSE: `keeper_heartbeat`

```json
{
  "type": "keeper_heartbeat",
  "name": "keeper-a",
  "generation": 3,
  "context_ratio": 0.42,
  "ts_unix": 1710000000.123
}
```

Meaning:

- emitted only when heartbeat snapshot write actually happened
- lightweight envelope, not the full heartbeat snapshot JSONL row

### 3. OAS custom event publish: `masc:keeper:snapshot`

This is the payload published to the shared Event_bus before the SSE bridge wraps it.

```json
{
  "keeper_name": "keeper-a",
  "generation": 3,
  "context_ratio": 0.42,
  "message_count": 128,
  "timestamp": 1710000000.123
}
```

### 4. OAS-relayed SSE: `oas:masc:keeper:snapshot`

```json
{
  "type": "oas:masc:keeper:snapshot",
  "event_type": "masc:keeper:snapshot",
  "ts_unix": 1710000000.123,
  "correlation_id": "corr-...",
  "run_id": "run-...",
  "agent_name": null,
  "task_id": null,
  "turn": null,
  "tool_name": null,
  "payload": {
    "keeper_name": "keeper-a",
    "generation": 3,
    "context_ratio": 0.42,
    "message_count": 128,
    "timestamp": 1710000000.123
  }
}
```

### 5. Server-push snapshot: `operator_digest`

```json
{
  "type": "operator_digest",
  "payload": {
    "health": "ok",
    "generated_at": "2026-04-16T12:34:56Z"
  },
  "ts_unix": 1710000000.123
}
```

Meaning:

- server cache projection
- changed-only SSE fanout
- payload body is large and surface-specific; example above is intentionally minimal

### 6. OAS-relayed SSE: `oas:masc:keeper:lifecycle`

```json
{
  "type": "oas:masc:keeper:lifecycle",
  "event_type": "masc:keeper:lifecycle",
  "ts_unix": 1710000000.123,
  "correlation_id": "corr-...",
  "run_id": "run-...",
  "payload": {
    "keeper_name": "keeper-a",
    "event": "started",
    "phase": "running",
    "detail": "supervised",
    "timestamp": 1710000000.123
  }
}
```

Meaning:

- observer and coordinator sessions both receive the live OAS tail
- lifecycle detail now carries `phase`, so the payload can replace the removed legacy direct SSE
- dashboard runtime state ingests this as OAS telemetry, while main keeper transition journaling still comes from `keeper_phase_changed`

## Variantization Status

## What is already typed

- Dashboard-side SSE names are modeled as a TypeScript string union in `dashboard/src/types/sse.ts`.
- Dashboard OAS monitor types are separately modeled in `dashboard/src/types/oas.ts`.
- Composite observer internals are variantized:
  - TLA action names mirrored as OCaml variants
  - invariant keys mirrored as OCaml variants
  - composite snapshot schema validated on the dashboard side

## What is still stringly typed

- Direct SSE producers emit raw JSON objects with string `"type"` fields.
- OAS custom events are published as `Agent_sdk.Event_bus.Custom (name, payload)`, where `name` is still a free string.
- The bridge preserves that string name as `event_type` and prefixes it into `type = "oas:" ^ event_type`.

## Practical conclusion

- This is partially variantized, not end-to-end variantized.
- Domain contracts inside the composite observer are strongly typed.
- Dashboard OAS monitor events are now modeled as a discriminated union rather than a wide product type.
- Transport event names themselves are still mostly string-labeled protocols.

## Source Pointers

- Dashboard event union: `dashboard/src/types/sse.ts`
- Composite signal router: `dashboard/src/sse-store.ts`, `dashboard/src/composite-signals.ts`
- Composite producer: `lib/keeper/keeper_registry.ml`
- Heartbeat snapshot writer: `lib/keeper/keeper_keepalive.ml`
- OAS custom event publishers: `lib/oas_events.ml`
- OAS bridge + durable replay: `lib/oas_event_bridge.ml`
- Server-push snapshot loops: `lib/server/server_dashboard_http_core.ml`, `lib/server/server_dashboard_http_execution_surfaces.ml`, `lib/server/server_dashboard_http_namespace_truth.ml`
