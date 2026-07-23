(** Keeper_invariant_check — TLA+ safety invariant checker.

    Shared module used by:
    - QCheck PBT (test_keeper_state_machine_pbt.ml)
    - Trace validator (keeper_trace_validate.ml)

    Checks the safety properties mirrored by KeeperStateMachine.tla. *)

type violation = {
  property : string;
  detail : string;
}

(** Check safety invariants for a single state transition step.
    Returns list of violations (empty = all passed).

    Checks:
    1.  TypeOK — phase is one of 11 valid phases
    2.  DeadIsForever — Dead in prev implies Dead in new
    3.  StoppedIsForever — Stopped in prev implies Stopped in new
    4.  RestartCountMonotonic — restart_count never decreases
    6.  RunningRequiresFiber — Running implies fiber_alive
    7.  StoppedRequiresDrain — Stopped implies stop_requested AND drain_complete
    8.  DeadRequiresTombstone — Dead implies durable tombstone latch
    9.  DerivePhaseAgreement — derive_phase conditions = new_phase
    10. TransitionMatrixAgreement — phase change implies can_transition *)
val check_step_invariants :
  prev_phase:Keeper_state_machine.phase ->
  prev_conditions:Keeper_state_machine.conditions ->
  prev_restart_count:int ->
  new_phase:Keeper_state_machine.phase ->
  new_conditions:Keeper_state_machine.conditions ->
  new_restart_count:int ->
  violation list

(** Check point-in-time safety invariants from a single (phase, conditions)
    snapshot, no history required.

    Subset of [check_step_invariants] covering the 5 invariants that are
    derivable without a prev-state:
    1. TypeOK
    6. RunningRequiresFiber
    7. StoppedRequiresDrain
    8. DeadRequiresTombstone
    9. DerivePhaseAgreement

    Suitable for periodic sweep-time scans (e.g. keeper supervisor audit).
    The history-dependent invariants (DeadIsForever, StoppedIsForever,
    RestartCountMonotonic, TransitionMatrixAgreement)
    require a prev-state and are intentionally excluded — use
    [check_step_invariants] when a prev-state is available.

    Returns list of violations (empty = all passed). *)
val check_snapshot_invariants :
  phase:Keeper_state_machine.phase ->
  conditions:Keeper_state_machine.conditions ->
  violation list
