---
status: runbook
last_verified: 2026-04-19
code_refs:
  - lib/keeper/keeper_accountability.ml
  - lib/dashboard/dashboard_http_keeper.ml
  - test/test_keeper_accountability.ml
---

# Keeper Accountability Runbook

This runbook explains the operator-facing accountability surface that landed with
PR7162 and the follow-up metric fixes around synthetic support handling.

## Where This Shows Up

- Dashboard read model:
  - `GET /api/v1/dashboard/execution`
  - keeper compatibility payload:
    - `keepers[*].trust_observatory.accountability`
  - projection is omitted when `compact=true` or
    `MASC_DECISION_LAYER_LEVEL < 3`
- Runtime source:
  - `Keeper_exec_status_metrics.accountability_summary_json`
- Durable ledger:
  - `.masc/accountability/YYYY-MM/DD.jsonl`

Treat this as an operator risk summary, not a write path.

## What This Surface Is

- A 14-day rolling, evidence-first summary for one keeper based on claim
  `created_at` values inside the current 14-day window.
- Separate from popularity signals such as board karma or reputation.
- A read model that helps an operator decide whether manual review or
  lower-risk routing is preferable.

It is not:

- a public leaderboard
- a hard scheduler gate
- a proof that a keeper is "good" or "bad" in absolute terms

## Claim Types

### Explicit completion claim

- Created by `record_completion_claim`.
- Usually comes from a keeper response header block on the direct or unified
  turn path, rather than from task lifecycle transitions.
- Stored with `synthetic=false`.
- Participates in `unsupported_completion_rate` once it resolves or ages into
  `unsupported`.

### Synthetic support

- Created by `record_task_transition ... transition="done"` when there is no
  recent explicit completion claim to support.
- Stored with `synthetic=true`, `surface="task_transition"`, and an immediate
  `Supported` resolution with `reason="task_done"`.
- Stays visible in `history`, but does not count toward the denominator of
  `unsupported_completion_rate`.

This follow-up rule is intentional. Synthetic support keeps task lifecycle
evidence visible without diluting real unsupported completion claims.

### Task commitment

- Created on `claim` or `start`.
- Expires after 72 hours if it stays unresolved.
- Feeds `task_followthrough_rate` and `open_overdue_commitments`.

## Field Semantics

| Field | Meaning | Operator reading |
|---|---|---|
| `window_days` | Summary window size | Currently fixed at 14 days of claim creation time |
| `task_followthrough_rate` | `supported_task_commitments / resolved_task_commitments` | Low means claimed work is often released, cancelled, or left to expire |
| `evidence_coverage` | `supported_claims / resolved_claims` | Low means work resolves without enough supporting evidence |
| `unsupported_completion_rate` | `unsupported explicit completion claims / resolved explicit completion claims` | High means explicit "done" claims are aging unsupported or being contradicted |
| `open_overdue_commitments` | Pending task commitments older than 72h | High means likely abandoned or stalled work |
| `recent_supported_claims` | Supported claims inside the current window | Quick health signal, not a ranking |
| `risk_band` | `low`, `medium`, `high` | Operator triage bucket |
| `routing_hint` | `normal_routing`, `prefer_low_risk_when_equivalent`, `manual_review_recommended` | Soft routing guidance only |
| `history` | Most recent 10 claim snapshots | Use it to see the concrete claim/resolution pattern |

Default ratio behavior when the denominator is zero:

- `task_followthrough_rate = 1.0`
- `evidence_coverage = 1.0`
- `unsupported_completion_rate = 0.0`

## Risk Band Thresholds

Current code uses these exact thresholds:

| Band | Condition |
|---|---|
| `low` | `evidence_coverage >= 0.80` and `unsupported_completion_rate < 0.10` and `open_overdue_commitments = 0` |
| `medium` | `evidence_coverage >= 0.60` and `unsupported_completion_rate < 0.25` and `open_overdue_commitments <= 2` |
| `high` | Anything outside the two rows above |

### Tuning Direction

These thresholds are code constants today, so changing them is a product
decision, not a dashboard toggle.

- Raise the `evidence_coverage` minimum:
  - stricter, more keepers fall into `medium` or `high`
  - better false-negative control, worse false-positive rate
- Lower the `evidence_coverage` minimum:
  - more lenient, more keepers stay `low` or `medium`
  - fewer false alarms, higher risk of missed weak evidence
- Lower the `unsupported_completion_rate` cutoff:
  - stricter, unsupported explicit claims trigger faster
- Raise the `unsupported_completion_rate` cutoff:
  - more lenient, but allows repeated unsupported claims to hide longer
- Lower the allowed `open_overdue_commitments`:
  - stricter on long-running or abandoned work
- Raise the allowed `open_overdue_commitments`:
  - more tolerant of slow queues, but stalls remain hidden longer

If you change the thresholds, update both the code and
`test/test_keeper_accountability.ml`.

## Routing Hint Is A Soft Signal

`routing_hint` is derived from `risk_band`:

| `risk_band` | `routing_hint` | Operator action |
|---|---|---|
| `high` | `manual_review_recommended` | Prefer human review or a lower-risk keeper when an equivalent path exists |
| `medium` | `prefer_low_risk_when_equivalent` | Do not block automatically; prefer lower-risk routing only when it is genuinely equivalent |
| `low` | `normal_routing` | No special routing action |

This hint is intentionally advisory. It should not be read as automatic
punishment or a permanent claim ban.

## First-Look Triage

When an operator first sees `risk_band = "high"`:

1. Check whether the keeper currently owns or is executing a task.
2. Separate the cause:
   - low `evidence_coverage`
   - high `unsupported_completion_rate`
   - non-zero `open_overdue_commitments`
3. Inspect `history` to see whether the pattern is:
   - missing evidence on otherwise normal work
   - repeated explicit "done" claims without support
   - stale commitments that were never closed
4. Apply `routing_hint` as guidance, not as a forced block.

High risk does not mean the system is down. It means the operator should review
evidence quality before treating the keeper as interchangeable with a lower-risk
peer.

## Ledger Interpretation

The ledger is date-partitioned, not keeper-partitioned:

- `.masc/accountability/YYYY-MM/DD.jsonl`
- events:
  - `claim_created`
  - `claim_resolved`

### Event fields

`claim_created` records:

| Field | Meaning |
|---|---|
| `claim_id` | Stable claim identifier used to match a later resolution |
| `agent_name`, `keeper_name` | Runtime identity and keeper-facing name |
| `kind` | `task_commitment` or `completion_claim` |
| `subject` | Human-readable task or completion subject |
| `surface` | Where the claim originated, such as `keeper_turn` or `task_transition` |
| `created_at` | ISO8601 timestamp |
| `task_id` | Optional task binding |
| `trace_id`, `turn_number` | Optional execution provenance for explicit keeper claims |
| `evidence_refs` | References attached at claim time |
| `synthetic` | `true` for lifecycle-generated support, `false` for explicit keeper claims |

`claim_resolved` records:

| Field | Meaning |
|---|---|
| `claim_id` | Links the resolution back to `claim_created` |
| `status` | `supported`, `unsupported`, `expired`, or `partial` |
| `resolved_at` | ISO8601 timestamp |
| `reason` | Resolution cause such as `same_turn_evidence` or `task_done` |
| `supporting_evidence_refs` | Evidence attached at resolution time |

Healthy patterns usually look like:

- `task_commitment` -> `supported` or `partial`
- explicit `completion_claim` -> `supported`

Watch for these operator smells:

- `task_commitment` left `pending` long enough to become `expired`
- `completion_claim` older than 24h with no supporting resolution, which turns
  into `unsupported`
- repeated `synthetic=true` completions with few explicit claims, which means
  the keeper is relying on task lifecycle support rather than making evidenceful
  completion claims

Useful read commands:

```bash
rg '"keeper_name":"keeper-sangsu"' .masc/accountability -g '*.jsonl' | tail -20
```

```bash
rg '"claim_id":"acct-"' .masc/accountability -g '*.jsonl' | tail -20
```

## Recovery Path

To move a keeper back toward `medium` or `low`:

1. Make explicit completion claims carry real `evidence_refs`.
2. Resolve or stop repeating unsupported explicit completion claims.
3. Clear, release, or finish stale task commitments before the 72h expiry path
   accumulates.
4. Re-check the next 14-day summary instead of expecting a fixed "three good
   runs" shortcut.

## Why There Is No Public Leaderboard

Accountability is not designed as a public ranking surface.

- It is a bounded 14-day operator risk summary.
- It is sensitive to task mix and evidence style, so cross-keeper comparison is
  not apples-to-apples.
- It is intentionally separate from popularity or reward signals.
- `routing_hint` is advisory, so turning it into a public score would invite
  over-interpretation and punishment logic the code does not implement.
