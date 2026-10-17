---
status: runbook
---

# Supervisor Mode

Supervisor Mode is the operator workflow for observing and guiding a workspace through
`/mcp/operator`.

```text
snapshot -> diagnose -> preview -> human confirm -> execute -> re-check
```

## Scope

- Supervisor endpoint: `/mcp/operator`
- Worker endpoint: `/mcp`
- Primary tools on `/mcp/operator`:
  - `masc_operator_snapshot`
  - `masc_operator_digest`
  - `masc_operator_action`
  - `masc_operator_confirm`
  - `masc_operator_board_attention_quarantine_requeue`
  - `masc_operator_task_recovery_resolve`
- Full-surface operator judgment write (`/mcp`):
  - `masc_operator_judgment_write`
- Runtime follow-up:
  - namespace/task hygiene tools
  - keeper lifecycle and keeper messaging tools

## What It Does

Supervisor Mode is for:

- reading namespace and keeper state at low cost
- previewing disruptive actions before a human confirms them
- issuing namespace broadcasts, pause/resume, keeper probes, and keeper recovery

## Golden Loop

1. Call `masc_operator_snapshot(view="summary")`.
2. Call `masc_operator_digest()`.
3. Decide whether the next step is:
   - `broadcast`
   - `namespace_pause`
   - `namespace_resume`
   - `task_inject`
   - `keeper_message`
   - `keeper_probe`
   - `keeper_recover`
4. Call `masc_operator_action`.
5. Inspect the preview and wait for human approval. Every action returns
   `confirm_required=true` with a `confirm_token`; nothing runs before step 6.
6. Call `masc_operator_confirm`.
7. Re-check with `masc_operator_snapshot` and `masc_operator_digest`.

## Intervention Policy

Every action is staged first. `masc_operator_action` returns a preview and a
`confirm_token`, and the action runs when `masc_operator_confirm` is called with
that token.

| Action | Use when |
|---|---|
| `broadcast` | Namespace-wide guidance is needed |
| `namespace_pause` | Automation should stop before more work lands |
| `namespace_resume` | Recovery after an operator pause |
| `task_inject` | A backlog task should be added to the namespace |
| `keeper_message` | One keeper needs direct corrective input |
| `keeper_probe` | A keeper needs a fresh diagnostic snapshot |
| `keeper_recover` | A keeper whose keepalive has stopped needs a controlled restart |

## Notes

- Treat dashboard surfaces as read models, not canonical write paths.
- For implementation work, start from repo workspace collaboration and keeper/runtime tools.
- For benchmark work, use [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md) or
  [INTEGRATED-BENCHMARK-RUNBOOK.md](./INTEGRATED-BENCHMARK-RUNBOOK.md).
