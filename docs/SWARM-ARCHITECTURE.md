# Swarm Architecture

Current swarm-related execution in `masc-mcp` has two distinct paths.

- Default implementation/runtime path: Team Session + OAS swarm bridge
- Managed-operation benchmark lane: live harness and read model

Front-door control order lives in [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md), [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md), and [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md). This doc is an internal architecture map, not the usage SSOT.

## Execution Layer

| Path | Current implementation | Role | Entrypoint |
|------|------------------------|------|------------|
| Managed-operation live proof | `scripts/harness/workload/agent_swarm_live.sh` | Deterministic hot-swarm proof. Seeds tasks, checks runtime contract, samples slots, and reads `masc_observe_swarm`. | `./scripts/harness_agent_swarm_live.sh` |
| Team-session swarm bridge | `lib/team_session/team_session_swarm_runner.ml` | Runs auto-mode team sessions through OAS Swarm Runner and applies results back to session state. | `Team_session_swarm_runner.run_swarm` |
| Session -> swarm bridge | `lib/team_session/team_session_oas_bridge.ml` | Converts session/planned-worker state into swarm config and exposes supported MCP dispatch. | `session_to_swarm_config` |
| Swarm callbacks | `lib/team_session/team_session_swarm_callbacks.ml` | Writes events/checkpoints/proof-facing telemetry during swarm execution. | `make_callbacks` |
| Local64 compat smoke | `scripts/harness/workload/team_session_local64_smoke.sh` | Validates spawn-batch, explicit model selection, and local64 worker runtime through the team-session path. | `./scripts/harness_team_session_local64_smoke.sh` |

## Public MCP / Proof Surfaces

| Surface | Purpose |
|--------|---------|
| `masc_observe_swarm` | Read the managed-operation swarm-live projection and pass/fail summary |
| `masc_runtime_verify` | Prove provider reachability, slot count, and ctx contract |
| `masc_team_session_start` | Start the implementation-oriented team-session path |
| `masc_team_session_step` | Canonical write path for spawn/note/run evidence |
| `masc_team_session_status` / `masc_team_session_prove` | Read status and generate proof artifacts for team sessions |
| `/mcp/operator` quartet | Supervisor-only intervention surface for team-session guidance |

## State / Projection Layer

| Module | Role |
|--------|------|
| `lib/swarm/swarm_goal_loop.ml` | Goal-loop metadata and checkpointed swarm logic |
| `lib/swarm/swarm_checkpoint.ml` | Persistence for swarm goal-loop checkpoints |
| `lib/swarm_status/swarm_status_*.ml` | Parse/build/classify swarm-live artifacts for projections |
| `lib/command_plane/cp_snapshot*.ml` | Command-plane read model and higher-level summaries |

## Historical / Retired Names

Older notes may still mention these names. They are not current public entrypoints and should not be used as SSOT.

- `masc_swarm_live_run`
- `masc_swarm_live_status`
- `agent_swarm_runner` / `agent_swarm_runner.ml`
- `agent_swarm_live_harness.ml`

If the goal is benchmark truth, use `./scripts/harness_agent_swarm_live.sh`.
If the goal is implementation/runtime supervision, use the team-session path and the supervisor runbooks.
