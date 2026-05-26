(** Keeper_registry_types_cascade — cascade and compaction FSM types and transitions.

    Extracted from [Keeper_registry_types] (534 LoC). Pure type definitions
    and functions for the cascade_state and compaction_stage GADTs, witnesses,
    transition matrices, spec violation types, and resolvers.

    @since Keeper 500-line decomposition *)

type cascade_state =
  | Cascade_idle [@tla.idle]
  | Cascade_selecting [@tla.active]
  | Cascade_trying [@tla.active]
  | Cascade_done [@tla.terminal]
  | Cascade_exhausted [@tla.terminal]
[@@deriving tla]

(* Phantom witness types for cascade_state GADT (Tier B5 pattern). *)
type cascade_idle = |
type cascade_selecting = |
type cascade_trying = |
type cascade_done = |
type cascade_exhausted = |

type 'a cascade_state_witness =
  | Cascade_idle : cascade_idle cascade_state_witness
  | Cascade_selecting : cascade_selecting cascade_state_witness
  | Cascade_trying : cascade_trying cascade_state_witness
  | Cascade_done : cascade_done cascade_state_witness
  | Cascade_exhausted : cascade_exhausted cascade_state_witness

type packed_cascade_state = Packed : 'a cascade_state_witness -> packed_cascade_state

let cascade_state_to_witness : cascade_state -> packed_cascade_state = function
  | Cascade_idle -> Packed Cascade_idle
  | Cascade_selecting -> Packed Cascade_selecting
  | Cascade_trying -> Packed Cascade_trying
  | Cascade_done -> Packed Cascade_done
  | Cascade_exhausted -> Packed Cascade_exhausted
;;

let witness_to_cascade_state : packed_cascade_state -> cascade_state = function
  | Packed Cascade_idle -> Cascade_idle
  | Packed Cascade_selecting -> Cascade_selecting
  | Packed Cascade_trying -> Cascade_trying
  | Packed Cascade_done -> Cascade_done
  | Packed Cascade_exhausted -> Cascade_exhausted
;;

(* Diagnostic label for invalid-transition error messages.  Mirrors
   [cascade_state]; constructor changes will fail compilation here. *)
let packed_cascade_state_label : packed_cascade_state -> string = function
  | Packed Cascade_idle -> "Cascade_idle"
  | Packed Cascade_selecting -> "Cascade_selecting"
  | Packed Cascade_trying -> "Cascade_trying"
  | Packed Cascade_done -> "Cascade_done"
  | Packed Cascade_exhausted -> "Cascade_exhausted"
;;

(* RFC-0072 Phase 1: GADT-encoded cascade transitions.

   Enumerates the 13 valid cross-state transitions of the 5-variant
   [cascade_state] FSM.  Idempotent (self-loop) transitions are
   intentionally not represented — mirrors [Decision_transition] —
   because they correspond to no-op writes at the mutator boundary.

   The 7 forbidden pairs ([Idle -> Trying/Done/Exhausted],
   [Selecting -> Done/Exhausted], [Done <-> Exhausted]) have no
   constructor and are therefore type-unrepresentable.  Adding a new
   [cascade_state] variant will trigger Warning 8 in [to_tag] and in
   any future per-transition dispatcher.

   Phase 1 (this PR) introduces the module additively — no caller is
   wired yet.  Phase 2 routes [set_turn_cascade_state] through
   [resolve_cascade_transition] for internal dispatch.  Phase 3
   converts [validate_cascade_transition] into a compile-time
   fixture (mirroring PR #14893 for decision). *)
module Cascade_transition = struct
  type ('from, 'to_) t =
    (* Boot dispatch (Idle -> Selecting). *)
    | Idle_to_selecting : (cascade_idle, cascade_selecting) t
    (* Selecting -> {Idle, Trying} (retry-back or forward dispatch). *)
    | Selecting_to_idle : (cascade_selecting, cascade_idle) t
    | Selecting_to_trying : (cascade_selecting, cascade_trying) t
    (* Trying -> {Idle, Selecting, Done, Exhausted}: retry-back,
       re-entry, completion, exhaustion. *)
    | Trying_to_idle : (cascade_trying, cascade_idle) t
    | Trying_to_selecting : (cascade_trying, cascade_selecting) t
    | Trying_to_done : (cascade_trying, cascade_done) t
    | Trying_to_exhausted : (cascade_trying, cascade_exhausted) t
    (* Compaction-driven retry from terminal states.
       prepare_turn_retry_after_compaction lifts Done/Exhausted back
       into Idle/Selecting/Trying. *)
    | Done_to_idle : (cascade_done, cascade_idle) t
    | Done_to_selecting : (cascade_done, cascade_selecting) t
    | Done_to_trying : (cascade_done, cascade_trying) t
    | Exhausted_to_idle : (cascade_exhausted, cascade_idle) t
    | Exhausted_to_selecting : (cascade_exhausted, cascade_selecting) t
    | Exhausted_to_trying : (cascade_exhausted, cascade_trying) t

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
   [validate_cascade_transition] / [set_turn_cascade_state] — the typed
   [cascade_transition_spec_violation] payload now travels on the exception
   instead of being projected through a string, so callers (and the test
   surface) can pattern-match on the violation directly. The [where] field
   is a diagnostic-only label naming the raising function for parity with
   the prior message. A [Printexc] printer is registered below so logging
   that catches a generic [exn] still produces the original message text. *)
exception
  Cascade_transition_violation of
    { where : string
    ; from : packed_cascade_state
    ; to_ : packed_cascade_state
    ; violation : cascade_transition_spec_violation
    }

let cascade_transition_violation_message ~where ~from ~to_ ~violation =
  Printf.sprintf
    "%s: invalid cascade transition %s -> %s (spec_violation=%s)"
    where
    (packed_cascade_state_label from)
    (packed_cascade_state_label to_)
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
   inside [set_turn_cascade_state]. *)
type cascade_resolve_outcome =
  | Resolved_transition of Cascade_transition.packed
  | Resolved_idempotent
  | Resolved_violation of cascade_transition_spec_violation

let resolve_cascade_transition
      ~(from : packed_cascade_state)
      ~(target : packed_cascade_state)
  : cascade_resolve_outcome
  =
  match from, target with
  (* Idempotent self-loops (5). *)
  | Packed Cascade_idle, Packed Cascade_idle
  | Packed Cascade_selecting, Packed Cascade_selecting
  | Packed Cascade_trying, Packed Cascade_trying
  | Packed Cascade_done, Packed Cascade_done
  | Packed Cascade_exhausted, Packed Cascade_exhausted -> Resolved_idempotent
  (* Valid cross-state transitions (13). *)
  | Packed Cascade_idle, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Idle_to_selecting)
  | Packed Cascade_selecting, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Selecting_to_idle)
  | Packed Cascade_selecting, Packed Cascade_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Selecting_to_trying)
  | Packed Cascade_trying, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_idle)
  | Packed Cascade_trying, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_selecting)
  | Packed Cascade_trying, Packed Cascade_done ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_done)
  | Packed Cascade_trying, Packed Cascade_exhausted ->
    Resolved_transition (Cascade_transition.Packed_transition Trying_to_exhausted)
  | Packed Cascade_done, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_idle)
  | Packed Cascade_done, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_selecting)
  | Packed Cascade_done, Packed Cascade_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Done_to_trying)
  | Packed Cascade_exhausted, Packed Cascade_idle ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_idle)
  | Packed Cascade_exhausted, Packed Cascade_selecting ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_selecting)
  | Packed Cascade_exhausted, Packed Cascade_trying ->
    Resolved_transition (Cascade_transition.Packed_transition Exhausted_to_trying)
  (* Spec violations (7). *)
  | Packed Cascade_idle, Packed Cascade_trying -> Resolved_violation Idle_to_trying
  | Packed Cascade_idle, Packed Cascade_done -> Resolved_violation Idle_to_done
  | Packed Cascade_idle, Packed Cascade_exhausted -> Resolved_violation Idle_to_exhausted
  | Packed Cascade_selecting, Packed Cascade_done -> Resolved_violation Selecting_to_done
  | Packed Cascade_selecting, Packed Cascade_exhausted ->
    Resolved_violation Selecting_to_exhausted
  | Packed Cascade_done, Packed Cascade_exhausted -> Resolved_violation Done_to_exhausted
  | Packed Cascade_exhausted, Packed Cascade_done -> Resolved_violation Exhausted_to_done
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
