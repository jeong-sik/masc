---
status: reference
last_verified: 2026-04-27
code_refs:
  - lib/masc_log/log.ml
  - lib/masc_log/log.mli
---

# Log Severity Taxonomy

> SSOT for `Log.{debug,info,warn,error}` callsite classification across `lib/`.
> Status: Living — refined as production log noise/drift incidents are diagnosed.
> Last Updated: 2026-04-27

## Purpose

`lib/masc_log/log.{ml,mli}` exposes 4 levels (`Debug | Info | Warn | Error`) with no per-callsite contract. As of 2026-04-27 there are **1516 callsites** across `lib/` with no documented severity rule. Top 5 hotspots own ~21% (319 sites):

| File | Sites |
|------|-------|
| `lib/server/server_runtime_bootstrap.ml` | 104 |
| `lib/keeper/keeper_keepalive.ml` | 69 |
| `lib/keeper/keeper_unified_turn.ml` | 57 |
| `lib/server/server_bootstrap_loops.ml` | 49 |
| `lib/keeper/keeper_agent_run.ml` | 40 |

The historical pattern has been **reactive demote/promote PRs** (~8 in the month preceding 2026-04-27 — `#7472, #7508, #7444, #5632, #4586, #6665, #8308, #4871, #10100, #10116, #10355, #10910, #10928, #10946`). Each PR fixes one hotspot after an operator complaint or alarm-fatigue incident. Without a contract, the same drift recurs.

This document is the contract. **A new `Log.*` callsite must match exactly one row of [§ 2 Levels](#2-levels)**; an existing callsite that does not is a CI failure (see [§ 4 Lint](#4-lint)).

## 1. Audience

- **Operator** — reads `WARN`/`ERROR` lines on `journalctl -u masc-mcp -p warning`. Expects every line to be actionable.
- **Developer** — reads `INFO`/`DEBUG` for lifecycle/tracing. Tolerates volume.
- **Alerting** — pages on `ERROR`. Anything else is dashboard-only.

The taxonomy is built around **operator action**. If a log line does not change what the operator does, it does not belong above `INFO`.

## 2. Levels

### `Error`

| Field | Content |
|-------|---------|
| Trigger | An infrastructure invariant is broken AND auto-recovery is impossible |
| Operator action | Human intervention required (restart, config fix, file system repair, escalation) |
| Marker (must) | The log call sits inside a branch that catches an unexpected exception, OR detects state corruption (e.g., file present but unparseable, expected key absent in normalised output), OR emits `operator_broadcast_required` / `disposition=pause_human` |
| Marker (must NOT) | Triggered by model output, network flake, or any retry-able failure |
| Cardinality | Low — a healthy fleet should produce ≤1/day per `Error` site |
| Example (good) | `Log.Misc.error "tool_usage_log: init failed: %s" exn` — durable store init failed, dashboard now blind |
| Anti-pattern | `Log.Keeper.error "keeper cycle FAILED ... cascade=keeper_unified ..."` for `required_tool_contract_violation` — model behavior, fleet-wide expected, not actionable |

### `Warn`

| Field | Content |
|-------|---------|
| Trigger | Degraded behavior with auto-recovery, or a precondition violation that the caller must learn from |
| Operator action | Glance, then dismiss unless rate spikes |
| Marker (must) | Auto-recovery path exists in the same scope (retry, fallback, default), OR the message itself describes the recovery |
| Marker (must NOT) | Used as a proxy for "I want this to be visible" — promote to `Error` if action is required, demote to `Info` if not |
| Cardinality | Medium — bursts of ~10/min on incident, baseline ~1/h |
| Example (good) | `Log.Misc.warn "tool_usage_log: append failed for %s: %s; recording coverage_gap"` — write failed but coverage_gap captures the loss |
| Anti-pattern | `silent:coord_join_normalize ... persona_not_found ... logging-only mode, proceeding with original agent_name` — silent fallback that produces identity drift is **`Error`**, not `Warn`. The "silent" prefix is itself a structural marker (see [§ 3.1](#31-silent-fallback)). |

### `Info`

| Field | Content |
|-------|---------|
| Trigger | A user-visible lifecycle event happened — keeper boot, PR merged, task transition, room join |
| Operator action | None. Audit trail only. |
| Marker (must) | Discrete event with low repetition (≤1/keeper/turn or ≤1/request) |
| Marker (must NOT) | Periodic tick, watchdog heartbeat, "still running" signal — those are `Debug` |
| Cardinality | High — but bounded by event count, not loop iteration |
| Example (good) | `Log.Keeper.info "keeper:%s turn=%d total_turns=%d ..."` — one line per turn completion |
| Anti-pattern | `Log.Keeper.info "watchdog tick noop=1 ... fiber_age=180"` — emitted every 30s per keeper. 11 keepers × 2/min × 1440min = 31k lines/day of pure noise. Demoted by `#10910` 2026-04-26. |

### `Debug`

| Field | Content |
|-------|---------|
| Trigger | Internal state inspection useful only when reproducing a bug |
| Operator action | Off by default. Enabled per-incident via `MASC_LOG_LEVEL=debug`. |
| Marker (must) | Periodic, deterministic, high-volume, OR detail that would clutter `Info` |
| Marker (must NOT) | Anything an operator may need to see without a config change |
| Cardinality | Unbounded — assume it floods when enabled |
| Example (good) | `Log.Keeper.debug "DOCKER_EXEC: keeper=... cwd=... cmd=... network=..."` — full command echo, useful for incident replay |
| Anti-pattern | Silent skip of a `Debug` log just because adding it "feels excessive" — under-instrumentation is also a failure mode |

## 3. Anti-pattern catalog

These are repeating misclassifications observed in `git log --grep='demote\|promote'` over the last 90 days. CI lint ([§ 4](#4-lint)) catches them syntactically; this section explains the semantics.

### 3.1 Silent fallback

| | |
|--|--|
| Pattern | Message contains `silent` or `logging-only mode` or `silently` AND severity is `Info`/`Warn` |
| Why wrong | A silent fallback IS the failure. The whole point is that downstream behavior diverges from the configured intent (identity drift, wrong cred, default model). The operator MUST know. |
| Correct | `Error` AND emit a structured field `silent_fallback_kind=<reason>` so dashboards can count |
| Origin | `silent:coord_join_normalize ... persona_not_found ... logging-only mode` (production 2026-04-27 09:17:48). `nick0cave` joined as `nick0cave-proud-shark` instead of canonical, identity drift not surfaced. |

### 3.2 Operator broadcast

| | |
|--|--|
| Pattern | Message contains `operator_broadcast_required` or `disposition=pause_human` or `awaiting_approval` AND severity is `Info` |
| Why wrong | The whole semantic of operator-broadcast is "human attention needed". `Info` puts it under noise floor. |
| Correct | `Warn` if degraded but auto-resumable, `Error` if the keeper is paused and a human must act |
| Origin | `Log.Keeper.info "janitor: operator_broadcast_required emitted disposition=pause_human reason=tool_required_unsatisfied seq=14792"` (production 2026-04-27 09:17:05) — keeper paused, no operator alert. |

### 3.3 Model behavior as Error

| | |
|--|--|
| Pattern | Message describes a syntactic / behavioral mistake by the LLM (`tool contract violated`, `gh syntax`, `JSON parse failed in tool args`) AND severity is `Error` |
| Why wrong | Model behavior is a **distribution**, not a fault. Logging every model-output flake as `Error` produces alarm inflation — operators learn to ignore `Error`, then miss the real ones. |
| Correct | `Warn`, with a per-keeper rate-limit OR aggregation. Promote to `Error` only when escalation policy kicks in (e.g., 5 violations in 10 turns → contract permanently broken). |
| Origin | `Log.Keeper.error "keeper:%s required tool contract violated (turn=%d, tools=%d)"` — fleet-wide ~40/day. Memory `proactive_turn_contract_violation_dominant` documents the pattern. |

### 3.4 Watchdog tick / periodic heartbeat

| | |
|--|--|
| Pattern | Message contains `watchdog tick`, `keepalive`, `reconcile`, `heartbeat` AND severity is `Info` AND emission is unconditional (i.e., no `noop=true` short-circuit) |
| Why wrong | Periodic emissions dominate log volume. 11 keepers × 1 tick/30s × 4 logs/tick = 5280 lines/h before any real event. |
| Correct | `Debug` for the tick itself; `Info` only when the tick observes a state change (e.g., `noop=false`); `Warn` when the tick detects a stuck condition |
| Origin | `Log.Keeper.info "janitor: watchdog tick noop=1 ..."` demoted by `#10910` (2026-04-26). |

### 3.5 Validation success

| | |
|--|--|
| Pattern | Message describes successful coercion, parse, or validation (`tool_input_validation coerced args`, `validated request`) AND severity is `Info` |
| Why wrong | Successful validation is the contract — logging it is logging "the system worked". Volume × zero signal. |
| Correct | `Debug`. Reserve `Info` for validation **failures** that auto-recovered. |
| Origin | `Log.Misc.info "tool_input_validation coerced args for keeper_shell"` — emitted on every tool call, ~1k+/h fleet-wide. |

## 4. Lint

`scripts/ci/check-log-severity-anti-patterns.sh` (planned, see [§ 6 Migration](#6-migration)) enforces:

| Rule | Pattern | Reason |
|------|---------|--------|
| L1 | `Log\.[A-Z][a-z]+\.(info\|warn).*silent` | Silent fallback should be `Error` (§ 3.1) |
| L2 | `Log\.[A-Z][a-z]+\.info.*operator_broadcast` | Operator broadcast is `Warn`/`Error` (§ 3.2) |
| L3 | `Log\.[A-Z][a-z]+\.error.*(contract violated\|gh_command_shape\|JSON parse failed)` | Model behavior is `Warn` (§ 3.3) |
| L4 | `Log\.[A-Z][a-z]+\.info.*(watchdog tick\|keepalive\|heartbeat)` | Periodic ticks are `Debug` (§ 3.4) |
| L5 | `Log\.[A-Z][a-z]+\.info.*(coerced\|validated)` | Validation success is `Debug` (§ 3.5) |

Each rule is a `rg -P` regex over `lib/`. Exit 1 on any match outside an explicit allowlist comment (`(* log-severity-allow:LN-N <reason> *)`).

## 5. Cardinality budget (informal)

A healthy fleet steady state should respect:

| Level | Per-minute | Per-day |
|-------|-----------|---------|
| Error | ≤1 | ≤100 |
| Warn  | ≤30 | ≤10k |
| Info  | ≤300 | ≤300k |
| Debug | unbounded (off by default) | — |

Production deviations from these numbers are themselves a signal — see `dashboards/log-severity-cardinality.json` (planned).

## 6. Migration

This document is the contract; existing 1516 callsites are unaudited. Migration is staged:

1. **Phase 0 — this document** — ratify the rules. ✓ (PR introducing this file)
2. **Phase 1 — lint** — add `scripts/ci/check-log-severity-anti-patterns.sh` with rules L1–L5 enforced on `lib/`. Allowlist comments for known intentional deviations.
3. **Phase 2 — top-5 hotspot reclassify** — `server_runtime_bootstrap.ml`, `keeper_keepalive.ml`, `keeper_unified_turn.ml`, `server_bootstrap_loops.ml`, `keeper_agent_run.ml` (319 sites). One PR per file; each PR audits + reclassifies + verifies cardinality.
4. **Phase 3 — long tail** — remaining ~1200 sites swept in domain batches (server, keeper, dashboard, oas-bridge, coord). Each batch ≤ 100 sites.
5. **Phase 4 — cardinality dashboard** — Prometheus counter per `(file, level)` exposed on `/metrics`, dashboard surfaces deviations from § 5.

Phases 1–4 are independent PRs. Migration order is not load-bearing — the lint catches drift even if Phase 2 is interleaved.

## 7. Known intentional deviations

Reserved. Add allowlist entries here when CI lint is bypassed for a structural reason (e.g., a one-shot bootstrap message that legitimately straddles two levels). Each entry must cite the allowlist comment in source and explain why the rule does not apply.

## References

- `lib/masc_log/log.ml` — implementation
- `lib/masc_log/log.mli` — public API + level type
- Memory: `proactive_turn_contract_violation_dominant`, `policy-runtime-drift-gate`
- Historical PRs: `#10910`, `#10928`, `#10946`, `#7508`, `#7444`, `#5632`
