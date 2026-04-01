# Swarm Architecture

Two distinct layers exist. Understanding which is which prevents confusion.

## Execution Layer (uses OAS, calls MODEL)

| Module | Role | Entry point |
|--------|------|-------------|
| `agent_swarm_swarm.ml` | Multi-agent runner. Eio fibers + Agent SDK `Agent.create`/`Agent.run`. MASC join/leave/heartbeat. | `run ~sw ~net ~clock config ~goal` |
| `agent_swarm_fleet.ml` | Fleet orchestrator. Planner + N workers via `agent_swarm_swarm.run_agent`. | `run_full ~sw ~net ~clock ~proc_mgr ...` |
| `agent_swarm_runner.ml` | CLI runner. Parses args, calls `Agent_swarm_fleet.run_full`. | `bin/agent_swarm_runner.exe --goal "..." --fleet` |
| `agent_swarm_live_harness.ml` | Live harness. Seeds tasks, runs swarm, collects results. | Called by `masc_swarm_live_run` MCP tool |
| `oas_worker.ml` | OAS agent builder/runner via `Oas.Builder.*`. | Used by keeper runtime |

### MCP Tools

| Tool | Behavior |
|------|----------|
| `masc_swarm_live_run` | Async: preflight then fork harness in background. Returns `run_id`. |
| `masc_swarm_live_status` | Poll for run status: running/completed/failed + artifacts. |

### CLI

```bash
# Solo mode (single agent with dev tools)
./_build/default/bin/agent_swarm_runner.exe --goal "Fix the bug" --provider local-qwen

# Fleet mode (planner + N workers)
./_build/default/bin/agent_swarm_runner.exe --goal "Ship the feature" --fleet --members 3
```

## State Layer (no MODEL, data structures only)

| Module | Role |
|--------|------|
| `swarm/swarm_eio.ml` | Swarm metadata: agents, fitness, pheromones, proposals. JSON persistence. |
| `swarm/swarm_goal_loop.ml` | Goal-driven loop: measure metric, evaluate condition, re-plan if needed. Connected to `mdal_swarm.ml`. |
| `swarm/swarm_checkpoint.ml` | Checkpoint persistence for goal loop state. |
| `swarm/swarm_status*.ml` | Status formatting and classification. |

The state layer tracks metadata about swarm runs. The execution layer's `on_complete` callback writes results back to the state layer's fitness model.

## Removed

| Module | Prior location | Reason |
|--------|----------------|--------|
| `swarm_behaviors_eio.ml` | `lab/swarm-behaviors/` | Archived experiment with no consumers; removed in the stale sweep. |
| `tool_swarm.mli` | Deleted | Orphaned interface, no implementation. |
