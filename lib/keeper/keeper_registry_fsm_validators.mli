(** Runtime sub-FSM transition validators.

    Pure side-effect wrappers around [Keeper_registry_types] resolvers
    that bump [metric_fsm_guard_violation] before raising the typed
    transition-violation exception on a forbidden pair. *)

open Keeper_registry_types

(** Validate a runtime_state cross-state transition.
    Idempotent self-loops are accepted; the 7 spec-forbidden pairs raise
    [Runtime_transition_violation] with the typed
    [runtime_transition_spec_violation] payload. Counter:
    [metric_fsm_guard_violation] (action=runtime_transition, stage=guard). *)
val runtime_transition :
  from:packed_runtime_state -> to_:packed_runtime_state -> unit

(** Validate a turn_phase cross-state transition.
    Idempotent self-loops are accepted; the 19 spec-forbidden pairs raise
    [Turn_phase_transition_violation] with the typed
    [turn_phase_transition_spec_violation] payload. Counter:
    [metric_fsm_guard_violation] (action=turn_phase_transition, stage=guard). *)
val turn_phase_transition :
  from:packed_turn_phase -> to_:packed_turn_phase -> unit
