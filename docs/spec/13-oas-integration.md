---
status: Active
last_verified: 2026-08-08
code_refs:
  - packages/agent_core/lib
  - lib/runtime/runtime_agent.ml
  - lib/keeper/keeper_event_bridge.ml
  - lib/tool_bridge.ml
---

# Agent Core Integration

MASC embeds `packages/agent_core` and consumes it through the `Agent_sdk`
library surface. Agent core owns reusable model execution; MASC owns product
orchestration.

## Dependency direction

```text
MASC coordinator -> masc.agent_core
```

`packages/agent_core` must not import MASC coordinator libraries or product
concepts. `scripts/check-agent-core-boundary.sh` checks this one-way dependency,
and CI executes the package behavior suite with
`@packages/agent_core/test/runtest`.

## Runtime flow

```text
Keeper turn -> Runtime_agent.run_blocks -> Agent_sdk.Agent
Fusion      -> Runtime_agent.build -> Agent_sdk.Async_agent
```

- `Runtime_agent` owns MASC runtime configuration, checkpoint attachment, and
  the Keeper execution boundary, including lifecycle projection, content
  admission, checkpoint resume, and terminal recording.
- Fusion builds with the same runtime configuration owner, then executes its
  typed panel through `Agent_sdk.Async_agent` inside `Masc_oas_bridge.run_safe`.
- `Agent_sdk.Agent` owns agent construction, tool turns, provider requests,
  typed responses, usage, and typed failures.
- Feature code projects typed Agent core results directly. It must not recreate
  response, error-category, usage, or tool-schema facades.

## Tool boundary

MASC owns tool descriptors, authorization, and handlers. `Tool_bridge` converts
descriptor-owned schemas and handlers into `Agent_sdk.Tool.t`. A model call is
validated against the same captured descriptor that is dispatched.

## Event boundary

`Keeper_event_bridge` subscribes to `Agent_sdk.Event_bus`, converts its closed
payload variants to MASC SSE events, and appends replayable JSONL under
`.masc/oas-events/`. MASC-owned domain events use the process-wide bus in
`Event_bus_slots`; they are not inferred from assistant text.

## State ownership

- Agent core owns the transcript and generic checkpoint representation.
- MASC owns Keeper lanes, Board, Goal, Task, Gate, receipts, and durable product
  state.
- MASC compaction is an explicit product operation. Agent core reports typed
  capacity or context overflow; it does not mutate MASC history implicitly.
- Concrete provider and model identity remains agent-core runtime data. MASC
  product policy routes by typed runtime lane and capability.

## Required proof

- `test/test_agent_core_boundary.sh`
- `@packages/agent_core/test/runtest`
- `@test/runtest-test_oas_canonical_delegation_contract`

These checks cover the dependency direction, the embedded core behavior, and
the Agent-core projection values consumed by MASC. The Keeper event bridge is
compiled as an exhaustive match and its wire joins run in
`@test/runtest-test_keeper_execution_join`.
