(** Keeper_invariant_check — TLA+ safety invariant checker.

    Pure, deterministic module. No I/O, no mutable state.
    Maps directly to the INVARIANTS and PROPERTIES sections
    of specs/keeper-state-machine/KeeperStateMachine.cfg. *)

module SM = Keeper_state_machine

type violation =
  { property : string
  ; detail : string
  }

let check_step_invariants
      ~(prev_phase : SM.phase)
      ~(prev_conditions : SM.conditions)
      ~(prev_restart_count : int)
      ~(new_phase : SM.phase)
      ~(new_conditions : SM.conditions)
      ~(new_restart_count : int)
  : violation list
  =
  let violations = ref [] in
  let fail property detail = violations := { property; detail } :: !violations in
  (* 1. TypeOK — phase is valid (trivially true for OCaml variant type,
     but checked here for trace deserialization correctness) *)
  if not (List.mem new_phase SM.all_phases)
  then fail "TypeOK" (Printf.sprintf "unknown phase: %s" (SM.phase_to_string new_phase));
  (* 2. DeadIsForever — Dead in prev implies Dead in new *)
  if prev_phase = SM.Dead && new_phase <> SM.Dead
  then
    fail
      "DeadIsForever"
      (Printf.sprintf "was Dead, became %s" (SM.phase_to_string new_phase));
  (* 3. StoppedIsForever — Stopped in prev implies Stopped in new *)
  if prev_phase = SM.Stopped && new_phase <> SM.Stopped
  then
    fail
      "StoppedIsForever"
      (Printf.sprintf "was Stopped, became %s" (SM.phase_to_string new_phase));
  (* 4. BudgetNeverRevives — false->true forbidden *)
  if
    (not prev_conditions.restart_budget_remaining)
    && new_conditions.restart_budget_remaining
  then fail "BudgetNeverRevives" "restart_budget_remaining revived from false to true";
  (* 5. RestartCountMonotonic — never decreases *)
  if new_restart_count < prev_restart_count
  then
    fail
      "RestartCountMonotonic"
      (Printf.sprintf "decreased from %d to %d" prev_restart_count new_restart_count);
  (* 6. RunningRequiresFiber — Running implies fiber_alive *)
  if new_phase = SM.Running && not new_conditions.fiber_alive
  then fail "RunningRequiresFiber" "phase=Running but fiber_alive=false";
  (* 7. StoppedRequiresDrain — Stopped implies both flags *)
  if
    new_phase = SM.Stopped
    && not (new_conditions.stop_requested && new_conditions.drain_complete)
  then
    fail
      "StoppedRequiresDrain"
      (Printf.sprintf
         "phase=Stopped but stop_requested=%b, drain_complete=%b"
         new_conditions.stop_requested
         new_conditions.drain_complete);
  (* 8. DeadRequiresNoBudget — Dead implies NOT restart_budget_remaining *)
  if new_phase = SM.Dead && new_conditions.restart_budget_remaining
  then fail "DeadRequiresNoBudget" "phase=Dead but restart_budget_remaining=true";
  (* 10. DerivePhaseAgreement — derive_phase must agree with recorded phase *)
  let derived = SM.derive_phase new_conditions in
  if derived <> new_phase
  then
    fail
      "DerivePhaseAgreement"
      (Printf.sprintf
         "derive_phase=%s but recorded=%s"
         (SM.phase_to_string derived)
         (SM.phase_to_string new_phase));
  (* 11. TransitionMatrixAgreement — phase change must be allowed *)
  if
    prev_phase <> new_phase
    && not (SM.can_transition ~from_phase:prev_phase ~to_phase:new_phase)
  then
    fail
      "TransitionMatrixAgreement"
      (Printf.sprintf
         "transition %s -> %s not in matrix"
         (SM.phase_to_string prev_phase)
         (SM.phase_to_string new_phase));
  List.rev !violations
;;
