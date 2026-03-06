# Supervisor Mode

Supervisor Mode is the interactive TUI operating model for steering a MASC team session through MCP.

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
  - `masc_operator_action`
  - `masc_operator_confirm`
- Worker substrate:
  - `masc_team_session_*`
  - `masc_join`
  - `masc_leave`

This keeps supervision and implementation separate:

- the supervisor reads state and issues guided interventions
- planner and implementer agents do the normal work through the full MCP surface

## Runtime Model

```text
Codex / Claude TUI
        |
        | MCP
        v
  /mcp/operator    -> supervisor snapshot + interventions
  /mcp             -> worker joins, team turns, status, events, proof
```

Use `/mcp/operator` when you want a small, deterministic control surface.
Use `/mcp` when an agent needs the full room and team-session tool inventory.

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
2. Re-run with `view="full"` when intervention looks necessary.
3. Diagnose using:
   - active session state
   - recent messages
   - pending confirmations
   - recent operator actions
4. Call `masc_operator_action`.
5. If `confirm_required=true`, inspect `preview` and wait for human approval.
6. Call `masc_operator_confirm`.
7. Re-check with `masc_operator_snapshot` and `masc_team_session_events`.

## Human Confirm Gate

Supervisor Mode v1 is intentionally human-in-the-loop.

- immediate actions are executed directly
- disruptive actions only produce a preview token on the first call
- the second call is the only execution path

This keeps the TUI workflow usable without turning the supervisor into an unchecked autonomous loop.

## Worker Roles

The recommended Team Session shape is fixed for v1.

- `supervisor`: monitors, diagnoses, and intervenes
- `planner`: decomposes work into concrete tasks and acceptance criteria
- `implementer-a`: backend, runtime, and API changes
- `implementer-b`: docs, harnesses, and tests

The supervisor is not the main implementer.
The supervisor should avoid editing unless intervention requires a direct corrective patch.

## Prompt / Profile Examples

### Supervisor Prompt

```text
You are the supervisor for a MASC team session.
Read state first. Do not guess.
Prefer the smallest intervention that corrects direction.
Use team_note before team_task_inject.
Use room_pause only when the session is materially drifting.
If an action returns confirm_required=true, stop and present the preview for human approval.
After any intervention, re-check snapshot and session events.
```

### Planner Prompt

```text
You are the planner inside a MASC team session.
Turn the current goal into concrete tasks, acceptance criteria, and risks.
Write short, executable team notes.
Do not stop at analysis; leave the room with work that implementers can claim.
```

### Implementer Prompt

```text
You are an implementer inside a supervised MASC team session.
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
  "masc_operator_action",
  "masc_operator_confirm",
]
startup_timeout_sec = 20
tool_timeout_sec = 60
```

Typical flow:

1. `masc_operator_snapshot(view="full")`
2. `masc_operator_action(action_type="team_note", target_id="ts-...", payload={message:"..."})`
3. `masc_operator_action(action_type="team_task_inject", target_id="ts-...", payload={title:"...", description:"...", priority:1})`
4. inspect preview
5. `masc_operator_confirm(confirm_token="...")`
6. `masc_team_session_events(session_id="ts-...")` via `/mcp`

## Claude Code Example

Register the same remote MCP server and restrict the exposed tool allowlist to the operator trio.

Recommended pattern:

1. read snapshot
2. issue one structured action
3. wait for confirm when required
4. re-check team-session evidence through `/mcp`

## Harness

Use the harness to prove the workflow end to end.

```bash
./scripts/harness_supervisor_team_session.sh
```

What it does:

1. starts a local server
2. bootstraps supervisor, planner, and implementer tokens
3. enables bearer-token auth
4. starts a real team session
5. drives worker turns over `/mcp`
6. performs supervisor interventions over `/mcp/operator`
7. stops the session and generates proof artifacts

## Related Docs

- `docs/REMOTE-MCP-OPERATOR.md`
- `docs/TEAM-SESSION.md`
- `scripts/harness_supervisor_team_session.sh`

## Design Notes

- Supervisor Mode is a workflow, not a new broad MCP namespace.
- `/mcp/operator` stays intentionally small.
- Team Session remains the authoritative swarm substrate for supervised implementation.
