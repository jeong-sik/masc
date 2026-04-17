---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/oas_events.ml
  - lib/oas_sse_bridge.ml
  - lib/telemetry_unified.ml
---

# OAS Observability Truth Audit (2026-04-15)

## Scope

This audit records the producer -> bridge -> durable store -> dashboard consumer chain for OAS observability, plus the dashboard truth split that was fixed in the April 2026 cleanup wave.

## Producer To Consumer Chain

### 1. Producers

- OAS native runtime events originate in `agent_sdk` and enter the shared `Agent_sdk.Event_bus`.
- MASC custom observability events are published by `lib/oas_events.ml` under the `masc:*` namespace.

### 2. Bridge

- `lib/oas_sse_bridge.ml` subscribes to the OAS event bus with `accept_all`.
- Native events are serialized with an `oas:` prefix.
- Envelope fields `correlation_id`, `run_id`, and `ts_unix` are emitted for every relayed event.

### 3. Durable Store

- `lib/oas_sse_bridge.ml` appends every relayed OAS event to `.masc/oas-events/` through `Dated_jsonl.append`.
- This durable JSONL store is the replay source for dashboard recovery and telemetry inspection.

### 4. Server Read Path

- `lib/telemetry_unified.ml` exposes the durable store as telemetry source `oas_event`.
- Dashboard consumers read it through `/api/v1/dashboard/telemetry?source=oas_event`.

### 5. Dashboard Consumer Path

- `dashboard/src/oas-runtime-store.ts` is the client-side OAS runtime SSOT.
- Boot and reconnect replay use `replayOasRuntimeTelemetry()` to rebuild runtime state from durable `oas_event` telemetry.
- Live SSE events flow through `dashboard/src/sse.ts`, but OAS runtime state is updated by the same `applyOasRuntimeEvent()` ingestion path used by replay.
- `dashboard/src/components/oas-health-chip.ts` renders the replayed + live-combined state.

## Fixed Truth Breaks

### Dashboard OAS Event Wiring

- Keeper lifecycle events were produced with `keeper_name` but the dashboard treated them as `agent_name`.
- Client dedupe was previously based on weak front-end tuples instead of the OAS envelope.
- `lastKeeperTick` could drift because the client used local wall-clock time instead of backend event time.
- A dead `oas:masc:keeper:tick` client-only path existed without a real producer.

### Durable vs Live Split

- Dashboard OAS health used live-only incremental counters, so a reload or reconnect lost the durable truth.
- Replay and live paths used different logic, which allowed drift between telemetry and runtime chips.
- The fixed rule is:
  - OAS runtime health SSOT = `durable oas_event replay + live SSE tail`
  - live SSE is an overlay, not the only source of truth

### Runtime Count Split

- Dashboard `counts.keepers` used configured keeper inventory in some paths and active runtime counts in others.
- The fixed rule is:
  - `counts` = active runtime truth
  - `configured_keepers` = configured keeper inventory
  - `counts.total_runtimes` = active agents + active keepers

## Consumer Rules

1. When reading OAS runtime health in the dashboard, trust the replayed `oas_event` ledger first and the live tail second.
2. When reading runtime counts in the dashboard, use `counts` for active runtime truth and `configured_keepers` for inventory.
3. When deduping OAS events client-side, prefer the OAS envelope (`event_type`, `correlation_id`, `run_id`, `ts_unix`) over front-end-only tuples.

## Deferred Follow-Up Issue Seeds

These items were intentionally deferred from the April 2026 dashboard cleanup wave because they cross runtime ownership boundaries.

### 1. Keeper checkpoint truth precedence

- Symptom: keeper continuity still spans OAS checkpoint data and MASC-owned runtime wrappers.
- Suspected owner path: `lib/keeper/keeper_exec_context.ml`, `lib/keeper/keeper_agent_run.ml`, checkpoint replay surfaces.
- Required outcome: document and enforce one checkpoint truth hierarchy before any more replay logic is added.

### 2. `working_context` ownership reduction

- Symptom: keeper runtime still persists a MASC-owned `working_context` wrapper around OAS context/checkpoint primitives.
- Suspected owner path: keeper post-turn and restore flows.
- Required outcome: shrink `working_context` until OAS owns runtime context/checkpoint state and MASC only projects coordination state.

### 3. Raw `[STATE]` marker removal

- Symptom: keeper continuity still depends on raw text markers such as `[STATE]`.
- Suspected owner path: post-turn continuity writes, context reduction heuristics, replay/read surfaces.
- Required outcome: replace raw marker coupling with structured metadata or typed replay facts.
