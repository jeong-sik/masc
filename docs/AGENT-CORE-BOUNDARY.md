---
status: reference
---

# MASC Agent Core Boundary Contract

MASC depends on the embedded `masc.agent_core` library. Agent Core never
depends on the MASC coordinator.

Agent Core carries its own specifications under
[`packages/agent_core/docs/`](../packages/agent_core/docs/README.md) — 24 RFCs
plus capability, catalog, and design references. Read those before changing
anything under `packages/agent_core/`; the repository-level `docs/rfc/` does
not cover that subtree.

```text
MASC coordinator -> masc.agent_core
```

| Concern | Agent Core owner | MASC owner |
|---|---|---|
| Agent execution | `Agent_core.Agent`, hooks, checkpoints | when and why a run starts |
| Provider request | provider runtime and typed failure | runtime lane and capability policy |
| Tool turn | `Agent_core.Tool.t` lifecycle | descriptor, authorization, handler |
| Transcript | typed messages and checkpoint state | durable product state |
| Events | typed `Agent_core.Event_bus` payloads | domain event publication, SSE projection, replay store |
| Orchestration | reusable primitives | Keeper, Board, Goal, Task, Gate, receipts |

## Current integration owners

- Keeper turns execute through `Runtime_agent.run_blocks`. Fusion constructs
  the same runtime with `Runtime_agent.build` and executes it through
  `Agent_core.Async_agent` inside `Masc_agent_core_bridge.run_safe`.
- `Tool_bridge` translates descriptor-owned tools once.
- `Keeper_event_bridge` projects typed bus events to SSE and
  `.masc/agent-core-events/`.
- `Inference_utils` is the direct MASC projection for response usage and timing.
- `Agent_core.Error.category` and `category_label` own agent-core error
  classification.

MASC feature modules consume these owners directly. They must not add response,
usage, error, checkpoint, or tool-schema facade chains.

## Enforcement

- `scripts/check-agent-core-boundary.sh` rejects reverse package dependencies.
- `test/test_agent_core_boundary.sh` proves that boundary check fails closed.
- CI runs `@packages/agent_core/test/runtest` for the embedded core.
- `test_keeper_hooks_agent_core_introspection`, `test_keeper_execution_join`,
  and `test_hitl_summary_worker` check the typed projections consumed by MASC.
