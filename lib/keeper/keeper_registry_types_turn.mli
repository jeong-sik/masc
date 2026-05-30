(** Cascade and compaction FSM types and transitions. *)

type route_phase =
  | Route_idle [@tla.idle]
  | Route_selecting [@tla.active]
  | Route_trying [@tla.active]
  | Route_done [@tla.terminal]
  | Route_exhausted [@tla.terminal]
[@@deriving tla]

type route_idle
type route_selecting
type route_trying
type route_done
type route_exhausted

type 'a route_phase_witness =
  | Route_idle : route_idle route_phase_witness
  | Route_selecting : route_selecting route_phase_witness
  | Route_trying : route_trying route_phase_witness
  | Route_done : route_done route_phase_witness
  | Route_exhausted : route_exhausted route_phase_witness

type packed_route_phase =
  | Packed : 'a route_phase_witness -> packed_route_phase

val route_phase_to_witness : route_phase -> packed_route_phase
val witness_to_route_phase : packed_route_phase -> route_phase
val packed_route_phase_label : packed_route_phase -> string

module Cascade_transition : sig
  type ('from, 'to_) t =
    | Idle_to_selecting : (route_idle, route_selecting) t
    | Selecting_to_idle : (route_selecting, route_idle) t
    | Selecting_to_trying : (route_selecting, route_trying) t
    | Trying_to_idle : (route_trying, route_idle) t
    | Trying_to_selecting : (route_trying, route_selecting) t
    | Trying_to_done : (route_trying, route_done) t
    | Trying_to_exhausted : (route_trying, route_exhausted) t
    | Done_to_idle : (route_done, route_idle) t
    | Done_to_selecting : (route_done, route_selecting) t
    | Done_to_trying : (route_done, route_trying) t
    | Exhausted_to_idle : (route_exhausted, route_idle) t
    | Exhausted_to_selecting : (route_exhausted, route_selecting) t
    | Exhausted_to_trying : (route_exhausted, route_trying) t

  type packed = Packed_transition : ('a, 'b) t -> packed

  val to_tag : ('from, 'to_) t -> string
end

type cascade_transition_spec_violation =
  | Idle_to_trying
  | Idle_to_done
  | Idle_to_exhausted
  | Selecting_to_done
  | Selecting_to_exhausted
  | Done_to_exhausted
  | Exhausted_to_done

val cascade_transition_spec_violation_to_tag
  :  cascade_transition_spec_violation
  -> string

exception
  Cascade_transition_violation of
    { where : string
    ; from : packed_route_phase
    ; to_ : packed_route_phase
    ; violation : cascade_transition_spec_violation
    }

val cascade_transition_violation_message
  :  where:string
  -> from:packed_route_phase
  -> to_:packed_route_phase
  -> violation:cascade_transition_spec_violation
  -> string

val raise_cascade_transition_violation
  :  where:string
  -> from:packed_route_phase
  -> to_:packed_route_phase
  -> violation:cascade_transition_spec_violation
  -> 'a

type cascade_resolve_outcome =
  | Resolved_transition of Cascade_transition.packed
  | Resolved_idempotent
  | Resolved_violation of cascade_transition_spec_violation

val resolve_cascade_transition
  :  from:packed_route_phase
  -> target:packed_route_phase
  -> cascade_resolve_outcome

type compaction_stage =
  | Compaction_accumulating [@tla.idle]
  | Compaction_compacting [@tla.active]
  | Compaction_done [@tla.terminal]
[@@deriving tla]

type compaction_accumulating
type compaction_compacting
type compaction_done

type 'a compaction_stage_witness =
  | Compaction_accumulating : compaction_accumulating compaction_stage_witness
  | Compaction_compacting : compaction_compacting compaction_stage_witness
  | Compaction_done : compaction_done compaction_stage_witness

type packed_compaction_stage =
  | Packed : 'a compaction_stage_witness -> packed_compaction_stage

val compaction_stage_to_witness : compaction_stage -> packed_compaction_stage
val witness_to_compaction_stage : packed_compaction_stage -> compaction_stage
val packed_compaction_stage_label : packed_compaction_stage -> string

type compaction_transition_spec_violation =
  | Accumulating_to_done
  | Done_to_accumulating
  | Done_to_compacting

val compaction_transition_spec_violation_to_tag
  :  compaction_transition_spec_violation
  -> string

exception
  Compaction_transition_violation of
    { where : string
    ; from : packed_compaction_stage
    ; to_ : packed_compaction_stage
    ; violation : compaction_transition_spec_violation
    }

val compaction_transition_violation_message
  :  where:string
  -> from:packed_compaction_stage
  -> to_:packed_compaction_stage
  -> violation:compaction_transition_spec_violation
  -> string

val raise_compaction_transition_violation
  :  where:string
  -> from:packed_compaction_stage
  -> to_:packed_compaction_stage
  -> violation:compaction_transition_spec_violation
  -> 'a
