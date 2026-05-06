# GOAL LOOP Anti-Stagnation SLA

`scripts/goal_loop_anti_stagnation.py` evaluates per-finding lifecycle state
against the prompt anti-stagnation rules. It produces machine-readable JSON so
status/dashboard consumers do not need to infer escalation state from prose.

## Input Shape

The input JSON is a finding lifecycle snapshot:

```json
{
  "findings": [
    {
      "finding_id": "NF-2",
      "status": "STILL_PRESENT",
      "first_seen_at": "2026-05-05T00:00:00Z",
      "act": {
        "ref": "PR#13050",
        "created_at": "2026-05-05T06:00:00Z",
        "merged_at": "2026-05-06T00:00:00Z",
        "repair_ref": "PR#13060",
        "rollback_ref": null
      },
      "verify": {
        "status": "FAIL",
        "checked_at": "2026-05-06T03:00:00Z",
        "failed_at": "2026-05-06T03:00:00Z"
      },
      "escalation": {
        "recorded": false
      }
    }
  ]
}
```

## Rules

- `still_present_requires_act`: `STILL_PRESENT` or `PARTIALLY_FIXED` findings
  must carry an ACT reference.
- `act_creation_deadline_missed`: an ACT must be created within 48 hours of
  first detection.
- `verify_after_merge_deadline_missed`: merged ACT work must have Verify
  evidence within 24 hours.
- `verify_fail_repair_deadline_missed`: failed Verify needs a repair PR or
  rollback reference within 4 hours.
- `week_old_escalation_required`: findings still present for more than one week
  must have an escalation record.

`scripts/goal_loop_status.py --anti-stagnation-json <report.json>` exposes the
summary under `phases.act.summary.anti_stagnation` and
`system_health_signals.anti_stagnation`.
