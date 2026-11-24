# Runtime Output Schema Index

This is the operator-facing map for agent_core runtime output surfaces. It answers:
where is the type or schema truth, who produces it, who consumes it, and which
test catches obvious path drift.

Machine-readable catalog: `docs/schema-surfaces/runtime-output-surfaces.v1.json`.

## Current Surfaces

| Surface | Output | Schema/type truth | Validation |
| --- | --- | --- | --- |
| `agent_core.event_bus.v1` | In-process agent lifecycle events | `lib/event_bus.mli`, `docs/EVENT-CATALOG.md` | Event bus and envelope tests |
| `agent_core.runtime_protocol.v2` | `Runtime.protocol_message` NDJSON protocol types *(no shipped producer)* | `lib/runtime.mli` | Runtime protocol roundtrip tests |
| `agent_core.runtime_telemetry_report.v1` | Structured telemetry types *(no shipped producer)* | `lib/sessions_types.mli` | Sessions type tests |
| `agent_core.raw_trace_record.v1` | Raw trace JSONL rows | `lib/raw_trace.mli` | Raw trace roundtrip tests |
| `agent_core.structured_schema.v1` | Structured output schema helper | `lib/structured.mli`, `lib/base/types.mli` | Structured schema tests |

## Rules

- agent_core-owned runtime semantics live in OCaml `.mli` files first.
- Downstream product domains should not become native agent_core event variants.
- When a schema source or test file moves, update the machine-readable catalog
  in the same change.
- This index lists production output surfaces only. Internal execution-topology
  types are not an additional runtime schema and do not authorize external writes.
- Durable occurrence creation belongs to `Agent_execution_runner` and
  `Execution_agent_scope`, composed through `Agent.execution_store`. External
  history readers use `Agent.open_execution_projection` with canonical event identity
  and scoped cursors. Event_bus and Raw_trace observations are not external-effect
  receipts.
