---
status: reference
last_verified: 2026-08-08
code_refs:
  - packages/agent_core/lib
  - lib/runtime/runtime_agent.ml
  - lib/tool_bridge.ml
  - lib/keeper/keeper_event_bridge.ml
---

# MASC Agent Core Boundary Contract

MASC depends on the embedded `masc.agent_core` library. Agent core never
depends on the MASC coordinator.

```text
MASC coordinator -> masc.agent_core
```

| Concern | Agent core owner | MASC owner |
|---|---|---|
| Agent execution | `Agent_sdk.Agent`, hooks, checkpoints | when and why a run starts |
| Provider request | provider runtime and typed failure | runtime lane and capability policy |
| Tool turn | `Agent_sdk.Tool.t` lifecycle | descriptor, authorization, handler |
| Transcript | typed messages and checkpoint state | explicit Keeper compaction and durable product state |
| Events | typed `Agent_sdk.Event_bus` payloads | domain event publication, SSE projection, replay store |
| Orchestration | reusable primitives | Keeper, Board, Goal, Task, Gate, receipts |

## Current integration owners

- Keeper turns execute through `Runtime_agent.run_blocks`. Fusion constructs
  the same runtime with `Runtime_agent.build` and executes it through
  `Agent_sdk.Async_agent` inside `Masc_oas_bridge.run_safe`.
- `Tool_bridge` translates descriptor-owned tools once.
- `Keeper_event_bridge` projects typed bus events to SSE and
  `.masc/oas-events/`.
- `Inference_utils` is the direct MASC projection for response usage and timing.
- `Agent_sdk.Error.category` and `category_label` own SDK error classification.

MASC feature modules consume these owners directly. They must not add response,
usage, error, checkpoint, or tool-schema facade chains.

## Enforcement

- `scripts/check-agent-core-boundary.sh` rejects reverse package dependencies.
- `test/test_agent_core_boundary.sh` proves that boundary check fails closed.
- CI runs `@packages/agent_core/test/runtest` for the embedded core.
- `test_oas_canonical_delegation_contract` pins the exact typed projections
  consumed by MASC.
