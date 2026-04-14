(** Unit tests for the [Overflowed] phase + auto-compact recovery flow.

    Scenarios mirror the five cases in the MASC-1 plan:
    1. Happy path — Running → Overflowed → Compacting → Running
    2. Compact failed → retry latch promotes the next overflow to Paused
    3. Operator clear — Overflowed → Running without passing Compacting
    4. Two consecutive overflows in one fiber lifecycle
    5. Heartbeat failure while Overflowed is preserved through recovery *)

open Alcotest

module SM = Masc_mcp.Keeper_state_machine

(** Conditions for a healthy Running keeper. *)
let running_conds : SM.conditions =
  { SM.default_conditions with
    fiber_alive = true;
    heartbeat_healthy = true;
    turn_healthy = true;
    restart_budget_remaining = true;
  }

let overflow_event ?(tokens = 205_000) ?(limit = Some 200_000) () =
  SM.Context_overflow_detected
    { source = `Prompt_rejected;
      token_count = tokens;
      limit_tokens = limit }

let apply_ok phase conds ev =
  match SM.apply_event ~current_phase:phase ~conditions:conds ~event:ev
          ~now:0.0
  with
  | Ok tr -> tr
  | Error err ->
    failf
      "apply_event rejected: %s (phase=%s event=%s)"
      (SM.transition_error_to_string err)
      (SM.phase_to_string phase)
      (SM.event_to_string ev)

let check_phase expected actual msg =
  check string msg (SM.phase_to_string expected) (SM.phase_to_string actual)

(* ── Scenario 1: happy path ───────────────────────────────── *)

let test_happy_path () =
  (* Running → overflow detected *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  check_phase SM.Overflowed tr1.new_phase "overflow → Overflowed";
  check bool "context_overflow latched" true
    tr1.updated_conditions.context_overflow;
  (* Entry action requests compaction *)
  let has_start_compaction =
    List.exists (function SM.Start_compaction -> true | _ -> false)
      tr1.entry_actions
  in
  check bool "entry action includes Start_compaction" true has_start_compaction;
  (* Auto-compact fires → Compacting *)
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions SM.Auto_compact_triggered
  in
  check_phase SM.Compacting tr2.new_phase "auto-compact → Compacting";
  (* Compaction completes → Running (context_overflow cleared) *)
  let tr3 =
    apply_ok SM.Compacting tr2.updated_conditions
      (SM.Compaction_completed { before_tokens = 205_000; after_tokens = 80_000 })
  in
  check_phase SM.Running tr3.new_phase "compaction done → Running";
  check bool "context_overflow cleared" false
    tr3.updated_conditions.context_overflow;
  check bool "compact_retry_exhausted cleared" false
    tr3.updated_conditions.compact_retry_exhausted

(* ── Scenario 2: compact failure → retry latch → Paused ───── *)

let test_compact_failure_latches_paused () =
  (* Running → overflow → Overflowed *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  (* Auto-compact triggered → Compacting *)
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions SM.Auto_compact_triggered
  in
  (* Compaction fails — compaction_active cleared but context_overflow keeps *)
  let tr3 =
    apply_ok SM.Compacting tr2.updated_conditions
      (SM.Compaction_failed { reason = "oas_error" })
  in
  check_phase SM.Overflowed tr3.new_phase
    "compact failed, context still overflowed → Overflowed again";
  check bool "context_overflow still set" true
    tr3.updated_conditions.context_overflow;
  (* Caller (keeper_unified_turn retry loop) declares retry exhausted by
     overriding the conditions before issuing the next overflow event.
     We simulate that by flipping the latch manually. *)
  let exhausted_conds =
    { tr3.updated_conditions with compact_retry_exhausted = true }
  in
  (* Next DerivePhase must map this to Paused even though the overflow is
     still active — this is what breaks the Overflowed ↔ Compacting loop. *)
  check_phase SM.Paused (SM.derive_phase exhausted_conds)
    "retry exhausted + context_overflow → Paused"

(* ── Scenario 3: operator clear bypasses Compacting ───────── *)

let test_operator_clear_returns_to_running () =
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  check_phase SM.Overflowed tr1.new_phase "overflow → Overflowed";
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions
      (SM.Operator_clear_requested
         { preserve_system = true; reason = "manual test" })
  in
  check_phase SM.Running tr2.new_phase
    "operator clear drops context → Running";
  check bool "context_overflow cleared" false
    tr2.updated_conditions.context_overflow;
  check bool "compact_retry_exhausted cleared" false
    tr2.updated_conditions.compact_retry_exhausted;
  check bool "compaction_active not touched" false
    tr2.updated_conditions.compaction_active

(* ── Scenario 4: two consecutive overflows in one fiber ───── *)

let test_two_consecutive_overflows () =
  (* Run one full overflow/compact/running cycle. *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions SM.Auto_compact_triggered
  in
  let tr3 =
    apply_ok SM.Compacting tr2.updated_conditions
      (SM.Compaction_completed { before_tokens = 210_000; after_tokens = 90_000 })
  in
  check_phase SM.Running tr3.new_phase "cycle 1 back to Running";
  (* Second overflow should be handled cleanly — retry latch is reset by the
     successful Compaction_completed in cycle 1. *)
  let tr4 = apply_ok SM.Running tr3.updated_conditions (overflow_event ()) in
  check_phase SM.Overflowed tr4.new_phase "cycle 2 → Overflowed";
  check bool "retry latch still clear after successful cycle" false
    tr4.updated_conditions.compact_retry_exhausted;
  let tr5 =
    apply_ok SM.Overflowed tr4.updated_conditions SM.Auto_compact_triggered
  in
  check_phase SM.Compacting tr5.new_phase "cycle 2 auto-compact → Compacting"

(* ── Scenario 5: heartbeat failure during Overflowed ──────── *)

let test_heartbeat_failure_preserved_through_overflow () =
  (* Overflowed with a subsequent heartbeat failure: the heartbeat flag
     must stick so the keeper surfaces Failing once the overflow is
     resolved. No event is lost. *)
  let tr1 = apply_ok SM.Running running_conds (overflow_event ()) in
  check_phase SM.Overflowed tr1.new_phase "overflow → Overflowed";
  let tr2 =
    apply_ok SM.Overflowed tr1.updated_conditions
      (SM.Heartbeat_failed { consecutive = 1; max_allowed = 5 })
  in
  (* Phase stays Overflowed because context_overflow still wins in the
     priority ladder, but heartbeat_healthy is now false. *)
  check_phase SM.Overflowed tr2.new_phase
    "Overflowed outranks heartbeat failure";
  check bool "heartbeat unhealthy latched" false
    tr2.updated_conditions.heartbeat_healthy;
  (* Auto-compact finishes → overflow cleared.  Heartbeat failure now
     surfaces as Failing.  This confirms no event is swallowed. *)
  let tr3 =
    apply_ok SM.Overflowed tr2.updated_conditions SM.Auto_compact_triggered
  in
  check_phase SM.Compacting tr3.new_phase "compact starts";
  let tr4 =
    apply_ok SM.Compacting tr3.updated_conditions
      (SM.Compaction_completed { before_tokens = 205_000; after_tokens = 70_000 })
  in
  (* context_overflow cleared, heartbeat_healthy=false remains → Failing *)
  check_phase SM.Failing tr4.new_phase
    "post-compact, heartbeat failure surfaces as Failing"

let () =
  run "keeper_overflow_recovery" [
    "overflow-lifecycle",
    [ test_case "happy path" `Quick test_happy_path;
      test_case "compact failure latches Paused" `Quick
        test_compact_failure_latches_paused;
      test_case "operator clear returns to Running" `Quick
        test_operator_clear_returns_to_running;
      test_case "two consecutive overflows" `Quick
        test_two_consecutive_overflows;
      test_case "heartbeat failure preserved through overflow" `Quick
        test_heartbeat_failure_preserved_through_overflow;
    ]
  ]
