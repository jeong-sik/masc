# RFC-0144 — Workaround Sunset Tracking for Keeper Dedup Carryovers

- **Status**: Active
- **Created**: 2026-05-20
- **Owner**: keeper observability
- **Predecessors**: masc-mcp #16389, masc-mcp #16470
- **Evidence base**: `~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md` §Cluster E

## 1. Motivation

PR audit (2026-05-20) classified two recently-merged PRs as Cluster E (cap / dedup / demote / repair) workarounds that breached the CLAUDE.md "Override 조건":

- **No `WORKAROUND:` label.**
- **No replacement RFC linked at merge time.**
- **No `removal target: <date or RFC>` in PR body.**

Both PRs are typed dedup layers over real, persistent error streams. They suppress symptom emission rate (ERROR → DEBUG demote, Prometheus counter substitute) but do not address the underlying failure rate. Without sunset tracking, the dedup arms accumulate as permanent infrastructure and AI agents subsequently treat them as a reasonable precedent (CLAUDE.md "누적 메커니즘").

This RFC declares both layers as *carryover* workarounds with explicit per-`error_kind` removal dependencies and a measurable sunset criterion.

## 2. Scope

In scope:

- `lib/keeper_recording_error_state/keeper_recording_error_state.ml` — registry-side `record_error` dedup (PR #16389), `error_kind` closed sum with 11 inhabitants.
- `lib/keeper/keeper_tools_oas.ml` retry-loop dedup block (PR #16470, around lines 770–820) routed through `Keeper_tool_retry_state`.

Out of scope:

- The dedup mechanics themselves. This RFC does not modify behaviour. It only adds tracking and removal criteria.
- Other Cluster E entries (oas #1564 etc.) — separate RFC.

## 3. Root-fix dependencies (per `error_kind`)

PR #16389 `error_kind` arms map to known root work:

| `error_kind` | 24h volume (2026-05-16) | Root issue / RFC | Status |
|---|---|---|---|
| `Sandbox_docker` | 142 | RFC-0097 container reuse + sandbox lifecycle | Phase 1 merged (PR #15728). Phase 2 outstanding. |
| `Path_syntax_blocked` | 62 | RFC-0091 PR-2 typed argv (execve-style) | PR-1 merged; PR-2 evidence inventory complete (`feedback`/`project_rfc_0091_pr_2_evidence_inventory.md`). |
| `Stale_turn_timeout` | 13 | TBD — keeper turn lifecycle timeout audit needed | Unassigned. |
| `Oas_timeout_budget` | 5 | TBD — OAS budget enforcement RFC needed | Unassigned. |
| `Fiber_unresolved` | 18 | TBD — Eio fiber cancellation audit | Unassigned. |
| `State_machine_guard` | (sub-threshold) | RFC-0072 keeper sub-FSM transitions typed | Implemented. Residual events likely indicate spec drift. |
| `Expected_version_mismatch` | (sub-threshold) | CAS contention — design-bounded; expected non-zero | Acceptable; dedup retains for noise control until rate >50/day. |
| `Cascade_resolution_failure` | (sub-threshold) | RFC-0058 cascade typed errors | Implemented. Re-audit after PR #15040/15070/15089 settle. |
| `Unknown_phase_transition` | (sub-threshold) | RFC-0072 + KSM exhaustive arms | Implemented. Residual events = bug, file issue. |
| `Auth_token_mismatch` | (sub-threshold) | Identity layer — outside this RFC | Track separately. |
| `Other` | 59 | Re-classification work | This RFC's removal criterion does not apply; `Other` must shrink via re-classification, not via root fix. |

PR #16470 retry dedup applies uniformly to *all* tool retry failures. Its root-fix dependency is the union of:

- Per-tool failure rate root fixes (each tool's `error_kind` traces back to the table above).
- `lib/keeper/keeper_tool_retry_state.ml` `Threshold_silence` semantics — once root rate drops, threshold trips disappear and the dedup becomes inert.

## 4. Sunset criteria

### Per-`error_kind` sunset (PR #16389)

An `error_kind` arm in `Keeper_recording_error_state` is eligible for removal when:

1. Its root-fix dependency (column 3 of §3) is **merged to main**.
2. **7-day rolling occurrence in system_log < 5/day** for that `error_kind`.
3. **`masc_keeper_recording_error_dedup_total{error_kind="X"}` counter < 50** over the same 7-day window.

When all three conditions hold, the `error_kind` arm is removed in a single PR that:

- Drops the variant from the `error_kind` sum.
- Removes the classifier branch.
- Drops the matching Prometheus label.
- Leaves the dedup layer intact for remaining arms.

When the **last** arm is removed, the entire `keeper_recording_error_state` sub-library is deleted in the same PR that removes it.

### Whole-layer sunset (PR #16470)

The retry-loop dedup in `keeper_tools_oas.ml` is eligible for removal when:

1. Aggregate `tool <NAME> returned error result (N/3)` ERROR rate in system_log **< 10/day for 7 days rolling**.
2. `masc_keeper_tools_oas_failures{site="retry_threshold_silence"}` counter **= 0 over the same window**.

## 5. Acceptance metric

System_log 30-day rolling baseline at this RFC's creation (2026-05-20, derived from `system_log_2026-05-16.jsonl`, single-day sample extrapolated):

- `Sandbox_docker`: 142/day
- `Path_syntax_blocked`: 62/day
- `Other`: 59/day
- Sum of sub-threshold: ~36/day
- Total `record_error` events: ~300/day

A monthly check (1st of each month) reads `system_log` for the prior 30 days and compares per-`error_kind` rate against the baseline. RFC body is amended with the snapshot. If any arm meets §4 sunset criteria, a sunset PR is opened the same day.

## 6. Open questions

- `Stale_turn_timeout` / `Oas_timeout_budget` / `Fiber_unresolved` root work is unassigned. These arms will linger longest. Tracking issue needed.
- `Other` bucket of 59/day requires classification work, not root fix. Should split-out PRs land before any sunset PR, or in parallel.

## 7. References

- Audit report: `~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md` §Cluster E
- PR #16389 — registry recording_error dedup
- PR #16470 — tool retry dedup
- CLAUDE.md §워크어라운드 거부 기준 (Override 조건)
- RFC-0088 — Counter-as-Fix umbrella (related, not parent)
