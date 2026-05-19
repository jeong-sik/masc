(** Runtime sub-FSM transition validators.

    Extracted from keeper_registry.ml (lines 727-771) as part of the
    godfile decomp campaign. Each validator wraps a pure transition
    resolver from [Keeper_registry_types] in
    [Keeper_fsm_guard_runtime.wrap_unit] so a forbidden pair bumps
    [metric_fsm_guard_violation] (action/stage labels) before the
    typed transition-violation exception is raised.

    Pure side-effect calls on top of pure resolvers — no registry
    state read or written. *)

open Keeper_registry_types

let cascade_transition ~from ~to_ =
  (* Wrapped in [Keeper_fsm_guard_runtime.wrap_unit] for symmetry with
     [turn_phase_transition] and the setters
     ([set_turn_cascade_state] / [set_turn_phase]): a forbidden pair
     reached via this validator bumps [metric_fsm_guard_violation]
     (action=cascade_transition, stage=guard) before re-raising the typed
     [Cascade_transition_violation] with its backtrace intact. Without
     this wrap, a direct call to this validator on a forbidden pair was
     uninstrumented (RFC-0072 Phase 5 left it as a thin shim). *)
  Keeper_fsm_guard_runtime.wrap_unit
    ~action:"cascade_transition"
    ~stage:"guard"
    (fun () ->
       match resolve_cascade_transition ~from ~target:to_ with
       | Resolved_idempotent | Resolved_transition _ -> ()
       | Resolved_violation violation ->
         raise_cascade_transition_violation
           ~where:"validate_cascade_transition"
           ~from
           ~to_
           ~violation)
;;

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
