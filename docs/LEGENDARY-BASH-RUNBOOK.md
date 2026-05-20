---
status: runbook
last_verified: 2026-05-21
code_refs:
  - lib/exec/exec_semantic.ml
  - lib/exec/exec_buffer.ml
  - lib/exec/exec_run.ml
  - lib/exec_core.ml
  - lib/cdal/cdal_judge.ml
  - lib/worker_dev_tools.ml
  - lib/keeper/keeper_exec_shell.ml
---

# Legendary Bash Runbook

This runbook documents the operator surface of the "Legendary Bash" exec
rework for `keeper_bash` and adjacent structured shell routing.

The legacy-vs-AST gate diff observer has been retired. Current operator
surfaces are limited to live behavior flags, the auto-background observer,
typed advisor counters, and background task roster endpoints.

## Related Documents

- [`ENV-CONTRACT.md`](./ENV-CONTRACT.md) §4 — authoritative flag matrix
- [`BOOT-ENV-STATE-INVENTORY.md`](./BOOT-ENV-STATE-INVENTORY.md)
- `planning/graceful-panda/Legendary-Bash-plan.md` (source plan, 6 phases)

## Scope

- Covers: `keeper_bash`, exec semantic exit, output truncation, background task
  lifecycle, verification contract markers, typed shell advisor counters, and
  the structured-shell boundary around it.
- `keeper_shell` is not a raw command execution surface. It owns structured ops
  such as `rg`, `ls`, `cat`, `git_status`, `git_log`, `git_diff`, `git_clone`,
  and `gh`; `keeper_shell op=bash` is a deprecated non-executing compatibility
  response.
- Does not cover: the cascade verifier itself or the approval layer for MCP
  tools. Those are separate surfaces.

Every flag in this runbook is `request_dynamic` on the keeper-bash path:
operators can flip without a process restart and the next `keeper_bash` call
observes the new value.

## Current Rollout State

As of `last_verified`:

| Phase | Feature | Default | Status |
| --- | --- | --- | --- |
| P1 | `semantic_exit` typed return code | **on** | flipped |
| P2 | background task lifecycle | n/a | delivered, opt-in per call |
| P3 | head+tail truncation | on | delivered |
| P4 | auto-background on blocking budget | off | observer live (`MASC_BASH_AUTO_BG_OBSERVE`) |
| P5 | typed shell validation | advisor opt-in | legacy-vs-shadow observer retired |
| P6 | `verifiable_markers` emission | **on** | flipped |

## Flag Matrix

Authoritative definitions live in `ENV-CONTRACT.md §4`.

| Variable | Default | Opt-out tokens | What changes |
| --- | --- | --- | --- |
| `MASC_BASH_SEMANTIC_EXIT` | on | `0`, `false`, `no`, `off` | drops `return_code_interpretation` JSON field |
| `MASC_BASH_OUTPUT_CAP` | on | — | head+tail truncation; `MASC_BASH_CAP_HEAD`/`TAIL` override per-stream caps |
| `MASC_BASH_VERIFIABLE_MARKERS` | on | `0`, `false`, `no`, `off` | drops typed `verifiable_markers` from `Cdal_judge` |
| `MASC_BASH_AUTO_BG` | off | — | foreground commands that outrun the blocking budget auto-promote |
| `MASC_BLOCKING_BUDGET_MS` | `15000` | — | consumed by `AUTO_BG` and `AUTO_BG_OBSERVE` |
| `MASC_BASH_AUTO_BG_OBSERVE` | off | — | dark-launch observer for P4 |
| `MASC_BASH_TYPED_ADVISOR` | off | — | behavior-neutral typed-validation advisor counters/logs |
| `MASC_BASH_TYPED_AUTHORITY` | off | — | typed-validation authority predicate for the remaining validation migration |

## Dark-Launch Observer: P4 Blocking Budget

### Purpose

Record every foreground `keeper_bash` call that would have auto-promoted to a
background task if `MASC_BASH_AUTO_BG` were on, without actually promoting.

### Enable

```bash
export MASC_BASH_AUTO_BG_OBSERVE=1
```

Inert if `MASC_BASH_AUTO_BG=1` (you are already running the target state).
Also inert when the fiber has no `Eio` clock in scope, because the observer
only instruments the foreground path.

### Log line

```text
auto_bg_would_have_promoted keeper=<name> cmd_hash=<12-hex-md5> duration_ms=<n> budget_ms=<m>
```

Emitted only when `duration_ms >= budget_ms`. `cmd_hash` is a 12-character
MD5 prefix; the raw command is not logged.

### Grep recipe

```bash
grep auto_bg_would_have_promoted logs/keeper/*.log \
  | awk -F'duration_ms=' '{print $2}' \
  | awk '{print $1}' \
  | sort -n | tail -20
```

Tail gives the worst-case durations observed. Histogram by keeper:

```bash
grep auto_bg_would_have_promoted logs/keeper/*.log \
  | awk '{for (i=1;i<=NF;i++) if ($i ~ /^keeper=/) print $i}' \
  | sort | uniq -c | sort -rn
```

### Flip criteria for `MASC_BASH_AUTO_BG`

The default flip is a product decision, not a pure observability one. Suggested
gate:

1. 7-day prod sample of `auto_bg_would_have_promoted` hits.
2. Review which keepers dominate the distribution.
3. Confirm downstream consumers handle the
   `{promoted, background_task_id, partial_output}` response shape.
4. Stage via per-keeper override before global default flip.

`MASC_BLOCKING_BUDGET_MS` tuning can precede the flip. Raising it reduces
promotion frequency; lowering it accelerates it.

## In-process Snapshot Endpoint

Observer and advisory counters are exposed as a public-read JSON endpoint for
dashboards or operator tooling:

```text
GET /api/v1/legendary_bash/counters
```

The response no longer contains retired gate-diff fields. Response shape
mirrors `Legendary_counters.snapshot` 1:1:

```json
{
  "auto_bg_observed": 0,
  "auto_bg_would_have_promoted": 0,
  "typed_advisor_allow": 0,
  "typed_advisor_reject": 0,
  "typed_advisor_cannot_parse": 0,
  "ratios": {
    "auto_bg_promotion_rate": 0.0
  }
}
```

Other snapshot fields cover gh exit classes and Shell_command_gate caller
partitioning. Every counter stays at `0` until the matching observer/advisor
path increments it, so the endpoint itself is cost-free under default posture.

### Derived Ratio

Dashboards and operator tooling should use `Legendary_counters` instead of
open-coding the math.

| Helper | Formula | Use |
| --- | --- | --- |
| `auto_bg_promotion_rate snap` | `would_have_promoted / auto_bg_observed` | Input to `MASC_BLOCKING_BUDGET_MS` tuning + `MASC_BASH_AUTO_BG` default-flip review |

The helper returns `0.0` when the denominator is zero, so the JSON output stays
a finite float even with the observer off.

## Background Task Roster Endpoint

The `keeper_bash` P2 background task lifecycle tracks long-running shell tasks
in an in-process registry (`Bg_task.list`). The roster is exposed for a given
keeper through a second public-read endpoint so dashboards can render "tasks
currently owned by this keeper" without scraping logs:

```text
GET /api/v1/legendary_bash/bg_tasks/<keeper>
```

Response shape:

```json
{
  "keeper": "<name>",
  "count": 2,
  "tasks": ["<task_id_1>", "<task_id_2>"],
  "task_details": [
    {
      "task_id": "<task_id_1>",
      "started_at_unix": 1730000000.123,
      "elapsed_ms": 4821
    }
  ]
}
```

Unknown or quiet keepers legitimately return
`{"count": 0, "tasks": [], "task_details": []}`. The path param is required;
a trailing-slash request (`.../bg_tasks/`) returns 400.

Per-task snapshots (stdout drain, exit status, drop counters) are not surfaced
by this endpoint; those require a stateful `since_*` offset and live inside the
`keeper_bash_output` MCP tool.

## Rollback

Each behavior flag has an inert opt-out path. No restart required.

```bash
# P1 — restore pre-P1 byte-identical JSON shape
export MASC_BASH_SEMANTIC_EXIT=0

# P6 — drop typed verifiable markers
export MASC_BASH_VERIFIABLE_MARKERS=0

# P4 — disable auto-promotion (already default)
unset MASC_BASH_AUTO_BG

# Observer — stop emitting dark-launch log lines
unset MASC_BASH_AUTO_BG_OBSERVE
```

Output caps (`MASC_BASH_OUTPUT_CAP` + `CAP_HEAD` + `CAP_TAIL`) are not treated
as rollback surface; truncation is safer than unbounded logs.

## When to Consult This Runbook

- Before flipping any `MASC_BASH_*` default in production.
- When triaging a surprise JSON field on a `keeper_bash` response.
- When an operator asks what an `auto_bg_would_have_promoted` log line means.
- When adding a new exec-layer flag: mirror the matrix row and observer pattern
  below, then update this file in the same PR.

## Rules for New Legendary Flags

1. Every behavior-changing flag must land as opt-in (`default off`) with an
   explicit matrix row in `ENV-CONTRACT.md §4`.
2. Defaults flip only after a dark-launch observer has confirmed non-regression.
3. Flip PRs must update this runbook's "Current Rollout State" table in the
   same commit.
4. Rollback path stays inert and restart-free on the keeper-bash path.
