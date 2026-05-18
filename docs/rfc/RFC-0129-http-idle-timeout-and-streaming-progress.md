---
rfc: "0129"
title: "Cascade attempt idle-cap: kill the reserve_fraction band-aid"
status: Draft
created: 2026-05-18
updated: 2026-05-18
author: vincent
supersedes: []
superseded_by: null
related: ["0107"]
implementation_prs: [16084, 16158]
---

# RFC-0129: Cascade attempt idle-cap — kill the reserve_fraction band-aid

## §0 Diagnosis reversal (2026-05-18)

A first draft of this RFC framed the fix as a cross-repo change
("OAS HTTP body lacks timeout, add idle-timeout to OAS"). Evidence
collected during PR-1 implementation contradicted that premise:

| layer | claim in first draft | actual state on 2026-05-18 |
|---|---|---|
| `oas/lib/llm_provider/http_client.ml` `post_sync` body read | unbounded `take_all` | wrapped in `Eio.Time.with_timeout_exn` via `body_timeout_s` since OAS 0.195.0 (`complete.ml:656-686`) |
| `oas/lib/llm_provider/http_client.ml` SSE / NDJSON | unbounded line read | per-line `idle_timeout` via `Eio.Time.with_timeout_exn` (`http_client.mli:204-243`) |
| masc-mcp ↔ OAS per-attempt cap | not wired | wired end-to-end: `effective_timeout_sec` → `per_provider_timeout_s` → `Cascade_agent_context.max_execution_time_s` → `Agent_sdk.Builder.with_max_execution_time` (`cascade_agent_context.ml:178-180`) |
| masc-mcp ↔ OAS per-line idle cap | not wired | wired: `Agent_sdk.Builder.with_stream_idle_timeout` (`cascade_agent_context.ml:174`), default `stream_idle_timeout_sec = 120s` (`keeper_runtime_config.mli:75`) |

The premise `keeper_turn_cascade_budget.ml:173-174` was written
against is no longer true. Both caps the band-aid was protecting
against have been enforced by the lower layers for a release cycle.
`degraded_retry_budget_reserve_fraction = 0.5` is now killing
healthy slow streams that would have completed within the un-halved
budget.

## §1 Problem (unchanged)

Fleet measurement, 2026-05-18: 9 keepers × 14 `oas_timeout_budget`
events in 24h, `productive_phase_elapsed_ms` clustered at
**307,500 ± 200ms across every event**. Deterministic — not provider
latency jitter, it is a code cap.

Decomposition matches `lib/keeper/keeper_turn_cascade_budget.ml`:

```
remaining_turn_budget_s            = 600.0
oas_timeout_guard_sec              = 15.0
degraded_retry_budget_reserve_fraction = 0.5
usable_budget                      = 600 - 15            =  585s
retry_reserved_cap                 = 585 × 0.5           = 292.5s
effective_timeout_sec              = min(adaptive, retry_reserved_cap)
                                                          ≈ 292.5s
+ oas_timeout_guard_sec                                  + 15.0s
≈ cascade_attempt_watchdog wall                          ≈ 307.5s
```

The receipt rotation distribution today is
**strict_tool_candidates → glm-spark : 9** versus
**glm-spark → strict_tool_candidates : 5**. Both tier-groups hit the
same cap because they share members (GLM-5-1, codex-spark, ollama)
and route through the same cap chain.

## §2 Why the band-aid is stale

`keeper_turn_cascade_budget.ml:162-181` carries two
self-incriminating comments:

```
/* Root cause is OAS HTTP body lacking timeout
   (`http_client.ml take_all`); this is a band-aid until that lands. */

/* Profiles with a declared fallback must not spend the whole turn on
   the first provider. Keep half of the usable budget for the degraded
   retry. */
```

Both comments **predate**:

1. **OAS 0.195.0** — added `body_timeout_s` on `post_sync`
   (`lib/llm_provider/complete.ml:656-686`). The non-streaming HTTP
   body read is now wall-clock-bounded.
2. **OAS streaming `?idle_timeout`** — `read_sse`/`read_ndjson`
   raise `Eio.Time.Timeout` if no line arrives within
   `idle_timeout` seconds. The deadline resets on each line.
3. **masc-mcp wiring**:
   `Cascade_agent_context.max_execution_time_s` →
   `Agent_sdk.Builder.with_max_execution_time` (per-attempt cap
   already plumbed; populated by
   `keeper_turn_driver_try_provider.max_execution_time_for_attempt`).
   `stream_idle_timeout_s` similarly wired to
   `Agent_sdk.Builder.with_stream_idle_timeout`.

Given these three pieces have all landed, the reserve_fraction is
no longer protecting against "OAS can hang the body read". It is
only producing a smaller per-attempt budget than necessary, which
deterministically truncates healthy slow streams at 307.5s.

Receipt-side scenarios in light of the corrected diagnosis:

| scenario | what the system sees today | what is true |
|---|---|---|
| **A.** provider streaming for 280s, would have finished at 320s | timeout at 307.5s | output exists but is discarded; cascade rotates and pays double cost |
| **B.** provider produces zero bytes after 280s (real hang) | also timeout at 307.5s | OAS `stream_idle_timeout_s=120s` would have caught this at 120s already, but `with_max_execution_time` fires first because reserve_fraction halved it down to 292.5s |
| **C.** provider finishes at 290s | success | the only path the band-aid does not corrupt |

Across the 14-event sample on 2026-05-18 every observed case is **A**.

## §3 Goal

A single, narrow change scope:

1. **Remove** `degraded_retry_budget_reserve_fraction` and the
   `reserve_degraded_retry_budget` parameter from
   `Keeper_turn_cascade_budget.resolve_bounded_oas_timeout_budget_with_turn_budget`.
2. **Update** the stale comment block to reflect the cap chain that
   now exists end-to-end.
3. **Keep** the existing wiring: `with_max_execution_time` continues
   to bound the per-attempt outer wall clock at full usable budget;
   `with_stream_idle_timeout` continues to bound inter-line silence;
   OAS `body_timeout_s` continues to bound non-streaming bodies.

Two related-but-non-gating tracks are explicitly separated below
(§4.2, §4.3) so they cannot stall the fleet fix.

## §4 Implementation

### §4.1 Fleet fix — PR-2 (#16158)

Pure removal. Same-diff legacy deletion per
`CLAUDE.md` workaround-rejection bar:

- `lib/keeper/keeper_turn_cascade_budget.ml`: delete the constant,
  delete the parameter, delete the branch, collapse the source
  labels. First-attempt branch returns
  `Float.min adaptive_timeout_sec usable_budget`.
- `lib/keeper/keeper_turn_cascade_budget.mli`,
  `lib/keeper/keeper_unified_turn.{ml,mli}`: signature update +
  caller cleanup (drops the unused
  `Keeper_cascade_profile.fallback_cascade_for` lookup at this
  call-site — function itself stays alive for other callers).
- `test/test_keeper_unified.ml`: 9 `~reserve_degraded_retry_budget:*`
  argument removals; 2 tests rewritten because they encoded the
  band-aid as expected behavior (242.5 → 485.0, 257.5 → 499.0).

No new flag, no new counter, no cooldown, no transitional baseline.

### §4.2 Pool layer reference — PR-1 (#16084), **not gating**

Independent infrastructure work in `lib/masc_http_client/pool.ml`
(piaf-based) to give the masc-mcp Pool the same idle-timeout +
body-progress shape that OAS already has at its HTTP layer.

Scope and rationale:

- Pool callers today: `lib/server/server_dashboard_http_link_preview.ml`
  and `lib/local/worker_container_types.ml`. Neither is an OAS LLM
  call. Pool fixes do **not** affect cascade attempt timeouts.
- Value of the PR: correct generic API at the Pool layer that
  mirrors OAS's existing idle-timeout pattern, with unit tests for
  steady stream / silent-from-start / mid-stream silence.
- Not gating the fleet fix. PR-2 lands independently of PR-1.

### §4.3 Body-progress observability — deferred

Surfacing `{ first_byte_at, last_chunk_at, bytes_received }` into
`cascade.rotation_attempts[i].body_progress` was in the first draft
as part of the same RFC. It is now out of scope because:

- The fleet 307.5s cluster does not require body-progress to fix —
  it requires the reserve to go away.
- Sourcing body-progress from the OAS layer to masc-mcp receipt
  schema requires an agent_sdk surface extension, which deserves
  its own RFC (provider HTTP boundary cross-cut).
- Deferring is consistent with the workaround-rejection bar's
  "make X visible" anti-pattern — if we made it visible without
  changing behaviour, we would be doing counter-as-fix.

A follow-up RFC may pick this up after the fleet stabilises.

## §5 Rollout

| step | PR | gating |
|---|---|---|
| Pool reference impl (piaf idle-timeout API + unit tests) | PR-1 #16084 | no |
| Fleet fix (band-aid removal) | PR-2 #16158 | this RFC |
| RFC docs (this file) | bundled in PR-1 worktree | no |

PR-2 may merge ahead of PR-1. PR-1 may merge ahead of PR-2. They
are independent.

## §6 Validation

After PR-2 merges, run on a 24h window:

```
rg 'oas_timeout_budget' "$MASC_BASE_PATH"/.masc/keepers/*/execution-receipts/2026-05/*.jsonl \
  | python3 .tmp/from_cascade.py
```

Expected:

1. `productive_phase_elapsed_ms` distribution **stops clustering at
   307,500 ± 200ms**. Real provider latency has visible spread
   (seconds of jitter minimum). If it persists, the cap chain has
   a second band-aid we have not identified yet.
2. Source-label distribution loses
   `*_capped_by_degraded_retry_budget` and
   `*_and_degraded_retry_budget` strings entirely (those labels are
   unreachable after this PR).
3. Total `oas_timeout_budget` event count drops materially. Hangs
   still occur (caught by `stream_idle_timeout_s=120s` upstream of
   the outer cap) but the bulk that were scenario-A truncations
   disappears.

## §7 Non-goals

- Provider-side latency investigation. RFC-0129 is about
  distinguishing the band-aid from real timeouts.
- Streaming UI / token-by-token rendering.
- Replacing `Piaf` in the Pool. PR-1's idle-timeout API fits inside
  Piaf's chunk-iteration; no library swap.
- Modifying OAS. The 0.195.0+ caps are already correct.

## §8 Evidence

- Fleet measurement, 2026-05-18:
  `.tmp/from_cascade.py` output reproduced in the session that
  spawned this RFC (9 keeper × 14 hit distribution + 307,500ms
  deterministic clustering).
- Self-admitting comment at
  `lib/keeper/keeper_turn_cascade_budget.ml:173-174` (replaced by
  PR-2).
- OAS `body_timeout_s` since 0.195.0, `complete.ml:656-686`.
- OAS streaming `idle_timeout` at `http_client.mli:204-243`.
- masc-mcp `with_max_execution_time` wiring at
  `cascade_agent_context.ml:178-180`.

## §9 Open questions

1. Should `stream_idle_timeout_sec = 120s` be tightened post-PR-2?
   With reserve_fraction gone, the outer cap is generous enough
   that a 120s idle window is the dominant signal for real hangs.
   Empirical question — re-measure once §6 #1 is satisfied.
2. The first cascade can now consume up to ~585s of a 600s turn,
   leaving little for the fallback if it truly takes that long.
   Current evidence (14 events, all scenario A) suggests this never
   happens; if §6 surfaces post-PR-2 fallback-starvation cases,
   revisit with a *separate* RFC rather than reintroducing reserve.
3. Should `body_progress` follow up under a new RFC, or fold into
   RFC-0132 (agent_sdk surface extensions)? Pending RFC backlog
   triage.
