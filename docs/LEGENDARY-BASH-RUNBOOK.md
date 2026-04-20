---
status: runbook
last_verified: 2026-04-20
code_refs:
  - lib/exec/exec_semantic.ml
  - lib/exec/exec_buffer.ml
  - lib/exec/exec_run.ml
  - lib/exec_core.ml
  - lib/cdal_judge.ml
  - lib/worker_dev_tools.ml
  - lib/keeper/keeper_exec_shell.ml
---

# Legendary Bash Runbook

This runbook documents the operator surface of the "Legendary Bash" exec
rework — the P1–P6 upgrades to `keeper_bash` / `keeper_shell` — and the
procedure for interpreting dark-launch observer logs before flipping the
remaining defaults.

## Related Documents

- [`ENV-CONTRACT.md`](./ENV-CONTRACT.md) §4 — authoritative flag matrix
- [`BOOT-ENV-STATE-INVENTORY.md`](./BOOT-ENV-STATE-INVENTORY.md)
- `planning/graceful-panda/Legendary-Bash-plan.md` (source plan, 6 phases)

## Scope

- Covers: `keeper_bash`, `keeper_shell`, exec semantic exit, output
  truncation, background task lifecycle, AST safety gate, verification
  contract markers.
- Does not cover: the cascade verifier itself or the approval layer for
  MCP tools. Those are separate surfaces.

Every flag in this runbook is `request_dynamic` on the keeper-bash path:
operators can flip without a process restart and the next `keeper_bash`
call observes the new value.

## Current Rollout State

As of `last_verified`:

| Phase | Feature | Default | Status |
| --- | --- | --- | --- |
| P1 | `semantic_exit` typed return code | **on** | flipped (post-PR soak) |
| P2 | background task lifecycle | n/a | delivered, opt-in per call |
| P3 | head+tail truncation | on | delivered |
| P4 | auto-background on blocking budget | off | **observer live** (`MASC_BASH_AUTO_BG_OBSERVE`) |
| P5 | AST-only single-gate safety | off | **observer live** (`MASC_BASH_AST_SHADOW_LOG`) |
| P6 | `verifiable_markers` emission | **on** | flipped (post-PR soak) |

Two dark-launch observers (P4 and P5) are the active operational surface
today. Every other Legendary flag is already on or opt-in per call.

## Flag Matrix (Quick Reference)

Authoritative definitions live in `ENV-CONTRACT.md §4`. Operator-facing
summary:

| Variable | Default | Opt-out tokens | What changes |
| --- | --- | --- | --- |
| `MASC_BASH_SEMANTIC_EXIT` | on | `0`, `false`, `no`, `off` | drops `return_code_interpretation` JSON field |
| `MASC_BASH_OUTPUT_CAP` | on | — | head+tail truncation; `MASC_BASH_CAP_HEAD`/`TAIL` override per-stream caps |
| `MASC_BASH_VERIFIABLE_MARKERS` | on | `0`, `false`, `no`, `off` | drops typed `verifiable_markers` from `Cdal_judge` |
| `MASC_BASH_AUTO_BG` | off | — | foreground commands that outrun the blocking budget auto-promote |
| `MASC_BLOCKING_BUDGET_MS` | `15000` | — | consumed by `AUTO_BG` (promotion) and `AUTO_BG_OBSERVE` (would-have-promoted) |
| `MASC_BASH_AUTO_BG_OBSERVE` | off | — | dark-launch observer for P4 |
| `MASC_BASH_AST_ONLY` | off | — | replaces regex+AST dual-gate with AST-only |
| `MASC_BASH_AST_SHADOW_LOG` | off | — | dark-launch observer for P5 |

## Dark-Launch Observer: P5 Gate Shadow

### Purpose
Record every case where the legacy regex gate and the new AST gate would
disagree on a real `keeper_bash` call, without changing the execution
outcome.

### Enable

```bash
export MASC_BASH_AST_SHADOW_LOG=1
```

Inert if `MASC_BASH_AST_ONLY=1` (you are already running the target
state).

### Log line

```
gate_diff_shadow keeper=<name> cmd_hash=<12-hex-md5> diff=<tag> legacy=<tag> shadow=<tag>
```

Emitted only on non-`Agree` outcomes. `cmd_hash` is a 12-character MD5
prefix — the raw command is never logged.

### Diff tags

| Tag | Meaning |
| --- | --- |
| `agree` | not logged (suppressed) |
| `shadow_stricter` | AST denies, regex allows — regressions if flipped today |
| `shadow_permissive` | AST allows, regex denies — potential win if flipped, audit manually |
| `parse_aborted` / `too_complex` | AST bailed out, regex still authoritative |

### Grep recipe

Aggregate one day of shadow logs:

```bash
grep gate_diff_shadow logs/keeper/*.log \
  | awk '{for (i=1;i<=NF;i++) if ($i ~ /^diff=/) print $i}' \
  | sort | uniq -c
```

### Flip criteria for `MASC_BASH_AST_ONLY`

All of the following must hold on a rolling 7-day window:

1. `shadow_stricter` count is `0` (any case is a real regression).
2. `parse_aborted` + `too_complex` is less than 1% of total
   `keeper_bash` calls (remaining AST gaps are tolerable).
3. N=1000+ prod calls observed (statistical power).

The flip covenant test `test_gate_diff.ml` must also still be green.

## Dark-Launch Observer: P4 Blocking Budget

### Purpose
Record every foreground `keeper_bash` call that would have auto-promoted
to a background task if `MASC_BASH_AUTO_BG` were on — without actually
promoting.

### Enable

```bash
export MASC_BASH_AUTO_BG_OBSERVE=1
```

Inert if `MASC_BASH_AUTO_BG=1` (you are already running the target
state). Also inert when the fiber has no `Eio` clock in scope, because
the observer only instruments the foreground path.

### Log line

```
auto_bg_would_have_promoted keeper=<name> cmd_hash=<12-hex-md5> duration_ms=<n> budget_ms=<m>
```

Emitted only when `duration_ms >= budget_ms`. Same `cmd_hash` convention
as P5.

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

The default flip is a product decision, not a pure observability one —
the plan explicitly marks it as `Opt-in only` until cumulative data
justifies otherwise. Suggested gate:

1. 7-day prod sample of `auto_bg_would_have_promoted` hits.
2. Review which keepers dominate the distribution.
3. Confirm downstream consumers handle the
   `{promoted, background_task_id, partial_output}` response shape.
4. Stage via per-keeper override before global default flip.

`MASC_BLOCKING_BUDGET_MS` tuning can precede the flip. Raising it
reduces promotion frequency; lowering it accelerates it.

## Rollback

Each Legendary flag has an inert opt-out path. No restart required.

```bash
# P1 — restore pre-P1 byte-identical JSON shape
export MASC_BASH_SEMANTIC_EXIT=0

# P6 — drop typed verifiable markers
export MASC_BASH_VERIFIABLE_MARKERS=0

# P4 — disable auto-promotion (already default)
unset MASC_BASH_AUTO_BG

# P5 — return to dual-gate (already default)
unset MASC_BASH_AST_ONLY

# Observers — stop emitting dark-launch log lines
unset MASC_BASH_AUTO_BG_OBSERVE
unset MASC_BASH_AST_SHADOW_LOG
```

Output caps (`MASC_BASH_OUTPUT_CAP` + `CAP_HEAD` + `CAP_TAIL`) are not
treated as rollback surface — truncation is always safer than unbounded
logs.

## When to consult this runbook

- Before flipping any `MASC_BASH_*` default in production.
- When triaging a surprise JSON field on a `keeper_bash` response.
- When an operator asks "what do these `gate_diff_shadow` /
  `auto_bg_would_have_promoted` log lines mean?"
- When adding a new exec-layer flag: mirror the matrix row and observer
  pattern below, then update this file in the same PR.

## Rules for new Legendary flags

1. Every behavior-changing flag must land as opt-in (`default off`) with
   an explicit matrix row in `ENV-CONTRACT.md §4`.
2. Defaults flip only after a dark-launch observer has confirmed
   non-regression.
3. Flip PRs must update this runbook's "Current Rollout State" table in
   the same commit — the table is the operator's source of truth.
4. Rollback path stays inert and restart-free on the keeper-bash path.
