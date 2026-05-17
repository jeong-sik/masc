---
rfc: "0102"
title: "Pre-turn cascade availability gate"
status: Draft
created: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0009", "0012", "0022", "0072", "0088"]
implementation_prs: []
---

# RFC-0102 — Pre-turn cascade availability gate

- Related RFCs (layer hand-offs):
  - **RFC-0009** Cascade Trust Phase 2 — *pre-attempt ordering*, trust score aggregate
  - **This RFC** — *pre-turn gate*, cached health snapshot
  - **RFC-0022** Cascade Attempt Liveness — *in-attempt*, streaming liveness
  - **RFC-0012** Mid-Turn Progress Probe — *cross-attempt at turn level*
- Related anti-pattern frames:
  - **RFC-0088** Counter-as-Fix umbrella — §6 self-check below
  - **RFC-0072** keeper sub-FSM transitions typed — extends Phase_gating decision arms

## 0. TL;DR

Keepalive turns enter `Cascade_routing` even when every cascade provider
is in cooldown (`cascade_health_tracker`) or has been pruned from the
healthy set (`cascade_health_filter`). The attempt then immediately
fails with `provider_error`, which trips
`operator_broadcast_required` (disposition `pause_human`, reason
`internal_error`). For a fleet of *N* keepers with no healthy providers,
this produces *N · turns_per_minute* WARN broadcasts that the operator
cannot act on at the per-turn granularity. The signal is real (providers
are down) but the *cadence* (one broadcast per keeper per turn) is wrong.

This RFC closes the gap between RFC-0009 (pre-attempt ordering) and
RFC-0022 (in-attempt liveness) by adding a **pre-turn gate**: before
`Phase_gating → Cascade_routing`, consult the cached cascade health
snapshot. If no provider is currently available, transition to
`Phase_gating → Done` with `outcome=Skipped`,
`terminal_reason_code=cascade_unavailable`. No broadcast. The fleet
recovers to a single dashboard counter (`cascade_health.unavailable_total`)
plus the existing per-provider trust state.

## 1. Layer separation (mandatory)

Extends the RFC-0022 §1 matrix with a fourth row above the existing three:

| Layer | RFC | State source | Decision input | Kill class | Effect |
|---|---|---|---|---|---|
| **Pre-turn (this RFC)** | **0102** | `Cascade_health_tracker.snapshot` (cached) | absence of any healthy provider at turn entry | `Cascade_unavailable` | turn is *not started*; FSM `Phase_gating → Done(Skipped)` |
| Pre-attempt (ordering) | 0009 | `trust_score` aggregate | reputation over time | provider demoted in order | next call sees better order |
| In-attempt | 0022 | per-attempt liveness clock | absence of streaming chunks | `Attempt_*` | this attempt fails, FSM advances to next slot |
| Cross-attempt | 0012 | `turn_observation.last_progress_at` | absence of `oas:event` across attempts | `Mid_turn_no_progress` | watchdog kills turn |

### Invariants (must not collide with RFC-0022 L1/L2)

**L0 (this RFC, monotonicity with L1):**
> `Phase_gating` reads the cached snapshot — it does **not** issue a
> probe. The cache is updated by RFC-0022's in-attempt path and
> RFC-0009's trust loop. L0 therefore cannot tighten L1's invariant; it
> can only short-circuit turns the cache *already* knows would fail.

**L0 (no double signal):**
> When L0 gates a turn out (`Cascade_unavailable`), it must **not**
> emit `operator_broadcast_required`. The operator-facing signal is
> the cached `cascade_health.unavailable_total` counter +
> `Cascade_health_tracker.last_change_at`, both of which already exist.

**Compatibility with RFC-0022 L1:** L0 reads the cache; L1's
chunk_clock writes the cache. The two clocks never race because L0
fires *before* L1 has a chance to start (no attempt yet).

## 2. Problem statement

### 2.1 Observed pattern (2026-05-17 dashboard daemon)

Per keeper, per keepalive turn (every 30–60s):

```
[fsm:transition] idle -> phase_gating action=StartTurn
[fsm:transition] phase_gating -> cascade_routing action=PhaseGateOk
operator_broadcast_required emitted disposition=pause_human reason=internal_error
[fsm:transition] cascade_routing -> failed:provider_error action=GenericFail
```

Across 7 keepers × ~1 turn/min = ~28 broadcasts/min sustained while every
provider in the live cascade is unhealthy. Root cause analysis points to
a known infra-side issue (cascade tier-group misroute + missing API keys,
memory: `project_cascade_tier_group_misroute_2026_05_17.md`,
`project_masc_system_log_audit_2026_05_16.md`). The infra issue is real;
the FSM nevertheless walks into routing every cycle and discovers the
same fact, broadcasting it each time.

### 2.2 Why existing layers do not close this

| Layer | Why it does not gate the entry |
|---|---|
| RFC-0009 (pre-attempt ordering) | Reorders providers within a *started* attempt. Empty healthy set still produces an attempt; the order is just degenerate. |
| RFC-0022 (in-attempt liveness) | Kills a live attempt that stopped streaming. Provides no signal *before* attempt start. |
| RFC-0012 (cross-attempt turn watchdog) | Kills a turn that produces no progress over its full budget. The current symptom kills the attempt in milliseconds — well under any cross-attempt timeout — so RFC-0012 never fires. |

The gap is "the cascade *might* be empty before we even start"; no
existing layer asks that question.

## 3. Proposed change

### 3.1 Insertion site

In `lib/keeper/keeper_unified_turn.ml`, the executable-phase arm of
`Phase_gating` (line ~256–277 at the time of writing) currently emits
`Phase_gating → Cascade_routing` unconditionally once
`Keeper_state_machine.can_execute_turn phase` returns `true`:

```ocaml
| phase_opt ->
  (* current code: append manifest, emit transition *)
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Phase_gating
    Keeper_turn_fsm.Cascade_routing;
  (* ... continue into cascade routing ... *)
```

The new gate fits *between* the executable-phase decision and the
transition emission:

```ocaml
| phase_opt ->
  (match Cascade_health_filter.cached_availability
           ~config ~cascade_name:(cascade_name_of_meta meta) with
   | Available ->
     (* unchanged path: emit Phase_gating → Cascade_routing *)
   | Unavailable { rejection; last_change_at } ->
     (* new gated path: emit Phase_gating → Done(Skipped) *)
     append_manifest ~site:"phase_gate_decided"
       ~status:"skipped"
       ~decision:
         (`Assoc
           [
             ("phase", ...);
             ("reason", `String "cascade_unavailable");
             ("rejection",
               `String (Cascade_health_filter.health_filter_rejection_to_string rejection));
             ("executable", `Bool false);
           ])
       Keeper_runtime_manifest.Phase_gate_decided;
     record_pre_dispatch_terminal_observation
       ~config ~meta ~generation
       ~outcome:`Skipped
       ~terminal_reason_code:"cascade_unavailable"
       ~activity_kind:"keeper.turn_skipped"
       ~trajectory_outcome:(Trajectory.Gated "cascade_unavailable")
       ~keeper_turn_id
       ();
     Keeper_turn_fsm.emit_transition
       ~keeper_name:meta.name
       ~turn_id:keeper_turn_id
       ~prev:Keeper_turn_fsm.Phase_gating
       Keeper_turn_fsm.Done;
     Ok meta)
```

### 3.2 New API (`Cascade_health_filter`)

The existing `filter_healthy_strict : sw:_ -> net:_ -> providers ->
(providers, health_filter_rejection) result` performs *active*
discovery and is therefore unsuitable for invocation on every keepalive
turn. Adding:

```ocaml
type availability =
  | Available
  | Unavailable of {
      rejection : health_filter_rejection;
      last_change_at : float; (* Unix epoch seconds *)
    }

val cached_availability :
  config:Coord.config -> cascade_name:Cascade_name.t -> availability
```

contract:

- pure read of `Cascade_health_tracker`'s already-mutex-guarded cached
  snapshot (window-based rolling state + cooldown clocks), plus the
  one-shot startup result of `filter_healthy_strict`;
- **never** issues an HTTP probe;
- never blocks longer than a single `Stdlib.Mutex.lock`/unlock;
- `last_change_at` is the latest provider-state-change timestamp so the
  dashboard can show `unavailable_for=<duration>` instead of just a
  boolean.

### 3.3 Transition table

| `cached_availability` result | Phase_gating arm | FSM transition | Outcome | Broadcast |
|---|---|---|---|---|
| `Available` | (unchanged) | `Phase_gating → Cascade_routing` | runs the existing attempt path | unchanged |
| `Unavailable { All_missing_api_key _ }` | new | `Phase_gating → Done` | `Skipped`, `terminal_reason_code=cascade_unavailable:missing_api_key` | **none** |
| `Unavailable { All_local_unhealthy _ }` | new | `Phase_gating → Done` | `Skipped`, `terminal_reason_code=cascade_unavailable:all_local_unhealthy` | **none** |

`terminal_reason_code` reuses the typed-terminal-code SSOT (RFC-0042).
New codes are added to the closed sum, not strings.

## 4. What this RFC explicitly does **not** do

- It does **not** silence operator broadcasts that the in-attempt path
  (RFC-0022) or the watchdog (RFC-0012) raise — those continue exactly
  as before.
- It does **not** change cascade selection ordering (RFC-0009 territory).
- It does **not** demote any existing `Log.Keeper.info/warn` calls.
  Telemetry per *transition* is preserved; the change is in the
  *number of transitions per turn* (from 3 to 1 in the unavailable case).
- It does **not** introduce a feature flag. The change is monotone (it
  can only *prevent* a turn that would have failed milliseconds later
  with the same operator-visible result), so flag-gating it would only
  preserve the broken path.

## 5. Test plan

| Surface | Test |
|---|---|
| `Cascade_health_filter.cached_availability` | unit: cached snapshot returns the last `filter_healthy_strict` rejection without issuing a probe (assert no `Eio.Net.connect` call). |
| FSM emit | `test_keeper_turn_fsm_emit.ml` adds `check_action F.GatedCascadeUnavailable ~from_state:F.Phase_gating ~to_state:F.Done`. |
| Joint invariant | TLA+ `KeeperCompositeLifecycle` observer (RFC-0072): assert that when `Cascade_health = empty`, the trace from any executable-phase entry reaches `Done(Skipped)` without traversing `Cascade_routing`. |
| Regression (operator broadcast) | new test under `test/test_keeper_execution_receipt_*.ml`: an unavailable cascade produces zero `operator_broadcast_required` activity events across `M=10` turns. |
| Idempotence | recovery test: when `Cascade_health_tracker` flips `Unavailable → Available`, the *next* turn reaches `Cascade_routing` without operator intervention. |

## 6. Anti-pattern self-check (RFC-0088 Counter-as-Fix umbrella)

| Signature | Check |
|---|---|
| **Counter-as-Fix / Telemetry-as-fix** | No new counter is introduced as a substitute for fixing data loss. Operator visibility is *not reduced*: the existing `cascade_health.unavailable_total` is already the operator-facing signal. The change *removes* duplicative per-turn broadcasts that did not carry independent information. |
| **String/substring classifier** | No new string match is added. `terminal_reason_code` extension uses the existing closed sum (RFC-0042). |
| **N-of-M patch** | The change is exhaustive within `Phase_gating`. There is exactly one `Phase_gating → Cascade_routing` emission site and this RFC modifies all of it. (Verified at insertion time by `rg 'Phase_gating[\s\S]*Cascade_routing' lib/keeper/`.) |
| **Cap/cooldown/dedup/repair** | The gate is not a cap or dedup. It is a state-based pre-condition that mirrors an existing typed rejection. The cache it reads is the same cache RFC-0009 has read since v0.137.0. |
| **Test backdoor** | No `set_*_for_test`/`reset_*_for_test` is added. |
| **Symptom suppression** | The symptom (`operator_broadcast_required` flood) is removed *as a side effect of fixing the underlying redundant routing*, not by demoting the WARN. The WARN remains at full volume for any *new* class of failure. |

## 7. Migration & rollout

- **Same PR**: `Cascade_health_filter.cached_availability` + Phase_gating
  arm + `terminal_reason_code` closed-sum extension + tests + TLA+
  invariant update.
- **No flag**: monotone change (cannot turn a successful turn into a
  failure).
- **Backwards-compat**: existing callers of `filter_healthy_strict` are
  unchanged; the new API is purely additive.
- **Observability hand-off**: dashboard panel
  `cascade_health.unavailable_total` already exists; this RFC adds
  `last_change_at` so the panel can show `unavailable_for=Xs`. Panel
  change is a separate small PR after the FSM change lands.

## 8. Open questions

- **Q1**: should the gate also apply during *non-keepalive* turns
  (operator-initiated, board-reactive)? Initial answer: yes — the same
  invariant holds and operator-initiated turns benefit from a fast
  typed error instead of a routing fail. To be confirmed in PR review.
- **Q2**: should we add a *grace window* (e.g., 5s after a recovery
  signal) before re-allowing turns, to avoid flapping? Initial answer:
  no — `Cascade_health_tracker` already implements cooldown semantics;
  layering a second timer would duplicate state.

## 9. Out of scope

- The underlying provider availability fix (missing API keys, tier-group
  misroute) is operational, not architectural. This RFC is the FSM-side
  hardening that prevents *any* future provider outage from producing
  the same WARN flood, not a fix for the current incident.
- The `[fsm:transition]` log-volume / stdout-vs-ledger split discussed
  in the originating session is deferred — once this RFC ships and the
  WARN flood is gone, the remaining `[fsm:transition]` INFO lines are
  one-per-turn (idle→phase_gating→done) and no longer constitute
  noise. A separate RFC may revisit if it does.
