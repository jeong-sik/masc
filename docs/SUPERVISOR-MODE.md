# Supervisor Mode

Supervisor Mode is the interactive TUI operating model for steering a MASC supervised execution session through MCP.

현재 기본 delivery path는 이 문서와 OAS-backed supervised execution 쪽이다. managed-operation benchmark 문서는 별도 compat lane으로 유지한다.

- managed-operation benchmark / compat lane: [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- benchmark compare recipe: [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- swarm-driven implementation delivery: [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)

The goal is not a new autonomous control plane. The goal is a small, explicit loop that Codex or Claude Code can run safely:

```text
snapshot -> diagnose -> preview -> human confirm -> execute -> re-check
```

## Scope

Supervisor Mode v1 is built on top of the existing operator surface.

- Supervisor endpoint: `/mcp/operator`
- Worker endpoint: `/mcp`
- Supervisor tools:
  - `masc_operator_snapshot`
  - `masc_operator_digest`
  - `masc_operator_action`
  - `masc_operator_confirm`
- Worker runtime:
  - `masc_team_session_*` (current tool family name)
  - `masc_join`
  - `masc_leave`

This keeps supervision and implementation separate:

- the supervisor reads state and issues guided interventions
- planner and implementer workers do the normal work through the full MCP surface
- local workers join the same session through `worker_class` / `worker_size`

## Runtime Model

```text
Codex / Claude TUI
        |
        | MCP
        v
  /mcp/operator    -> supervisor snapshot + interventions
  /mcp             -> worker joins, session turns, status, events, proof
```

Use `/mcp/operator` when you want a small, deterministic control surface.
Use `/mcp` when an agent needs the full room and supervised-execution tool inventory.

Repo-synthesis workflow에서는 이 분리를 그대로 유지한다.

- start/control:
  - repo-synthesis는 `masc_autoresearch_cycle` 내부에서 dispatch된다 (전용 front-door tool은 retired)
  - 이어서 `masc_team_session_step`, `masc_operation_checkpoint`
- read/proof:
  - `/mcp/operator`의 `masc_operator_snapshot` / `masc_operator_digest`
  - dashboard `/api/v1/dashboard/repo-synthesis`

즉 dashboard는 read-only truth/proof surface이고, canonical write/control은 계속 MCP다.

## Local Worker Runtime

`masc-mcp` can run a worker directly on the hidden local worker backend.

- canonical supervised-execution spawn path: `masc_team_session_step(spawn_role="...", worker_class="...", worker_size="...", spawn_prompt="...")`
- implementation detail: local worker on the configured local runtime

Environment:

- `LLAMA_SERVER_URL`
  - default: OAS local runtime endpoint (`OAS_LOCAL_LLM_URL` -> `OAS_LOCAL_QWEN_URL` -> OAS default)

Selection policy for this slice is size-based:

1. choose `worker_class`
2. choose `worker_size` (`sm` | `lg` | `xlg`) if you need an override
3. record selection rationale in the session with `masc_team_session_step(turn_kind="note", message="...")` when helpful
4. spawn through `spawn_prompt` / `spawn_batch`
5. backend model/provider selection stays internal to MASC

## Intervention Policy

| Action | Use when | Confirmation |
|---|---|---|
| `team_note` | Direction is off but the current task can recover | Immediate |
| `team_broadcast` | All workers need the same new context | Immediate |
| `team_task_inject` | Missing work must be split out or explicitly tracked | Preview + confirm |
| `room_pause` | The room is drifting or producing unsafe edits | Preview + confirm |
| `team_stop` | The current attempt should be terminated cleanly | Preview + confirm |
| `broadcast` | Room-wide operator guidance is needed | Immediate |
| `keeper_message` | A long-running keeper needs a direct correction | Immediate |
| `room_resume` | Recovery after an operator pause | Immediate |

Default policy:

1. Prefer `team_note` before `team_task_inject`.
2. Prefer `team_task_inject` before `room_pause`.
3. Use `team_stop` only when the current attempt should not continue.
4. Require a human confirm for every disruptive action.

## Supervisor Loop

Recommended loop for Codex or Claude Code in a TUI:

1. Call `masc_operator_snapshot` with `view="summary"` for low-cost polling.
2. Call `masc_operator_digest` for the room or a specific execution session.
   - current tool ids still use `team_session`; operator narrative should treat it as a session/runtime detail, not a separate product concept.
3. Diagnose using:
   - digest `health`
   - prioritized `attention_items`
   - advisory `recommended_actions`
   - recent messages and pending confirmations from snapshot
4. Call `masc_operator_action`.
5. If `confirm_required=true`, inspect `preview` and wait for human approval.
6. Call `masc_operator_confirm`.
7. Re-check with `masc_operator_snapshot`, `masc_operator_digest`, and `masc_team_session_events`.

## Human Confirm Gate

Supervisor Mode v1 is intentionally human-in-the-loop.

- immediate actions are executed directly
- disruptive actions only produce a preview token on the first call
- the second call is the only execution path

This keeps the TUI workflow usable without turning the supervisor into an unchecked autonomous loop.

## Worker Roles

The recommended supervised execution shape is fixed for v1.

- `supervisor`: monitors, diagnoses, and intervenes
- `planner`: decomposes work into concrete tasks and acceptance criteria
- `implementer-a`: backend, runtime, and API changes
- `implementer-b`: docs, harnesses, and tests

For llama workers, the supervisor should make model choice explicit and attributable:

1. call `masc_llama_models`
2. pick one inventory item deliberately
3. record a session note describing the chosen model and why
4. pass the same note to each worker with `spawn_selection_note`

That gives the proof trail two copies of the same decision:

- a supervisor-owned session note
- a worker prompt line: `Leader-selected model context: ...`

The supervisor is not the main implementer.
The supervisor should avoid editing unless intervention requires a direct corrective patch.

## Prompt / Profile Examples

### Supervisor Prompt

```text
You are the supervisor for a MASC supervised execution session.
Read state first. Do not guess.
Prefer the smallest intervention that corrects direction.
Use team_note before team_task_inject.
Use room_pause only when the session is materially drifting.
If an action returns confirm_required=true, stop and present the preview for human approval.
After any intervention, re-check snapshot and session events.
```

### Planner Prompt

```text
You are the planner inside a supervised MASC execution session.
Turn the current goal into concrete tasks, acceptance criteria, and risks.
Write short, executable team notes.
Do not stop at analysis; leave the room with work that implementers can claim.
```

### Implementer Prompt

```text
You are an implementer inside a supervised MASC execution session.
Stay inside the assigned task.
Report progress through team_session turns.
If the supervisor corrects direction, adapt immediately and acknowledge the new plan.
```

## Codex TUI Example

`~/.codex/config.toml`

```toml
[mcp_servers.masc_operator]
url = "https://your-host.example.com/mcp/operator"
bearer_token_env_var = "MASC_OPERATOR_TOKEN"
enabled_tools = [
  "masc_operator_snapshot",
  "masc_operator_digest",
  "masc_operator_action",
  "masc_operator_confirm",
]
startup_timeout_sec = 20
tool_timeout_sec = 60
```

Typical flow:

1. `masc_operator_snapshot(view="summary")`
2. `masc_operator_digest(target_type="team_session", target_id="ts-...")`
3. `masc_operator_action(action_type="team_note", target_id="ts-...", payload={message:"..."})`
4. `masc_operator_action(action_type="team_task_inject", target_id="ts-...", payload={title:"...", description:"...", priority:1})`
5. inspect preview
6. `masc_operator_confirm(confirm_token="...")`
7. `masc_team_session_events(session_id="ts-...")` via `/mcp`

## Claude Code Example

Register the same remote MCP server and restrict the exposed tool allowlist to the operator quartet.

Recommended pattern:

1. read summary snapshot
2. read digest
3. issue one structured action
4. wait for confirm when required
5. re-check session evidence through `/mcp`

## Harness

Use the harness to prove the workflow end to end.

```bash
./scripts/harness_supervisor_team_session.sh
```

What it does:

1. starts a local server
2. bootstraps supervisor auth
3. reads the llama inventory through `masc_llama_models`
4. validates an explicit `LLAMA_SWARM_MODEL`
5. starts a real execution session
6. spawns a full llama worker team (`planner`, `implementer-a`, `implementer-b`)
7. records the explicit model-selection note in the session
8. passes the same note into every spawned worker prompt
9. requires every worker to leave a non-empty session note turn via `masc_team_session_step`
10. performs supervisor interventions over `/mcp/operator`
11. stops the session and generates proof artifacts

Run it against a real local llama team:

```bash
LLAMA_SERVER_URL="${OAS_LOCAL_LLM_URL}" \
LLAMA_SWARM_MODEL=<exact-model-id-from-masc_llama_models> \
./scripts/harness_supervisor_team_session.sh
```

For same-box shard-pool validation, precompute the runtime pool env and run the local64 smoke harness:

```bash
export LLM_ENDPOINTS="$(./scripts/llama-runtime-pool.sh print-env --target-shards 6)"
LLAMA_SWARM_MODEL=<exact-model-id-from-masc_llama_models> \
./scripts/harness_team_session_local64_smoke.sh
```

Use the deterministic failure-replay harness when you want to validate the
failed batch-spawn path itself instead of the happy path:

```bash
LLAMA_SWARM_MODEL=<explicit-model-id> \
./scripts/harness_team_session_failed_batch_spawn.sh
```

It starts MASC with an intentionally unreachable `LLAMA_SERVER_URL`, replays a
two-worker llama batch spawn, and verifies:

1. both spawned workers fail deterministically
2. failed runtime actors are detached from session participants
3. report/proof artifacts expose failed spawn and detached actor counts
4. report/proof artifacts expose failed runtime-actor roster and detach reasons

## Related Docs

- `docs/SWARM-DELIVERY-RUNBOOK.md`
- `docs/REMOTE-MCP-OPERATOR.md`
- `scripts/harness_supervisor_team_session.sh`
- `scripts/harness_team_session_failed_batch_spawn.sh`

## Design Notes

- Supervisor Mode is a workflow, not a new broad MCP namespace.
- `/mcp/operator` stays intentionally small.
- OAS-backed session execution remains the authoritative runtime substrate for supervised implementation sessions.
- Managed-operation benchmarking is a separate compatibility lane; it is not required for supervised delivery.
