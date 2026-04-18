---
status: runbook
last_verified: 2026-04-18
code_refs:
  - lib/supervisor.ml
  - lib/tool_operator.ml
  - lib/operator/operator_control.ml
---

# Supervisor Mode

Supervisor Mode is the reduced operator workflow for guiding a namespace through
`/mcp/operator`.

The old `swarm` and `team session` lanes are removed. This runbook covers only
the surviving control loop:

```text
snapshot -> diagnose -> preview -> human confirm -> execute -> re-check
```

## Scope

- Supervisor endpoint: `/mcp/operator`
- Worker endpoint: `/mcp`
- Primary tools:
  - `masc_operator_snapshot`
  - `masc_operator_digest`
  - `masc_operator_action`
  - `masc_operator_confirm`
- Runtime follow-up:
  - namespace/task hygiene tools
  - keeper lifecycle and keeper messaging tools

## What It Does

Supervisor Mode is for:

- reading namespace and keeper state at low cost
- previewing disruptive actions before a human confirms them
- issuing namespace broadcasts, pause/resume, keeper probes, and keeper recovery

Supervisor Mode is not for:

- starting team sessions
- running swarm-style worker orchestration
- relying on retired `masc_team_session_*` tool families

## Golden Loop

1. Call `masc_operator_snapshot(view="summary")`.
2. Call `masc_operator_digest(target_type="root")`.
3. Decide whether the next step is:
   - `broadcast`
   - `namespace_pause`
   - `namespace_resume`
   - `social_sweep`
   - `keeper_message`
   - `keeper_probe`
   - `keeper_recover`
4. Call `masc_operator_action`.
5. If `confirm_required=true`, inspect the preview and wait for human approval.
6. Call `masc_operator_confirm`.
7. Re-check with `masc_operator_snapshot` and `masc_operator_digest`.

## Intervention Policy

| Action | Use when | Confirmation |
|---|---|---|
| `broadcast` | Namespace-wide guidance is needed | Immediate |
| `namespace_pause` | Automation should stop before more work lands | Preview + confirm |
| `namespace_resume` | Recovery after an operator pause | Immediate |
| `social_sweep` | Keepers need an immediate public-square sweep | Immediate |
| `keeper_message` | One keeper needs direct corrective input | Immediate |
| `keeper_probe` | A keeper needs a fresh diagnostic snapshot | Immediate |
| `keeper_recover` | A stale or degraded keeper needs a controlled restart | Preview + confirm |

## Notes

- Treat dashboard surfaces as read models, not canonical write paths.
- For implementation work, start from repo coordination and keeper/runtime tools.
- For benchmark work, use [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md) or
  [INTEGRATED-BENCHMARK-RUNBOOK.md](./INTEGRATED-BENCHMARK-RUNBOOK.md).
