(** Runtime sub-FSM transition validators. *)

open Keeper_registry_types

(* RFC-0072 Phase 4b + Phase 5: collapse the 49-pair turn_phase matrix onto
   [resolve_turn_phase_transition] (PR #14912) and raise the typed
   [Turn_phase_transition_violation] (Phase 5) on the 19 forbidden pairs.
   Wrapped in [Keeper_fsm_guard_runtime.wrap_unit] so the existing metric /
   observability instrumentation ([metric_fsm_guard_violation], etc.) keeps
   firing on forbidden pairs.  The typed
   [turn_phase_transition_spec_violation] payload travels on the exception;
   a [Printexc] printer reproduces the prior message text for log output. *)
let turn_phase_transition ~from ~to_ =
  Keeper_fsm_guard_runtime.wrap_unit
    ~action:"turn_phase_transition"
    ~stage:"guard"
    (fun () ->
       match resolve_turn_phase_transition ~from ~target:to_ with
       | Resolved_turn_idempotent | Resolved_turn_transition _ -> ()
       | Resolved_turn_violation violation ->
         raise_turn_phase_transition_violation
           ~where:"validate_turn_phase_transition"
           ~from
           ~to_
           ~violation)
;;
