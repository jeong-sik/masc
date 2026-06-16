# RFC-0250: Stale-run window — give the closed `Idle_turn` variant its first producer

## §0 Summary

At default config, a keeper whose run has frozen silently is indistinguishable from a
long-running one: it triggers no restart, stamps no failure reason, and the supervisor's
cohort sweep leaves it alone. The machinery to address this is **half-built but unwired**:

- The closed-sum variant `stale_kill_class = … | Idle_turn of { stall_seconds : float }`
  (`keeper_registry_types_kill_class.ml`) exists and is consumed by 4 sites (terminal-code
  mapping, status bridge, execution-receipt label, supervisor cohort key) — but **no
  detector ever produces it**. Its only construction site passes a placeholder
  `{ stall_seconds = 0.0 }` as a cohort key (`keeper_supervisor_types.ml`).
- `Keeper_execution_receipt.emit_stale_keeper_broadcast` (`keeper_execution_receipt.ml:790`,
  exposed in `.mli:317`) emits a `keeper.operator_broadcast_required` event with actor
  `{kind="watchdog"}` — but has **zero call sites** repo-wide. Its own sibling comment
  (`keeper_execution_receipt.ml:518`) states the "StaleRunning watchdog +
  emit_stale_keeper_broadcast is deferred to a separate cycle."
- The only wall-clock detector that exists, `MASC_KEEPER_MAX_TURN_WATCHDOG_TIMEOUT_SEC`
  (RFC-0125 P4, `env_config_runtime.ml:412-420`), is **opt-in** (`default:0.0 → None` =
  disabled) and — by its own comment — detects *in-turn* no-progress (`In_turn_hung`),
  not the *no-turn-produced* case `Idle_turn` names.

This RFC completes the wiring: the supervisor cohort sweep's `None -> () (* Alive — skip *)`
branch (`keeper_supervisor.ml:255-256`) gains a wall-clock check on `last_turn_ts`; when a
running keeper has not completed a turn in `stale_run_threshold_sec`, it stamps
`Stale_turn_timeout (Idle_turn { stall_seconds })` — giving the named-but-producerless
variant its first real producer — and invokes the dead `emit_stale_keeper_broadcast` so the
silent stall becomes an addressable operator event. The existing `watchdog_triggered`
branch then routes it to crash recovery exactly as `In_turn_hung` does today.

This is a **wiring RFC**, not a new classifier: no new type, no string match, no cap. It
closes the gap by completing a deliberately-deferred cycle using the closed sum already on
disk.

## §1 Motivation (falsified on `origin/main` 165b10a30)

Five load-bearing claims were verified directly against current main (re-falsified after
the prior round on `6ac33d752`; the single intervening commit `165b10a30` is dashboard-only
and touches none of these files):

1. **`emit_stale_keeper_broadcast` has zero callers.** `rg -rn emit_stale_keeper_broadcast
   lib/ test/ scripts/ dashboard/` returns only the `.mli val`, the `.ml let`, and the
   "deferred" comment. No invocation anywhere.
2. **`Idle_turn` is producerless.** Every site that matches it is a consumer
   (`| Idle_turn of { stall_seconds } -> …`, bridge blocker, terminal code) except
   `keeper_supervisor_types.ml`'s `{ stall_seconds = 0.0 }` cohort-key placeholder. No
   detector sets a real `stall_seconds`.
3. **The supervisor treats a frozen run as Alive.** `keeper_supervisor.ml:255-256`:
   `| None when watchdog_stop_pending entry -> force_unresolved_watchdog_crash entry |
    None -> () (* Alive — skip *)`. A running entry whose `done_p` is unset and carries no
   `failure_reason` is skipped — exactly the silent-stall case.
4. **The wall-clock watchdog is disabled at default.** `env_config_runtime.ml:417`:
   `get_float ~default:0.0 …; if v > 0.0 then Some v else None`. Its own comment concedes it
   "only detects in-turn no-progress, not stuck too long."
5. **A frozen fiber never advances `last_turn_ts`.** `keeper_registry.ml:156`:
   `if had_live_turn then … usage = { … with last_turn_ts = now }`. `last_turn_ts` advances
   only when a turn *completes*; a run frozen mid-turn leaves it stuck, so it is a faithful
   "no turn produced in N seconds" signal.

Net: the per-turn wall-clock watchdog was **deliberately removed**
(`keeper_unified_turn_attempt_watchdog.mli`: "MASC must not impose a wall-clock timeout
around the whole provider/tool run … `attempt_watchdog_s` intentionally ignored") so that
legitimate long tool runs survive. That removal left no detector for the *keeper-level*
"alive but producing no turns" case — the half-built `Idle_turn` + `emit_stale_keeper_broadcast`
pair was the intended replacement and was never wired.

The gap is the documented `#fleet-stall` bug class (`keeper_execution_receipt.ml:516-517`).

## §2 Design

### 2.1 Wall-clock check in the cohort sweep

In `keeper_supervisor.ml`, the cohort sweep's `None -> () (* Alive — skip *)` arm gains a
guarded sub-check. Pseudocode (the closed sum is reused verbatim — `Idle_turn`, not a string):

```ocaml
| None ->
  (* RFC-0250: stale-run window. A running keeper that has not completed a
     turn in [stale_run_threshold_sec] is frozen-but-silent, not alive. Give
     the closed [Idle_turn] variant its first producer and broadcast, so the
     existing watchdog_triggered branch routes it to crash recovery. *)
  (match entry.phase with
   | Keeper_state_machine.Running
     when entry.meta.runtime.usage.last_turn_ts > 0.0 ->
     let stall = now -. entry.meta.runtime.usage.last_turn_ts in
     if stall > stale_run_threshold_sec then begin
       let reason =
         Keeper_registry.Stale_turn_timeout
           (Keeper_registry_types.Idle_turn { stall_seconds = stall })
       in
       Keeper_registry.set_failure_reason ~base_path entry.name (Some reason);
       Keeper_execution_receipt.emit_stale_keeper_broadcast
         config
         ~keeper_name:entry.name
         ~agent_name:entry.meta.agent_name
         ~runtime_id:entry.meta.runtime_id
         ~trace_id:entry.meta.trace_id
         ~generation:entry.meta.generation
         ~failure_reason:reason
         ~stale_seconds:stall
         ~last_turn_ts:entry.meta.runtime.usage.last_turn_ts
     end
   | _ -> ())
```

After `set_failure_reason`, the entry carries `Stale_turn_timeout (Idle_turn …)`. On the
next sweep the `watchdog_stop_pending` predicate (already true for `Stale_turn_timeout`)
routes it through `force_unresolved_watchdog_crash` → `sweep_and_recover` → restart, exactly
as `In_turn_hung` does. The exact field paths (`entry.meta.runtime.usage.last_turn_ts`,
`agent_name`, `runtime_id`, `trace_id`, `generation`) are confirmed at implementation time
against the `registry_entry` record; the design intent is "the fields the broadcast already
expects."

### 2.2 Threshold: a distinct default-on env, not the in-turn watchdog

`stale_run_threshold_sec` is read from a **new** env `MASC_KEEPER_STALE_RUN_SEC`, default-on
at `1800.0` (30 min). Rationale for a separate knob rather than promoting the max-turn
watchdog to default-on:

- **Different case, different variant.** The max-turn watchdog produces `In_turn_hung`
  (a single turn is taking too long); stale-run produces `Idle_turn` (no turn has completed
  at all). Conflating them would force a single threshold to serve both "a long tool call"
  and "the keeper is wedged," reproducing the per-turn-timeout regression the deliberate
  removal was meant to prevent.
- **Key on `last_turn_ts`, never on active-tool duration.** This is the invariant the
  removed per-turn watchdog violated; the stale-run window respects it by construction.

The threshold is colocated with the display-only `agent_staleness_threshold_s` (`120.0`,
`keeper_status_runtime.ml:13`) with a comment relating the two: the display threshold says
"this keeper looks old"; the enforcement threshold says "this keeper is producing no turns
and is presumed dead." Keeping them as named constants in the same area prevents the
enforcement/display drift that undetectable silent stalls would otherwise reintroduce.

`Env_config_runtime` gains a `Keeper_stale_run` module mirroring `Keeper_max_turn_watchdog`,
but with a positive default (`get_float ~default:1800.0 …`).

### 2.3 What this RFC does NOT add

- No new type — `Idle_turn` and `Stale_turn_timeout` already exist.
- No string classifier — the failure reason is a closed sum.
- No per-turn wall-clock timeout — the removed `attempt_watchdog_s` stays ignored.
- No cap / cooldown / dedup — stamping an already-stamped reason is idempotent
  (`set_failure_reason` overwrites; the next sweep routes to recovery). The
  `watchdog_stop_pending` + restart-budget machinery already governs restart pacing.

## §3 Verification

- **Producer exists:** `rg Idle_turn lib/` shows a construction with a non-placeholder
  `stall_seconds` (the supervisor sweep), not only consumers.
- **Emitter wired:** `rg emit_stale_keeper_broadcast lib/` shows ≥ 1 call site in addition
  to the definition.
- **Behavioral test:** a registry fixture with `phase = Running`, `last_turn_ts` set
  `stale_run_threshold_sec + ε` in the past, and no `failure_reason` — running the cohort
  sweep stamps `Stale_turn_timeout (Idle_turn { stall_seconds })` and emits the broadcast.
  A fresh `last_turn_ts` (within threshold) leaves the entry Alive. (Use the test clock; no
  `Unix.time` — see coding rules.)
- `dune build --root .` + `@check`: exit 0 (the new code touches the hot path, so the
  default target must also build — `feedback_dune_check_misses_expr_type_errors`).
- ocamlformat `@fmt`: clean.
- Relevant `dune runtest` (keeper supervisor / registry / execution-receipt suites).

## §4 Non-goals

- Reintroducing the per-turn wall-clock watchdog (`keeper_unified_turn_attempt_watchdog`).
  Long tool runs must survive; the stale-run window keys on `last_turn_ts`, not tool
  duration.
- Changing the max-turn watchdog's opt-in policy — it remains a separate, opt-in detector
  for the `In_turn_hung` case.
- Unbounded operator broadcast flooding — governed by the existing restart-budget /
  cohort-recovery machinery, not a new rate limiter.
