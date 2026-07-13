(** Keeper_invariant_check — TLA+ safety invariant checker.

    Pure, deterministic module. No I/O, no mutable state.
    Maps directly to the INVARIANTS and PROPERTIES sections
    of specs/keeper-state-machine/KeeperStateMachine.cfg. *)

module SM = Keeper_state_machine

type violation = {
  property : string;
  detail : string;
}

(* History-free invariants — derivable from a single
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

  (* Dead is authorized only by an explicit durable tombstone. *)
  if phase = SM.Dead && not conditions.dead_tombstone_latched then
    fail "DeadRequiresTombstone" "phase=Dead but dead_tombstone_latched=false";

  (* 9. DerivePhaseAgreement — derive_phase must agree with recorded phase *)
  let derived = SM.derive_phase conditions in
  if derived <> phase then
    fail "DerivePhaseAgreement"
      (Printf.sprintf "derive_phase=%s but recorded=%s"
         (SM.phase_to_string derived) (SM.phase_to_string phase))
;;

let check_step_invariants
    ~(prev_phase : SM.phase)
    ~prev_conditions:(_ : SM.conditions)
    ~(prev_restart_count : int)
    ~(new_phase : SM.phase)
    ~(new_conditions : SM.conditions)
    ~(new_restart_count : int)
  : violation list =
  let violations = ref [] in
  let fail property detail =
    violations := { property; detail } :: !violations
  in

  (* History-dependent invariants require prev-state. *)

  (* 2. DeadIsForever — Dead in prev implies Dead in new *)
  if prev_phase = SM.Dead && new_phase <> SM.Dead then
    fail "DeadIsForever"
      (Printf.sprintf "was Dead, became %s" (SM.phase_to_string new_phase));

  (* 3. StoppedIsForever — Stopped in prev implies Stopped in new *)
  if prev_phase = SM.Stopped && new_phase <> SM.Stopped then
    fail "StoppedIsForever"
      (Printf.sprintf "was Stopped, became %s" (SM.phase_to_string new_phase));

  (* RestartCountMonotonic — an observation counter never decreases. *)
  if new_restart_count < prev_restart_count then
    fail "RestartCountMonotonic"
      (Printf.sprintf "decreased from %d to %d" prev_restart_count new_restart_count);

  (* 10. TransitionMatrixAgreement — phase change must be allowed *)
  if prev_phase <> new_phase
     && not (SM.can_transition ~from_phase:prev_phase ~to_phase:new_phase) then
    fail "TransitionMatrixAgreement"
      (Printf.sprintf "transition %s -> %s not in matrix"
         (SM.phase_to_string prev_phase) (SM.phase_to_string new_phase));

  (* History-free invariants applied to the new state. *)
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

   This snapshot form is suitable for production sweep-time invariant
   scanning without inventing lifecycle policy. *)
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
