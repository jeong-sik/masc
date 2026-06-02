(** Keeper_invariant_check — TLA+ safety invariant checker.

    Pure, deterministic module. No I/O, no mutable state.
    Maps directly to the INVARIANTS and PROPERTIES sections
    of specs/keeper-state-machine/KeeperStateMachine.cfg. *)

module SM = Keeper_state_machine

type violation = {
  property : string;
  detail : string;
}

(* History-free invariants (1, 6, 7, 8, 9) — derivable from a single
   (phase, conditions) snapshot.  Shared between [check_step_invariants]
   (applied to the new state) and [check_snapshot_invariants] (applied
   to a sweep-time observation).  Centralising avoids drift if a check's
   message or predicate changes. *)
let check_history_free_invariants
    ~(phase : SM.phase)
    ~(conditions : SM.conditions)
    ~(fail : string -> string -> unit)
  : unit =
  (* 1. TypeOK — phase is valid (trivially true for OCaml variant type,
     but checked here for trace deserialization correctness) *)
  if not (List.mem phase SM.all_phases) then
    fail "TypeOK" (Printf.sprintf "unknown phase: %s" (SM.phase_to_string phase));

  (* 6. RunningRequiresFiber — Running implies fiber_alive *)
  if phase = SM.Running && not conditions.fiber_alive then
    fail "RunningRequiresFiber" "phase=Running but fiber_alive=false";

  (* 7. StoppedRequiresDrain — Stopped implies both flags *)
  if phase = SM.Stopped
     && not (conditions.stop_requested && conditions.drain_complete) then
    fail "StoppedRequiresDrain"
      (Printf.sprintf "phase=Stopped but stop_requested=%b, drain_complete=%b"
         conditions.stop_requested conditions.drain_complete);

  (* 8. DeadRequiresNoBudget — pairs with BudgetNeverRevives.  A keeper
     observed in Dead phase with [restart_budget_remaining=true] is the
     direct signal of a revival via [register_restarting] on an already-
     dead entry (one of three vectors documented in iter 14 audit). *)
  if phase = SM.Dead && conditions.restart_budget_remaining then
    fail "DeadRequiresNoBudget" "phase=Dead but restart_budget_remaining=true";

  (* 9. DerivePhaseAgreement — derive_phase must agree with recorded phase *)
  let derived = SM.derive_phase conditions in
  if derived <> phase then
    fail "DerivePhaseAgreement"
      (Printf.sprintf "derive_phase=%s but recorded=%s"
         (SM.phase_to_string derived) (SM.phase_to_string phase))
;;

let check_step_invariants
    ~(prev_phase : SM.phase)
    ~(prev_conditions : SM.conditions)
    ~(prev_restart_count : int)
    ~(new_phase : SM.phase)
    ~(new_conditions : SM.conditions)
    ~(new_restart_count : int)
  : violation list =
  let violations = ref [] in
  let fail property detail =
    violations := { property; detail } :: !violations
  in

  (* History-dependent invariants (2, 3, 4, 5, 10) — require prev-state. *)

  (* 2. DeadIsForever — Dead in prev implies Dead in new *)
  if prev_phase = SM.Dead && new_phase <> SM.Dead then
    fail "DeadIsForever"
      (Printf.sprintf "was Dead, became %s" (SM.phase_to_string new_phase));

  (* 3. StoppedIsForever — Stopped in prev implies Stopped in new *)
  if prev_phase = SM.Stopped && new_phase <> SM.Stopped then
    fail "StoppedIsForever"
      (Printf.sprintf "was Stopped, became %s" (SM.phase_to_string new_phase));

  (* 4. BudgetNeverRevives — false->true forbidden *)
  if (not prev_conditions.restart_budget_remaining)
     && new_conditions.restart_budget_remaining then
    fail "BudgetNeverRevives" "restart_budget_remaining revived from false to true";

  (* 5. RestartCountMonotonic — never decreases *)
  if new_restart_count < prev_restart_count then
    fail "RestartCountMonotonic"
      (Printf.sprintf "decreased from %d to %d" prev_restart_count new_restart_count);

  (* 10. TransitionMatrixAgreement — phase change must be allowed *)
  if prev_phase <> new_phase
     && not (SM.can_transition ~from_phase:prev_phase ~to_phase:new_phase) then
    fail "TransitionMatrixAgreement"
      (Printf.sprintf "transition %s -> %s not in matrix"
         (SM.phase_to_string prev_phase) (SM.phase_to_string new_phase));

  (* History-free invariants (1, 6, 7, 8, 9) applied to the new state. *)
  check_history_free_invariants ~phase:new_phase ~conditions:new_conditions ~fail;

  List.rev !violations
;;

(* ── Snapshot invariants (R-A-6.c) ─────────────────────────

   Point-in-time invariants derivable from a single (phase, conditions)
   pair, no history required.  Useful for sweep-time scans (e.g.
   keeper_supervisor periodic audit) where prev-state tracking is not
   available.

   Exactly the history-free subset of [check_step_invariants] — both
   funnel through [check_history_free_invariants], so a change to any
   shared invariant's predicate or message takes effect in both call
   sites simultaneously.

   Iter 14 audit (`docs/tla-audit/ksm-a6-budget-never-revives-2026-05-12.md`)
   identified that [check_step_invariants] has no production callers —
   only PBT and trace validator.  This snapshot form is the structural
   foundation for production sweep-time invariant scanning; wiring into
   [keeper_supervisor.sweep_and_recover] is a follow-up. *)
let check_snapshot_invariants
    ~(phase : SM.phase)
    ~(conditions : SM.conditions)
  : violation list =
  let violations = ref [] in
  let fail property detail =
    violations := { property; detail } :: !violations
  in
  check_history_free_invariants ~phase ~conditions ~fail;
  List.rev !violations
;;
