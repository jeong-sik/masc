---
rfc: "0102"
title: "Pre-turn runtime availability gate — reuse, not new surface"
status: Superseded
created: 2026-05-17
updated: 2026-07-11
author: vincent
supersedes: []
superseded_by: "0206"
related: ["0009", "0012", "0022", "0042", "0072", "0088", "0206", "0207"]
implementation_prs: [15814]
---

# RFC-0102 — Pre-turn runtime availability gate

> **Superseded (2026-07-11):** RFC-0206 replaced the legacy health-filtered
> candidate fail-open decision point with the typed `Runtime` boundary. RFC-0207
> subsequently introduced per-Keeper ordered runtime lanes, whose candidates are
> resolved by `Keeper_turn_driver` and checked per attempt by
> `Keeper_turn_driver_provider_attempt`. It did not restore the helper removed in
> PR #24186. The design and examples below describe the historical RFC-0102
> implementation, not the current dispatch path.

- Related RFCs (layer hand-offs):
  - **RFC-0009** Runtime Trust Phase 2 — *pre-attempt ordering*
  - **This RFC** — *pre-turn gate*, reuse of existing health snapshot
  - **RFC-0022** Runtime Attempt Liveness — *in-attempt*
  - **RFC-0012** Mid-Turn Progress Probe — *cross-attempt at turn level*
- Related typed-surface foundations:
  - **RFC-0042** typed terminal codes — `Failure_runtime_unavailable`, `No_providers_available`
  - **RFC-0072** keeper sub-FSM transitions typed — extends Phase_gating decision arms
  - **RFC-0088** Counter-as-Fix / N-of-M umbrella — §6 self-check

## 0. TL;DR

This RFC closes the gap between RFC-0009 (pre-attempt ordering) and
RFC-0022 (in-attempt liveness) with a fourth *pre-turn* layer in the
runtime-failure matrix.

The fix introduces **no new types, no new reason codes, no new
broadcast paths, no new API surface**. Every typed atom needed already
exists; the change is (a) a shared helper extracted from an existing
call site and (b) a case-split in an existing fail-open policy.

> **Drafting note (2026-05-17, same-day amend):** an earlier draft of
> this RFC proposed four new surfaces (`cached_availability` API, new
> `availability` type, new `runtime_unavailable:*` reason codes, a
> "new" `Phase_gating → Done(Skipped)` FSM arm). A reviewer pass found
> that each of those already exists as a typed surface in the codebase.
> Per RFC-0088 §"N-of-M patch" the duplicate-surface draft was rejected
> by this RFC's own self-check; this revision documents the reuse plan
> instead. The earlier draft is preserved only in this PR's git
> history as a counter-example.

## 1. Existing typed surfaces this RFC reuses (no new code paths)

| Concern | Existing typed surface | Location |
|---|---|---|
| FSM failure variant for runtime-unavailable terminal | `Keeper_turn_fsm.Failure_runtime_unavailable of { base; resolved }` (label `"runtime_unavailable"`) | `lib/keeper/keeper_turn_fsm.ml:8`, transition arm at `:222` |
| Typed reason for "no providers" terminal | `Keeper_types.No_providers_available` (display + json + display message) | `lib/keeper/keeper_meta_contract.ml:85,190,205,214` |
| `terminal_reason_code` mapping for the typed reason | `"runtime_exhausted_no_providers_available"` | `lib/keeper/keeper_unified_turn_types.ml:107` |
| Typed health rejection | `Runtime_health_filter.health_filter_rejection = All_missing_api_key of int \| All_local_unhealthy of {local_count; cloud_count}` | `lib/runtime/runtime_health_filter.mli:17` |
| Strict provider filter (returns rejection) | `Runtime_health_filter.filter_healthy_strict` | `lib/runtime/runtime_health_filter.mli:64` |
| Per-provider cooldown read | `Runtime_health_tracker.is_in_cooldown : t -> provider_key:string -> bool` | `lib/runtime/runtime_health_tracker.mli:276` |
| `Phase_gating → Done(Skipped)` emission template (with `record_pre_dispatch_terminal_observation` + `Trajectory.Gated`) | already in 4 arms (`supervisor_stop`, `non_executable_phase`, etc.) | `lib/keeper/keeper_unified_turn.ml:155,164,195,204,235,415,466,479` |
| Runtime-recovery probe (already in production) | `runtime_recovered` closure using named-provider runtime resolution + `Runtime_health_filter.filter_healthy_strict` | `lib/keeper/keeper_stale_watchdog.ml:749-770` |
| Historical fail-open policy site (removed by RFC-0206 / PR #24186) | pre-filter candidate fallback + `health_cooldown_fail_open` | archived RFC-0102 implementation |

The watchdog and the (to-be-added) phase_gating gate need the **same**
logical question — *is this runtime currently capable of producing any
healthy candidate?* — answered the same way. That answer already lives
inside `keeper_stale_watchdog.ml:749-770` as an anonymous closure.

## 2. Layer separation

Extends the RFC-0022 §1 matrix:

| Layer | RFC | State source | Decision input | Kill class | Effect |
|---|---|---|---|---|---|
| **Pre-turn (this RFC)** | **0102** | `current_availability` helper (extracted from watchdog) | typed rejection from `filter_healthy_strict` | reuses `No_providers_available` | turn is *not started*; FSM `Phase_gating → Done(Skipped)` |
| Pre-attempt | 0009 | `trust_score` aggregate | reputation over time | provider demoted | next call sees better order |
| In-attempt | 0022 | per-attempt liveness clock | absence of streaming chunks | `Attempt_*` | this attempt fails |
| Cross-attempt | 0012 | `turn_observation.last_progress_at` | absence of `oas:event` | `Mid_turn_no_progress` | watchdog kills turn |

### Invariants

**L0-A (no new typed atom):** every emission this RFC produces uses an
existing variant (`No_providers_available`) or an existing template
(`Trajectory.Gated`, `record_pre_dispatch_terminal_observation` with
`outcome:`Skipped`).

**L0-B (no double signal):** Phase_gating's gated arm must **not**
emit `operator_broadcast_required`. The cached
`runtime_health.unavailable_total` counter is already the operator
signal; the disposition stays `Skipped`, which already maps to
`Disp_skipped` (`keeper_execution_receipt.mli:232`) and is *not* in
`needs_operator_broadcast`.

**L0-C (single source of truth for `current_availability`):** after
this RFC, the watchdog (`keeper_stale_watchdog.ml:749-770`) and
Phase_gating both call the same extracted helper. The pre-existing
anonymous closure is replaced by a named function in
`lib/runtime/runtime_health_filter.ml` so both call sites see the same
typed rejection.

## 3. Problem statement (observed 2026-05-17)

Per keeper, per keepalive turn:

```
[fsm:transition] idle -> phase_gating action=StartTurn
[fsm:transition] phase_gating -> runtime_routing action=PhaseGateOk
operator_broadcast_required emitted disposition=pause_human reason=internal_error
[fsm:transition] runtime_routing -> failed:provider_error action=GenericFail
```

7 keepers × ~1 turn/min for an entire incident window. Underlying
cause is operational (runtime runtime misroute + missing API keys —
memory `project_runtime_misroute_2026_05_17.md`); the
*FSM-side amplification* is that the turn starts an attempt that fails
within milliseconds and trips a per-turn `pause_human` broadcast each
time. The information (one runtime outage) is correct; the cadence
(N · turns/min broadcasts) is wrong.

### Why the current path produces this

`keeper_turn_driver.ml:325-345` chooses fail-open:

```
all tool-capable candidates are in health/cooldown;
fail-open to surface provider result instead of no_providers_available
```

That policy treats `All_local_unhealthy` (transient — local endpoints
may recover within the cooldown window) and `All_missing_api_key`
(configurationally broken — no recovery without operator action) as
the same case. Surfacing the provider result is reasonable for the
transient case and pointless for the broken-config case.

## 4. Proposed change

### 4.1 Extract `current_availability` helper (no new logic)

Move the existing closure body from `keeper_stale_watchdog.ml:749-770`
into:

```ocaml
(* lib/runtime/runtime_health_filter.ml *)
val current_availability :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  runtime_id:Runtime_name.t ->
  ( unit, health_filter_rejection ) result
```

— signature, body, and error variants are *exactly* what the watchdog
closure already does. No behaviour change for the watchdog; its
anonymous closure is replaced by `Runtime_health_filter.current_availability`.

Implementation note: this is **not** a probe-free cached read in the
first iteration — it preserves the watchdog's existing semantics
(active resolve + strict filter). A cached variant is a follow-up
*if and only if* per-turn invocation cost proves measurable (see §8 Q3).

### 4.2 Historical case-split policy (superseded)

The original implementation replaced its boolean fail-open decision with a
typed dispatch. This is retained as historical rationale only; the current
runtime-lane path uses the typed boundaries named in the supersession note.

```
match rejection_or_ok with
| Ok healthy -> healthy
| Error (All_local_unhealthy _) ->
  (* unchanged: fail-open, surface provider result *)
  retry the pre-filter candidates
| Error (All_missing_api_key _) ->
  (* new: fail-closed, return No_providers_available directly *)
  ... raise No_providers_available
```

`All_missing_api_key` already returns `No_providers_available` upstream
via `keeper_meta_contract.ml`. The change is which rejection variants
the fail-open path *applies to*.

### 4.3 Phase_gating short-circuit (reuses existing arm template)

In `keeper_unified_turn.ml` between the `non_executable_phase` arm and
the `Runtime_routing` emission (around line 256–277), add an arm that
is a **structural copy** of the existing `non_executable_phase` arm
(line 175–211), with a different `decision` payload and the same
`Trajectory.Gated` + `record_pre_dispatch_terminal_observation`
sequence:

- consult `Runtime_health_filter.current_availability`
- on `Error rejection` → emit `Phase_gating → Done` (Skipped),
  `terminal_reason_code = "runtime_exhausted_no_providers_available"`
  (SSOT: `keeper_unified_turn_types.ml:107`)
- on `Ok ()` → emit `Phase_gating → Runtime_routing` (unchanged)

No new helper is introduced; the existing template is the contract.

## 5. What this RFC does **not** add

- ❌ No new typed variant (FSM, terminal_reason_code, disposition)
- ❌ No new API beyond renaming a watchdog-local closure into a public
  function (same signature, same body)
- ❌ No new operator broadcast path
- ❌ No new counter (the existing `runtime_health.*` family is enough)
- ❌ No feature flag (monotone change once §4.2 is justified per
  rejection variant)
- ❌ No `[fsm:transition]` log-level demotion or string dedup

## 6. Anti-pattern self-check (RFC-0088 umbrella)

| Signature | Check |
|---|---|
| **Counter-as-Fix / Telemetry-as-fix** | ✅ No new counter; existing `runtime_health.*` is the operator signal. |
| **String/substring classifier** | ✅ All decisions are over closed typed sums (`health_filter_rejection`, `failure_reason`, `Keeper_types.terminal_reason`). |
| **N-of-M patch** | ✅ **first-draft self-violation removed in same-day amend** (this draft). The single emission site `Phase_gating → Runtime_routing` in `keeper_unified_turn.ml` is the only one this RFC modifies; the watchdog call site is migrated in the same PR so both sites end up on the same extracted helper. |
| **Cap/cooldown/dedup/repair** | ✅ Pre-condition check, not a cap. Cooldown semantics live in `Runtime_health_tracker` and are unchanged. |
| **Test backdoor** | ✅ No `set_*_for_test`/`reset_*_for_test`. |
| **Symptom suppression** | ✅ WARN flood is removed *by removing the duplicative routing*, not by demoting the WARN level. The WARN remains at full volume for any other failure class. |
| **Hardcoded reason code** | ✅ `"runtime_exhausted_no_providers_available"` is read from the SSOT location `lib/keeper/keeper_unified_turn_types.ml:107`, not duplicated. |

## 7. Test plan

| Surface | Test |
|---|---|
| `Runtime_health_filter.current_availability` (extracted helper) | extraction unit test: identical inputs as the watchdog closure produce identical outputs (regression — *behaviour must not drift*). |
| Watchdog call site | existing `keeper_stale_watchdog` tests stay green after the closure → named-function swap. |
| FSM emit | `test_keeper_turn_fsm_emit.ml` adds a case: `runtime_unavailable` Phase_gating arm reaches `Done` without traversing `Runtime_routing`. |
| Joint invariant | TLA+ `KeeperCompositeLifecycle` observer (RFC-0072): when `current_availability = Error _`, the trace from any executable phase entry reaches `Done(Skipped)`. |
| Operator broadcast regression | `Runtime_unavailable` over M=10 turns produces zero `operator_broadcast_required` activity events. |
| Fail-open case split | `All_missing_api_key` → `No_providers_available` (fail-closed). `All_local_unhealthy` → fail-open path stays. |
| Recovery | `Runtime_health_tracker` flip → next turn reaches `Runtime_routing` without operator intervention. |

## 8. Open questions

- **Q1** — should the Phase_gating gate apply during operator-initiated
  turns (board-reactive, manual)? Default: yes (faster typed error
  beats slow routing fail). Confirm in PR review.
- **Q2** — `All_local_unhealthy` with non-empty cloud fallback: is
  fail-open still correct? Currently yes (cloud may still answer).
  Confirm in PR-1.
- **Q3** — first iteration uses an *active* probe (preserves watchdog
  semantics). Per-turn cost has not been measured. If profiling shows
  measurable overhead, a second iteration adds a cached variant —
  but only after evidence, not preemptively (RFC-0088 §"defer until
  warranted").

## 9. Out of scope

- Operational fix for the current incident (runtime misroute, missing
  keys) — that is config and operator action, not architecture.
- `[fsm:transition]` log-volume reduction — once this RFC ships, the
  remaining transitions per turn drop from 3 to 1 in the unavailable
  case and from 4 to 4 (unchanged) in the healthy case. The remaining
  one-per-turn lines are not flood. A separate RFC may revisit *only
  if* this RFC ships and the noise persists.
