(** Keeper_registry_types_compaction — compaction-stage (KMC) FSM types and
    transitions.

    Re-homed from the deleted [Keeper_registry_types_runtime] (RFC-0206). The
    compaction sub-lifecycle is independent of the removed runtime selection
    FSM and survives the runtime purge. *)

type compaction_stage =
  | Compaction_accumulating [@tla.idle]
  | Compaction_compacting [@tla.active]
  | Compaction_done [@tla.terminal]
[@@deriving tla]

(** {1 Compaction stage GADT infrastructure (Cycle 21 / Tier B5)} *)

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

(** Diagnostic label using the constructor name (e.g. ["Compaction_done"]).
    Used by the [Compaction_transition_violation] [Printexc] printer. *)
val packed_compaction_stage_label : packed_compaction_stage -> string

(** RFC-0072 Phase 6: typed error for forbidden compaction-stage
    transitions. *)
type compaction_transition_spec_violation =
  | Accumulating_to_done
  | Done_to_accumulating

val compaction_transition_spec_violation_to_tag
  :  compaction_transition_spec_violation
  -> string

(** RFC-0072 Phase 6: raised by [validate_compaction_transition] on a
    forbidden compaction transition, carrying the typed
    [compaction_transition_spec_violation] payload. [where] is a diagnostic
    label naming the raising function. A [Printexc] printer is registered so
    [Printexc.to_string] renders the labelled message. *)
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
