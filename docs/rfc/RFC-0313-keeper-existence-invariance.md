# RFC-0313 — Keeper Existence Invariance (failure modulates pacing and routing, never existence)

- Status: Draft
- Area: `lib/keeper/` (turn failure post-processing, supervisor sweep/launch, pause policy, error classification, rotation), `lib/keeper_failure_policy/`, `lib/runtime/` ([pause] knobs), dashboard pacing projection
- Supersedes: the failure-driven halves of RFC-0152 (auto-resume taxonomy), RFC-0246 remnants; extends RFC-0303 (which retired heuristic no-progress pause) to *all* failure-driven existence changes
- Builds on / touches: RFC-0303 (stimulus-gated wake, "판단은 LLM 경계"), RFC-0260 / PR #22970 (failover chain restoration), #23452 (supervisor honors Pause_keeper), #23456 (cooldown cause preservation), RFC-0002 (originally: Paused = operator-paused only)
- Evidence base: 6-lens audit 2026-07-07 (88 findings, 23/24 adversarially confirmed), 48h live logs `~/me/.masc/logs/system_log_2026-07-05..07.jsonl`

## Operator principle (verbatim intent)

> Keeper 가 멈추는 상태가 안 되도록 최대한 fail open 으로. 하드코딩으로 멈추거나 판단하거나 상태 위임은 그만. 무한히 도는 거야 — 설정 런타임을 기본으로.

Restated as an invariant this RFC enforces:

**A turn failure may change *when* the next turn runs (pacing) and *where* it runs (routing). It may never change *whether* the keeper exists (paused / crashed / dead).**

Existence is owned by exactly two axes: operator intent (register / operator-pause / shutdown) and process reality (fiber alive / fiber dead → relaunch). Failure outcomes touch neither.

## Current state (audited, main `d097d9d9dc`)

### The three-rung existence ladder — every rung a hardcoded count

| Rung | Trigger | Site | Recovery |
|---|---|---|---|
| auto-pause | streak ≥ `turn_fail_streak_threshold` (=3, `config/runtime.toml:1020`) | `keeper_unified_turn_failure.ml:75-131` | backoff 1h→×2→24h cap, or **manual** (idle / contract-attention) |
| fiber crash | streak ≥ `MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES` (=10, `env_config_keeper.ml:719`) | `keeper_unified_turn_failure.ml:210-227` `raise Keeper_fiber_crash` | supervisor restart (consumes budget) |
| **DEAD** | `restart_count ≥ max_restarts` (=5, env) | `keeper_supervisor.ml:290` `to_mark_dead` | **none — no automated path back** |

Six in-turn pause paths (turn-failure streak, contract-attention `keeper_unified_turn_success.ml:751-768`, livelock `keeper_unified_turn_livelock_block.ml:67-86`, overflow `keeper_turn_runtime_budget.ml:655-712`, resilience `:871-886`, ambiguous-partial-commit `keeper_unified_turn.ml:729-750`) plus three supervisor crash-sweep arms (`keeper_supervisor.ml:299-339`). Among all of them, exactly **one** involves a judgment boundary (ambiguous-partial-commit → HITL). Zero involve an LLM. Every other stop is decided by a literal.

### Rotation is provider-only; everything else walks the ladder

- `Agent/Mcp/Config/Serialization/Io/Orchestration/Internal` errors and API sub-500 classes get rotation reason `None` (`keeper_error_classify.ml:524-551`) — no failover attaches, the failure goes straight to the streak counter.
- The cycle-permission matrix (`:691-712`) hard-caps `Hard_quota / Rate_limit / Capacity_backpressure / *_no_progress`; the backpressure comment *declares* "the keeper pauses after candidates are exhausted" as the design.
- Return-to-base is already correct: rotation is not persisted; every turn restarts from the `runtime.toml` assignment (`keeper_unified_turn.ml:119`). The operator's "설정 런타임 기본" requires no new code.

### The root defect is missing pacing, not the loop itself

48h live evidence: 15,254 rotation retries (95.9% `capacity_backpressure`, peak ~70/min); one keeper (nick0cave) alone produced 10,645 retries ping-ponging between two saturated runtimes (5,428 + 5,047); 16,628 `pause_human` broadcasts (99.9% `internal_error`) mirrored the storm 1:1. The system *can* loop forever — it just does so with zero revisit spacing, and then suppresses the resulting storm by flipping existence bits. Every threshold on the ladder is a cap/cooldown-class remedy for the absence of pacing (workaround signature per CLAUDE.md bar).

### State surface

Failure state lives in ≥6 stores / 10 representations (registry counter·reason·error·livelock, FSM conditions, disk `paused`/`latched_reason`/`last_blocker`, circuit breaker, binding-health cooldown, heartbeat-local ref) with no transaction. Confirmed live crack: CAS merge preserves disk `paused=true` only for `Operator_paused` (`keeper_meta_merge.ml:40`) — auto-pauses (including `Manual_resume_required` ones) can be silently erased by a stale competing writer. Phase 3.5 auto-resume does not reset counters while reconcile-gate resume does (asymmetry).

### Dead judgment residue

`normalized_runtime_id` (`keeper_error_classify.ml:543-560`) is three ORs of the *same* expression plus a re-trim — the whole function is `String.trim`; its catalog check is dead. Candidate slot 2 and 3 (`default_runtime`, `phase_recovery_runtime`) are the same value by definition (`keeper_config.ml:21-24`), so the "3-slot" assembly is a 2-slot. `health_cooldown_fail_open`'s selection-time mechanism has zero callers. Four decisive branches are string matches: TLS substring (`keeper_error_classify.ml:39`), provider-timeout prefix (`keeper_provider_runtime_boundary.ml:65`), `"(budget="` substring (`keeper_oas_timeout_message.ml:7`), supervisor `| _ -> Exception (Printexc.to_string exn)` catch-all (`keeper_supervisor_launch.ml:300`).

## Design

### 1. Typed pacing state (the only failure output)

```ocaml
(* lib/keeper/keeper_pacing.mli — new SSOT *)
type revisit =
  { eligible_at : float          (* monotonic; provider retry_after wins over computed backoff *)
  ; cause : Failure_cause.t      (* typed, closed; no strings *)
  ; consecutive : int            (* observability only — never compared to a threshold *)
  }

type t =
  { per_runtime : (Runtime_id.t * revisit) list  (* absent entry = eligible now *)
  ; floor : float option                          (* provider-class rate floor, config *)
  }

val next_turn_due : t -> catalog:Runtime_id.t list -> float
(* = min eligible_at over catalog; the keeper always has a next turn. *)
val on_failure : t -> runtime:Runtime_id.t -> cause:Failure_cause.t
  -> retry_after:float option -> now:float -> t
(* exponential per-runtime widening, capped by config; retry_after overrides. *)
val on_success : t -> runtime:Runtime_id.t -> t   (* clears that runtime's revisit *)
```

Semantics: the keeper cycles forever. Each failing runtime's revisit interval widens (honoring the provider's `retry_after` — the field the 07-06 storm ignored); the keeper's next turn is due when the *earliest* runtime becomes eligible, starting from the configured base runtime. All runtimes far out ⇒ the keeper sleeps until the earliest one — visibly, as pacing, not as a `Paused` FSM state. No terminal state exists in the type.

### 2. Routing total over error classes — `None` is abolished

Every `sdk_error` maps to exactly one typed route (exhaustive match, no catch-all):

| Route | Classes (examples) | Effect |
|---|---|---|
| `Retry_after_pacing` | transient network, timeout, 5xx, backpressure, quota (with pool filter) | widen that runtime's revisit, continue on next eligible |
| `Rotate_now` | provider-bound errors with untried candidates | same turn, next candidate (today's behavior, kept) |
| `Escalate_judgment` | deterministic: config mismatch, schema/contract violation, `Mcp` protocol errors, catalog illegal-state (oas#2482 class) | **keeper keeps running**; the failure becomes a typed stimulus for an LLM-boundary verdict (keeper's own next turn receives it as input; supervisor LLM or HITL for mutating ambiguity). Retrying a deterministic error is never a route. |

This removes the `None` family (`keeper_error_classify.ml:524-551`) and the cycle-cap matrix — backpressure no longer needs a cap because pacing spaces revisits; quota keeps only the credential-pool filter (fact-based, not judgment).

### 3. Counters demoted to aggregation

`turn_failures`, restart counts, streak lengths remain as OTel metrics and dashboard signals (same policy as Budget/Cost/Turn: aggregate, never actuate). Thresholds `turn_fail_streak_threshold`, `MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES`, `max_restarts→DEAD` are deleted, not tuned.

### 4. Existence axes, made explicit

- **Operator intent**: `Registered | Operator_paused | Shutdown` — the only pause that survives. HITL continue-gate for ambiguous partial commits stays (it is operator intent acquisition, and already the one correct boundary).
- **Process reality**: fiber dead → supervisor relaunches, always (no restart budget, no DEAD). Relaunch itself is paced by the same revisit mechanism keyed on the crash cause, so a crash-looping keeper widens its relaunch interval instead of dying permanently. Stale-fiber kill (watchdog) is process repair and remains.
- Deleted states: failure-driven `Paused`, `Dead`-by-budget, dead_ttl tombstone reaping of auto-paused meta (`paused prune` deleting Manual-paused keeper meta files after 1 day is abolished with the state itself).

### 5. State SSOT

One record (pacing + operator intent) replaces `paused`/`latched_reason`/`last_blocker` triple-writes and the registry duplicates. The `keeper_meta_merge.ml:40` CAS erasure bug dissolves structurally: pacing is per-runtime monotone (merge = max eligible_at), operator intent is single-writer.

### 6. Boundary cleanups carried along

- Provider-timeout prefix parse → consume OAS typed error (MASC→OAS direction is allowed; the string round-trip is the violation).
- TLS substring, `"(budget="` substring → typed variants at the same boundaries.
- Supervisor catch-all keeps `Printexc` **capture** for logging but routes policy through a typed `Unclassified_exception` constructor, so new exception kinds fail loudly in review, not silently into "generic restart".
- Delete `normalized_runtime_id` (≡ `String.trim`), the duplicate candidate slot, and callerless `health_cooldown_fail_open` selection-time code.

## What this does NOT change

- Operator pause/resume UX and semantics.
- HITL approval queue, ambiguous-partial-commit gate, credential/risk gating (RFC-0309 family).
- Return-to-base routing (already correct).
- #23456 cause preservation (its typed causes feed `Failure_cause.t`).
- Lane-per-keeper admission; task lease TTLs (long-paced keepers release tasks via the *existing* lease machinery — no new mechanism).

## Objections considered

1. **"Infinite loops burn paid-provider money."** Deterministic errors are the expensive repeaters (oas#2482: 245 identical raises), and they get `Escalate_judgment`, not retry. Transients pay per-runtime widening backoff with a config `floor` per provider class. The 07-06 storm cost came precisely from *ignoring* `retry_after` — pacing makes it load-bearing.
2. **"Without DEAD, a broken keeper spams forever."** A keeper whose every runtime fails deterministically converges to: all failures escalated for judgment, pacing intervals at cap, near-zero spend. That is strictly less noise than today's crash-restart×5 storm followed by permanent DEAD that a human must notice.
3. **"Thresholds are simple; LLM judgment is expensive."** Judgment is invoked only on deterministic-failure stimuli (rare, and each one is actionable), not per turn. The thresholds were not simple in practice: three of them interact to produce #23439's evidence-reset loop, and the audit found the interaction surface (6 stores) is where the bugs live.

## Migration (each wave = one PR, CI-green, behind the previous)

- **W0** — this RFC + TLA+ spec `KeeperPacing.tla`: invariant `NoFailureDrivenExistenceChange` + bug-model action (`FailureSetsPaused`) with clean/buggy cfg pair (house pattern); replay fixture built from the 07-06 storm log window.
- **W1** — `keeper_pacing` module + shadow writes (observe-only: pacing computed and logged next to existing behavior; dashboard shows it). No behavior change.
- **W2** — total routing: kill `None` rotation classes, add `Escalate_judgment` typed stimulus channel; per-runtime revisit honors `retry_after`. Cycle-cap matrix deleted in the same PR (pacing replaces it).
- **W3** — flip: the six in-turn pause paths and both supervisor auto arms write pacing instead of `paused=true`. Manual-resume classes (idle, contract-attention) become `Escalate_judgment` stimuli. Storm replay fixture must show bounded retry rate.
- **W4** — purge: streak/crash/restart-budget thresholds, DEAD-by-budget, dead_ttl/prune of auto-paused, `[pause]` knobs; supervisor relaunch always-on with paced relaunch.
- **W5** — state SSOT consolidation + boundary cleanups (§6), CAS merge simplification, vestige deletion.

Rollback per wave: W1-W2 are additive; W3 is the behavior flip and carries a config kill-switch for one release (`pacing_mode = shadow | enforce`) — the switch itself is removed in W4 (temporary by construction, removal target stated here per workaround bar).

## Verification

- TLA+ clean cfg: no error; buggy cfg (existence-change action enabled): invariant violation — both must hold for the spec to count.
- Storm replay harness: feed the 07-06 log window through the W3 build; assert (a) zero `paused=true` writes from failure paths, (b) per-keeper rotation rate ≤ pacing bound, (c) `retry_after` respected within tolerance.
- Live metrics after W3: failure-driven pause events = 0 (counter must exist and stay zero), rotation retries/hour bounded, provider 429/`capacity` rates not worse than pre-W3 baseline.
