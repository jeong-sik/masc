(** Runtime sub-FSM transition validators. *)

open Keeper_registry_types

(** Validate a turn_phase cross-state transition.
    Idempotent self-loops are accepted; the 19 spec-forbidden pairs raise
    [Turn_phase_transition_violation] with the typed
    [turn_phase_transition_spec_violation] payload. Counter:
    [metric_fsm_guard_violation] (action=turn_phase_transition, stage=guard). *)
val turn_phase_transition :
  from:packed_turn_phase -> to_:packed_turn_phase -> unit
