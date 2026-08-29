---
status: Active
---

# Agent Core Integration

MASC embeds `packages/agent_core` and consumes it through the `Agent_core`
library surface. Agent Core owns reusable model execution; MASC owns product
orchestration.

## Dependency direction

```text
MASC coordinator -> masc.agent_core
```

`packages/agent_core` must not depend on MASC coordinator libraries. CI asks
Dune for the resolved library dependency closure rooted at
`packages/agent_core` and `scripts/audit-sublib-cycle.py` rejects every
workspace-local library owned outside that source root. Installed libraries
remain allowed. `scripts/check-agent-core-boundary.sh` separately checks the
package's required filesystem shape and rejects nested package/release surfaces
and source symlinks. CI rejects Dune's legacy OCaml-syntax escape hatch; Dune
itself then formats the package and active ancestor Dune files before CI rejects
include stanzas, keeping every dependency input inside the path-classified
graph proof. The existing coordinator-module name scan
remains as defense in depth. CI also executes the package behavior suite with
`@packages/agent_core/test/runtest`.

## Runtime flow

```text
Keeper turn -> Runtime_agent.run_blocks -> Agent_core.Agent
Fusion      -> Runtime_agent.build -> Agent_core.Async_agent
```

- `Runtime_agent` owns MASC runtime configuration, checkpoint attachment, and
  the Keeper execution boundary, including lifecycle projection, content
  admission, checkpoint resume, and terminal recording.
- Fusion builds with the same runtime configuration owner, then executes its
  typed panel through `Agent_core.Async_agent` inside `Masc_agent_core_bridge.run_safe`.
- `Agent_core.Agent` owns agent construction, tool turns, provider requests,
  typed responses, usage, and typed failures.
- Feature code projects typed Agent Core results directly. It must not recreate
  response, error-category, usage, or tool-schema facades.

## Tool boundary

MASC owns tool descriptors, authorization, and handlers. `Tool_bridge` converts
descriptor-owned schemas and handlers into `Agent_core.Tool.t`. A model call is
validated against the same captured descriptor that is dispatched.

## Event boundary

`Keeper_event_bridge` subscribes to `Agent_core.Event_bus`, converts its closed
payload variants to MASC SSE events, and appends replayable JSONL under
`.masc/agent-core-events/`. Agent Core mints one producer-owned `event_id` per
occurrence; the bridge preserves the same canonical envelope in JSONL and SSE
so replay/live overlap is deduplicated by identity rather than content or
timestamps. MASC-owned domain events use the process-wide bus in
`Event_bus_slots`; they are not inferred from assistant text.

## State ownership

- Agent Core owns the transcript and generic checkpoint representation.
- MASC owns Keeper lanes, Board, Goal, Task, Gate, receipts, and durable product
  state.
- Agent Core reports typed capacity or context overflow; it does not mutate
  MASC history implicitly.
- Concrete provider and model identity remains agent-core runtime data. MASC
  product policy routes by typed runtime lane and capability.

## Required proof

- `test/test_agent_core_boundary.sh`
- `scripts/audit-sublib-cycle.py --closed-source-root packages/agent_core --required-local-library masc.agent_core`
- `@packages/agent_core/test/runtest`
- `@test/runtest-test_keeper_hooks_agent_core_introspection`
- `@test/runtest-test_keeper_execution_join`
- `@test/runtest-test_hitl_summary_worker`

These checks cover the dependency direction, the embedded core behavior, and
the agent-core projection values consumed by MASC. The Keeper event bridge is
compiled as an exhaustive match and its wire joins run in
`@test/runtest-test_keeper_execution_join`.
