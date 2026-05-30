(** Keeper_registry_types_turn — cascade and compaction FSM types and transitions.

    Extracted from [Keeper_registry_types] (534 LoC). Pure type definitions
    and functions for the route_phase and compaction_stage GADTs, witnesses,
    transition matrices, spec violation types, and resolvers.

    @since Keeper 500-line decomposition *)

type route_phase =
  | Route_idle [@tla.idle]
  | Route_selecting [@tla.active]
  | Route_trying [@tla.active]
  | Route_done [@tla.terminal]
  | Route_exhausted [@tla.terminal]
[@@deriving tla]

(* Phantom witness types for route_phase GADT (Tier B5 pattern). *)
type route_idle = |
type route_selecting = |
type route_trying = |
type route_done = |
type route_exhausted = |

type 'a route_phase_witness =
  | Route_idle : route_idle route_phase_witness
  | Route_selecting : route_selecting route_phase_witness
  | Route_trying : route_trying route_phase_witness
  | Route_done : route_done route_phase_witness
  | Route_exhausted : route_exhausted route_phase_witness

type packed_route_phase = Packed : 'a route_phase_witness -> packed_route_phase

let route_phase_to_witness : route_phase -> packed_route_phase = function
  | Route_idle -> Packed Route_idle
  | Route_selecting -> Packed Route_selecting
  | Route_trying -> Packed Route_trying
  | Route_done -> Packed Route_done
  | Route_exhausted -> Packed Route_exhausted
;;

let witness_to_route_phase : packed_route_phase -> route_phase = function
  | Packed Route_idle -> Route_idle
  | Packed Route_selecting -> Route_selecting
  | Packed Route_trying -> Route_trying
  | Packed Route_done -> Route_done
  | Packed Route_exhausted -> Route_exhausted
;;

(* Diagnostic label for invalid-transition error messages.  Mirrors
   [route_phase]; constructor changes will fail compilation here. *)
let packed_route_phase_label : packed_route_phase -> string = function
  | Packed Route_idle -> "Route_idle"
  | Packed Route_selecting -> "Route_selecting"
  | Packed Route_trying -> "Route_trying"
  | Packed Route_done -> "Route_done"
  | Packed Route_exhausted -> "Route_exhausted"
;;

(* RFC-0072 Phase 1: GADT-encoded cascade transitions.

   Enumerates the 13 valid cross-state transitions of the 5-variant
   [route_phase] FSM.  Idempotent (self-loop) transitions are
   intentionally not represented — mirrors [Decision_transition] —
   because they correspond to no-op writes at the mutator boundary.

   The 7 forbidden pairs ([Idle -> Trying/Done/Exhausted],
   [Selecting -> Done/Exhausted], [Done <-> Exhausted]) have no
   constructor and are therefore type-unrepresentable.  Adding a new
   [route_phase] variant will trigger Warning 8 in [to_tag] and in
   any future per-transition dispatcher.

   Phase 1 (this PR) introduces the module additively — no caller is
   wired yet.  Phase 2 routes [set_turn_route_phase] through
   [resolve_cascade_transition] for internal dispatch.  Phase 3
   converts [validate_cascade_transition] into a compile-time
   fixture (mirroring PR #14893 for decision). *)
module Cascade_transition = struct
  type ('from, 'to_) t =
    (* Boot dispatch (Idle -> Selecting). *)
    | Idle_to_selecting : (route_idle, route_selecting) t
    (* Selecting -> {Idle, Trying} (retry-back or forward dispatch). *)
    | Selecting_to_idle : (route_selecting, route_idle) t
    | Selecting_to_trying : (route_selecting, route_trying) t
    (* Trying -> {Idle, Selecting, Done, Exhausted}: retry-back,
       re-entry, completion, exhaustion. *)
    | Trying_to_idle : (route_trying, route_idle) t
    | Trying_to_selecting : (route_trying, route_selecting) t
    | Trying_to_done : (route_trying, route_done) t
    | Trying_to_exhausted : (route_trying, route_exhausted) t
    (* Compaction-driven retry from terminal states.
       prepare_turn_retry_after_compaction lifts Done/Exhausted back
       into Idle/Selecting/Trying. *)
    | Done_to_idle : (route_done, route_idle) t
    | Done_to_selecting : (route_done, route_selecting) t
    | Done_to_trying : (route_done, route_trying) t
    | Exhausted_to_idle : (route_exhausted, route_idle) t
    | Exhausted_to_selecting : (route_exhausted, route_selecting) t
    | Exhausted_to_trying : (route_exhausted, route_trying) t

  type packed = Packed_transition : ('a, 'b) t -> packed

  let to_tag : type a b. (a, b) t -> string = function
    | Idle_to_selecting -> "idle->selecting"
    | Selecting_to_idle -> "selecting->idle"
    | Selecting_to_trying -> "selecting->trying"
    | Trying_to_idle -> "trying->idle"
    | Trying_to_selecting -> "trying->selecting"
    | Trying_to_done -> "trying->done"
    | Trying_to_exhausted -> "trying->exhausted"
    | Done_to_idle -> "done->idle"
    | Done_to_selecting -> "done->selecting"
    | Done_to_trying -> "done->trying"
    | Exhausted_to_idle -> "exhausted->idle"
    | Exhausted_to_selecting -> "exhausted->selecting"
    | Exhausted_to_trying -> "exhausted->trying"
  ;;
end

(* RFC-0072 Phase 1: typed error for cascade transition spec violations.

   Replaces the prior string-formatted [Invalid_argument] message at
   [validate_cascade_transition].  Each forbidden pair has its own
   constructor — adding a future forbidden pair (or downgrading an
   admitted pair to forbidden) is a deliberate type-level commit, not
   a substring of an error message.  Idempotent self-loops are
   classified [Idempotent_no_op] (admitted by the mutator boundary
   but not a Cascade_transition.t value). *)
type cascade_transition_spec_violation =
  | Idle_to_trying
  | Idle_to_done
  | Idle_to_exhausted
  | Selecting_to_done
  | Selecting_to_exhausted
  | Done_to_exhausted
  | Exhausted_to_done

let cascade_transition_spec_violation_to_tag = function
  | Idle_to_trying -> "idle->trying"
  | Idle_to_done -> "idle->done"
  | Idle_to_exhausted -> "idle->exhausted"
  | Selecting_to_done -> "selecting->done"
  | Selecting_to_exhausted -> "selecting->exhausted"
  | Done_to_exhausted -> "done->exhausted"
  | Exhausted_to_done -> "exhausted->done"
;;

(* RFC-0072 Phase 5: typed exception for forbidden cascade transitions.
   Replaces the prior [invalid_arg (Printf.sprintf ...)] at
   [validate_cascade_transition] / [set_turn_route_phase] — the typed
   [cascade_transition_spec_violation] payload now travels on the exception
   instead of being projected through a string, so callers (and the test
   surface) can pattern-match on the violation directly. The [where] field
   is a diagnostic-only label naming the raising function for parity with
   the prior message. A [Printexc] printer is registered below so logging
   that catches a generic [exn] still produces the original message text. *)
exception
  Cascade_transition_violation of
    { where : string
    ; from : packed_route_phase
    ; to_ : packed_route_phase
    ; violation : cascade_transition_spec_violation
    }

let cascade_transition_violation_message ~where ~from ~to_ ~violation =
  Printf.sprintf
    "%s: invalid cascade transition %s -> %s (spec_violation=%s)"
    where
    (packed_route_phase_label from)
    (packed_route_phase_label to_)
    (cascade_transition_spec_violation_to_tag violation)
;;

let raise_cascade_transition_violation ~where ~from ~to_ ~violation =
  raise (Cascade_transition_violation { where; from; to_; violation })
;;

let () =
  Printexc.register_printer (function
    | Cascade_transition_violation { where; from; to_; violation } ->
      Some (cascade_transition_violation_message ~where ~from ~to_ ~violation)
    | _ -> None)
;;

(* RFC-0072 Phase 1: resolve a (from, target) packed pair to a typed
   transition value.

   - [Ok (Packed_transition t)] when the pair matches a Cascade_transition.t
     constructor (13 valid cross-state pairs).
   - [Ok Packed_transition Idle_to_selecting] etc do NOT cover idempotent
     self-loops — those return [Error] with no spec violation (they are a
     mutator-boundary concern, not a transition).  Callers that need
     idempotent handling should check [from = target] before calling.
   - [Error spec_violation] for the 7 forbidden cross-state pairs.

   Self-loops are deliberately not in the GADT.  This function distinguishes
   them via a separate [`Idempotent] return tag below to keep Result.t
   semantically clean (Ok = transition value exists, Error = spec violation).

   Phase 2 will use this to replace the [validate_cascade_transition] call
   inside [set_turn_route_phase]. *)
type cascade_resolve_outcome =
  | Resolved_transition of Cascade_transition.packed
  | Resolved_idempotent
  | Resolved_violation of cascade_transition_spec_violation

let resolve_cascade_transition
      ~(from : packed_route_phase)
      ~(target : packed_route_phase)
  : cascade_resolve_outcome
  =
  match from, target with
  (* Idempotent self-loops (5). *)
  | Packed Route_idle, Packed Route_idle
  | Packed Route_selecting, Packed Route_selecting
  | Packed Route_trying, Packed Route_trying
  | Packed Route_done, Packed Route_done
  | Packed Route_exhausted, Packed Route_exhausted -> Resolved_idempotent
  (* Valid cross-state transitions (13). *)
  | Packed Route_idle, Packed Route_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Idle_to_selecting)
  | Packed Route_selecting, Packed Route_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Selecting_to_idle)
  | Packed Route_selecting, Packed Route_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Selecting_to_trying)
  | Packed Route_trying, Packed Route_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_idle)
  | Packed Route_trying, Packed Route_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_selecting)
  | Packed Route_trying, Packed Route_done ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_done)
  | Packed Route_trying, Packed Route_exhausted ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_exhausted)
  | Packed Route_done, Packed Route_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_idle)
  | Packed Route_done, Packed Route_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_selecting)
  | Packed Route_done, Packed Route_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_trying)
  | Packed Route_exhausted, Packed Route_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_idle)
  | Packed Route_exhausted, Packed Route_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_selecting)
  | Packed Route_exhausted, Packed Route_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_trying)
  (* Spec violations (7). *)
  | Packed Route_idle, Packed Route_trying -> Resolved_violation Idle_to_trying
  | Packed Route_idle, Packed Route_done -> Resolved_violation Idle_to_done
  | Packed Route_idle, Packed Route_exhausted -> Resolved_violation Idle_to_exhausted
  | Packed Route_selecting, Packed Route_done -> Resolved_violation Selecting_to_done
  | Packed Route_selecting, Packed Route_exhausted ->
    Resolved_violation Selecting_to_exhausted
  | Packed Route_done, Packed Route_exhausted -> Resolved_violation Done_to_exhausted
  | Packed Route_exhausted, Packed Route_done -> Resolved_violation Exhausted_to_done
;;

(* ── Compaction stage FSM ────────────────────────────────────────────── *)

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
   One constructor per of the 3 forbidden pairs in the compaction matrix
   (3 idempotent + 3 valid cross-state + 3 forbidden = 9 = 3×3).  Mirrors
   [cascade_transition_spec_violation] / [turn_phase_transition_spec_violation];
   smaller because the compaction axis has only 3 states. *)
type compaction_transition_spec_violation =
  | Accumulating_to_done
  | Done_to_accumulating
  | Done_to_compacting

let compaction_transition_spec_violation_to_tag = function
  | Accumulating_to_done -> "accumulating->done"
  | Done_to_accumulating -> "done->accumulating"
  | Done_to_compacting -> "done->compacting"
;;

(* RFC-0072 Phase 6: typed exception for forbidden compaction transitions.
   Replaces the prior bare [assert (match ... -> bool)] inside
   [validate_compaction_transition], whose [Assert_failure] carried only a
   file/line — not the rejected (from, to) pair.  Mirrors
   [Cascade_transition_violation] / [Turn_phase_transition_violation]:
   the typed [compaction_transition_spec_violation] payload travels on the
   exception, and a [Printexc] printer renders the labelled message. *)
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
