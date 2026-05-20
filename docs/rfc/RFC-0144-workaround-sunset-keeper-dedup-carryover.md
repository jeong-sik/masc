# RFC-0144 — Workaround Sunset Tracking for Keeper Dedup Carryovers

- **Status**: Active
- **Created**: 2026-05-20
- **Owner**: keeper observability
- **Predecessors**: masc-mcp #16389, masc-mcp #16470
- **Extensions**: masc-mcp #15792 (pair-repair fabrications counter), masc-mcp #15808 (drain batch_size burst visibility) — added 2026-05-20 from Cluster B sample-verify
- **Evidence base**: `~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md` §Cluster E (initial), §Cluster B (extension)

## 1. Motivation

PR audit (2026-05-20) classified four recently-merged PRs as workarounds (Cluster E + Cluster B) that breached the CLAUDE.md "Override 조건":

- **No `WORKAROUND:` label.**
- **No replacement RFC linked at merge time.**
- **No `removal target: <date or RFC>` in PR body.**

The initial two PRs (#16389, #16470) are typed dedup layers over real, persistent error streams. They suppress symptom emission rate (ERROR → DEBUG demote, Prometheus counter substitute) but do not address the underlying failure rate.

The two Cluster B additions (#15792, #15808) are Counter-as-Fix layers — they make a real defect (`tool_call`/`tool_result` pair fabrication, drain burst from unbounded producer) visible via `/metrics` without fixing it. Sub-agent triage classified them as "audit-requested, INTENTIONAL" but sample-verify re-classified them as workarounds: the counter is alarm, not fix. The underlying repair function `Keeper_context_core.repair_broken_tool_call_pairs` matches the CLAUDE.md "Repair / Sanitize" anti-pattern (fabricate on read instead of reject at write boundary). The drain WARN-with-streak matches the symptom-suppression cluster (the underlying issue is backpressure absence, not log volume).

Without sunset tracking, all four layers accumulate as permanent infrastructure and AI agents subsequently treat them as a reasonable precedent (CLAUDE.md "누적 메커니즘").

This RFC declares all four layers as *carryover* workarounds with explicit root-fix dependencies and measurable sunset criteria.

## 2. Scope

In scope:

- `lib/keeper_recording_error_state/keeper_recording_error_state.ml` — registry-side `record_error` dedup (PR #16389), `error_kind` closed sum with 11 inhabitants.
- `lib/keeper/keeper_tools_oas.ml` retry-loop dedup block (PR #16470, around lines 770–820) routed through `Keeper_tool_retry_state`.
- `lib/keeper/keeper_context_core.ml` `repair_broken_tool_call_pairs_with_stats` (line 488) — the underlying read-side fabrication function the #15792 counter observes. Counter definition at `lib/keeper/keeper_metrics.ml:547` (`metric_keeper_compaction_pair_repair_fabrications`); increment site at `lib/keeper/keeper_compact_policy.ml:343-362`.
- `lib/keeper/keeper_compact_audit.ml` drain loop (line 522, `spawn_subscriber` fiber) — burst visibility counters + streak WARN added by #15808. Counter definitions at `lib/keeper/keeper_metrics.ml:604-614` (`metric_keeper_compact_audit_drain_batches`, `metric_keeper_compact_audit_drain_batch_size_bucket`).

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

### Cluster B carryovers (added 2026-05-20)

| Carryover | PR | Counter / observable | Root issue / RFC | Status |
|---|---|---|---|---|
| `tool_call_pair_fabrication` | #15792 | `masc_keeper_compaction_pair_repair_fabrications_total{kind=downgraded_tool_use\|downgraded_tool_result}` at `keeper_compact_policy.ml:343-362`; underlying repair at `keeper_context_core.ml:488` | Write-time `tool_call`/`tool_result` pair validation at LLM response boundary — reject malformed pair instead of fabricating downgraded text on read. Separate RFC candidate (`RFC-XXXX Tool-Call-Pair Write-Time Enforcement`). | Unassigned. |
| `compact_audit_drain_burst` | #15808 | `masc_keeper_compact_audit_drain_batches_total`, `masc_keeper_compact_audit_drain_batch_size_bucket_total{bucket}` at `keeper_compact_audit.ml:522-586`; streak WARN at lines 569-582 | Backpressure signal propagation from `keeper_compact_audit` subscriber to producer (drain interval dynamic adjust OR producer-side throttle on 9-keeper compaction storm). Counter is alarm-only until backpressure mechanism exists. | Unassigned. |

Both Cluster B carryovers were merged without `WORKAROUND:` label, replacement RFC link, or `removal target:` line. Sub-agent triage classified them as "audit-requested, INTENTIONAL"; sample-verify (2026-05-20) re-classified them as Counter-as-Fix / Repair-Sanitize workarounds. This RFC retroactively applies the Override 조건 metadata.

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

### Pair-repair fabrication sunset (PR #15792)

The pair-repair fabrication counter + underlying `repair_broken_tool_call_pairs_with_stats` function are eligible for removal when:

1. Write-time `tool_call`/`tool_result` pair validation lands (replacement RFC merged to main).
2. **30-day rolling `masc_keeper_compaction_pair_repair_fabrications_total{kind="downgraded_tool_use"}` and `{kind="downgraded_tool_result"}` deltas both = 0**.

When both conditions hold, the removal PR drops:

- The `bump_pair_repair` block in `keeper_compact_policy.ml:343-362`.
- `metric_keeper_compaction_pair_repair_fabrications` declaration in `keeper_metrics.ml` + `.mli`.
- `repair_broken_tool_call_pairs` / `repair_broken_tool_call_pairs_with_stats` from `keeper_context_core.ml` and all callers (currently lines 516, 1064, 1093, 1136).

Until the write-time validation RFC exists, the counter remains as alarm. The 30-day-zero condition cannot be met without the root fix, so this sunset is dependency-gated, not time-gated.

### Compact-audit drain burst sunset (PR #15808)

The drain burst counters + streak WARN are eligible for removal when:

1. Backpressure signal propagation from `keeper_compact_audit` subscriber to producer exists (drain interval dynamic adjustment OR producer-side throttle that bounds inflight events to a configured ceiling).
2. **7-day rolling P95 of `masc_keeper_compact_audit_drain_batch_size_bucket_total{bucket="100_499"}` and `{bucket="500_plus"}` deltas both = 0**, i.e. no batch ever crosses 100 events.

When both conditions hold, the removal PR drops:

- The `over_threshold_streak` ref + `batch_size_bucket_label` + counter increments + WARN block in `keeper_compact_audit.ml:522-586`.
- `metric_keeper_compact_audit_drain_batches` and `metric_keeper_compact_audit_drain_batch_size_bucket` declarations in `keeper_metrics.ml` + `.mli`.

The 100-burst-zero condition is achievable only if backpressure bounds producer rate. As long as the 9-keeper compaction storm can push >100 events per 250ms drain, the counter must remain for operator visibility.

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
- `tool_call_pair_fabrication` write-time enforcement RFC is unassigned. The repair function has 4 caller sites in `keeper_context_core.ml` plus the compact_policy call site; the replacement RFC must cover all paths and define the reject semantics (drop message? error to operator? upstream report?).
- `compact_audit_drain_burst` backpressure RFC is unassigned. Producer side is `Agent_sdk_metrics_bridge`; a throttle there changes event delivery semantics across all subscribers. Should be scoped before the sunset PR is written.

## 7. References

- Audit report: `~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md` §Cluster E (initial), §Cluster B (extension)
- PR #16389 — registry recording_error dedup (Cluster E)
- PR #16470 — tool retry dedup (Cluster E)
- PR #15792 — compaction pair-repair fabrications counter (Cluster B, added 2026-05-20)
- PR #15808 — compact-audit drain batch_size burst visibility V17 (Cluster B, added 2026-05-20)
- CLAUDE.md §워크어라운드 거부 기준 (Override 조건)
- RFC-0088 — Counter-as-Fix umbrella (related, not parent)
