(** Keeper_invariant_check — TLA+ safety invariant checker.

    Shared module used by:
    - QCheck PBT (test_keeper_state_machine_pbt.ml)
    - Trace validator (keeper_trace_validate.ml)

    Checks 10 safety properties matching KeeperStateMachine.tla. *)

type violation =
  { property : string
  ; detail : string
  }

(** Check safety invariants for a single state transition step.
    Returns list of violations (empty = all passed).

    Checks:
    1.  TypeOK — phase is one of 11 valid phases
    2.  DeadIsForever — Dead in prev implies Dead in new
    3.  StoppedIsForever — Stopped in prev implies Stopped in new
    4.  BudgetNeverRevives — restart_budget_remaining false->true forbidden
    5.  RestartCountMonotonic — restart_count never decreases
    6.  RunningRequiresFiber — Running implies fiber_alive
    7.  StoppedRequiresDrain — Stopped implies stop_requested AND drain_complete
    8.  DeadRequiresNoBudget — Dead implies NOT restart_budget_remaining
    9.  DerivePhaseAgreement — derive_phase conditions = new_phase
    10. TransitionMatrixAgreement — phase change implies can_transition *)
val check_step_invariants
  :  prev_phase:Keeper_state_machine.phase
  -> prev_conditions:Keeper_state_machine.conditions
  -> prev_restart_count:int
  -> new_phase:Keeper_state_machine.phase
  -> new_conditions:Keeper_state_machine.conditions
  -> new_restart_count:int
  -> violation list
