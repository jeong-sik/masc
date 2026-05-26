(** Cascade and compaction FSM types and transitions. *)

type cascade_state =
  | Cascade_idle [@tla.idle]
  | Cascade_selecting [@tla.active]
  | Cascade_trying [@tla.active]
  | Cascade_done [@tla.terminal]
  | Cascade_exhausted [@tla.terminal]
[@@deriving tla]

type cascade_idle
type cascade_selecting
type cascade_trying
type cascade_done
type cascade_exhausted

type 'a cascade_state_witness =
  | Cascade_idle : cascade_idle cascade_state_witness
  | Cascade_selecting : cascade_selecting cascade_state_witness
  | Cascade_trying : cascade_trying cascade_state_witness
  | Cascade_done : cascade_done cascade_state_witness
  | Cascade_exhausted : cascade_exhausted cascade_state_witness

type packed_cascade_state =
  | Packed : 'a cascade_state_witness -> packed_cascade_state

val cascade_state_to_witness : cascade_state -> packed_cascade_state
val witness_to_cascade_state : packed_cascade_state -> cascade_state
val packed_cascade_state_label : packed_cascade_state -> string

module Cascade_transition : sig
  type ('from, 'to_) t =
    | Idle_to_selecting : (cascade_idle, cascade_selecting) t
    | Selecting_to_idle : (cascade_selecting, cascade_idle) t
    | Selecting_to_trying : (cascade_selecting, cascade_trying) t
    | Trying_to_idle : (cascade_trying, cascade_idle) t
    | Trying_to_selecting : (cascade_trying, cascade_selecting) t
    | Trying_to_done : (cascade_trying, cascade_done) t
    | Trying_to_exhausted : (cascade_trying, cascade_exhausted) t
    | Done_to_idle : (cascade_done, cascade_idle) t
    | Done_to_selecting : (cascade_done, cascade_selecting) t
    | Done_to_trying : (cascade_done, cascade_trying) t
    | Exhausted_to_idle : (cascade_exhausted, cascade_idle) t
    | Exhausted_to_selecting : (cascade_exhausted, cascade_selecting) t
    | Exhausted_to_trying : (cascade_exhausted, cascade_trying) t

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
    ; from : packed_cascade_state
    ; to_ : packed_cascade_state
    ; violation : cascade_transition_spec_violation
    }

val cascade_transition_violation_message
  :  where:string
  -> from:packed_cascade_state
  -> to_:packed_cascade_state
  -> violation:cascade_transition_spec_violation
  -> string

val raise_cascade_transition_violation
  :  where:string
  -> from:packed_cascade_state
  -> to_:packed_cascade_state
  -> violation:cascade_transition_spec_violation
  -> 'a

type cascade_resolve_outcome =
  | Resolved_transition of Cascade_transition.packed
  | Resolved_idempotent
  | Resolved_violation of cascade_transition_spec_violation

val resolve_cascade_transition
  :  from:packed_cascade_state
  -> target:packed_cascade_state
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
