(** Keeper_registry_types_compaction — compaction-stage (KMC) FSM types and
    transitions.

    Re-homed from the deleted [Keeper_registry_types_runtime] (RFC-0206
    runtime→Runtime rebirth). The compaction FSM is independent of the removed
    runtime selection FSM — it tracks the keeper's context-compaction
    sub-lifecycle (accumulate → compact → done) and survives the runtime purge.
    Only the runtime_state half of the deleted module is dropped; this module
    carries the compaction half verbatim so its GADT witnesses, transition
    matrix, typed spec violations, and [Printexc] printer keep their contracts. *)

type compaction_stage =
  | Compaction_accumulating [@tla.idle]
  | Compaction_compacting [@tla.active]
  | Compaction_done [@tla.terminal]
[@@deriving tla]

(* Phantom witness types for compaction_stage GADT (Tier B5 pattern). *)
type compaction_accumulating = |
type compaction_compacting = |
type compaction_done = |

type 'a compaction_stage_witness =
  | Compaction_accumulating : compaction_accumulating compaction_stage_witness
  | Compaction_compacting : compaction_compacting compaction_stage_witness
  | Compaction_done : compaction_done compaction_stage_witness

type packed_compaction_stage =
  | Packed : 'a compaction_stage_witness -> packed_compaction_stage

let compaction_stage_to_witness : compaction_stage -> packed_compaction_stage = function
  | Compaction_accumulating -> Packed Compaction_accumulating
  | Compaction_compacting -> Packed Compaction_compacting
  | Compaction_done -> Packed Compaction_done
;;

let witness_to_compaction_stage : packed_compaction_stage -> compaction_stage = function
  | Packed Compaction_accumulating -> Compaction_accumulating
  | Packed Compaction_compacting -> Compaction_compacting
  | Packed Compaction_done -> Compaction_done
;;

(* Diagnostic label using the constructor name (e.g. ["Compaction_done"]).
   Used by the [Compaction_transition_violation] [Printexc] printer.
   Distinct from [Keeper_composite_observer.compaction_stage_to_string]
   which emits a snake_case form for dashboards. *)
let packed_compaction_stage_label : packed_compaction_stage -> string = function
  | Packed Compaction_accumulating -> "Compaction_accumulating"
  | Packed Compaction_compacting -> "Compaction_compacting"
  | Packed Compaction_done -> "Compaction_done"
;;

(* RFC-0072 Phase 6: typed error for forbidden compaction-stage transitions.
   One constructor per forbidden pair in the compaction matrix.  Mirrors
   [turn_phase_transition_spec_violation]; smaller because the compaction axis
   has only 3 states. *)
type compaction_transition_spec_violation =
  | Accumulating_to_done
  | Done_to_accumulating

let compaction_transition_spec_violation_to_tag = function
  | Accumulating_to_done -> "accumulating->done"
  | Done_to_accumulating -> "done->accumulating"
;;

(* RFC-0072 Phase 6: typed exception for forbidden compaction transitions.
   Replaces the prior bare [assert (match ... -> bool)] inside
   [validate_compaction_transition], whose [Assert_failure] carried only a
   file/line — not the rejected (from, to) pair.  Mirrors
   [Turn_phase_transition_violation]: the typed
   [compaction_transition_spec_violation] payload travels on the exception, and
   a [Printexc] printer renders the labelled message. *)
exception
  Compaction_transition_violation of
    { where : string
    ; from : packed_compaction_stage
    ; to_ : packed_compaction_stage
    ; violation : compaction_transition_spec_violation
    }

let compaction_transition_violation_message ~where ~from ~to_ ~violation =
  Printf.sprintf
    "%s: invalid compaction transition %s -> %s (spec_violation=%s)"
    where
    (packed_compaction_stage_label from)
    (packed_compaction_stage_label to_)
    (compaction_transition_spec_violation_to_tag violation)
;;

let raise_compaction_transition_violation ~where ~from ~to_ ~violation =
  raise (Compaction_transition_violation { where; from; to_; violation })
;;

let () =
  Printexc.register_printer (function
    | Compaction_transition_violation { where; from; to_; violation } ->
      Some (compaction_transition_violation_message ~where ~from ~to_ ~violation)
    | _ -> None)
;;
