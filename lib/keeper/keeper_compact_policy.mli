(** Keeper_compact_policy — explicit compaction request application.

    Applies a caller-owned typed request. Context observations never admit
    compaction on their own. *)

type compaction_rejection =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_execution_context_unavailable
  | Exact_execution_failed_before_dispatch
  | Exact_execution_failed_after_dispatch
  | Invalid_compaction_plan
  | Invalid_structure of Keeper_compaction_unit.structural_error
  | No_eligible_history
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Invalid_structural_evidence of Keeper_compaction_evidence.decode_error

(** [Prepared] is structural only; [Applied] requires a durable save. *)
type compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

val compaction_rejection_to_tag : compaction_rejection -> string
(** Stable categorical tag without instance-specific evidence detail. *)

val compaction_rejection_to_string : compaction_rejection -> string
(** Diagnostic detail. Unlike {!compaction_rejection_to_tag}, this may include
    the rejected evidence values. *)
val compaction_decision_to_string : compaction_decision -> string
val compaction_decision_prepared : compaction_decision -> bool
val compaction_decision_applied : compaction_decision -> bool

type compaction_preparation =
  { context : Keeper_context_core.working_context
  ; decision : compaction_decision
  ; evidence : Keeper_compaction_evidence.t option
  }

(** Apply a caller-owned request. Only a valid configured-LLM plan that
    strictly reduces the exact serialized checkpoint byte length is prepared.
    Every refusal preserves the original context and returns a typed reason.
    The caller owns the durable save and promotion from [Prepared] to [Applied]. *)
val compact_for_request_typed
  :  meta:Keeper_meta_contract.keeper_meta
  -> trigger:Compaction_trigger.t
  -> Keeper_context_core.working_context
  -> compaction_preparation

type pre_compact_event =
  { timestamp : float
  ; keeper_name : string
  ; checkpoint_bytes : int
  ; message_count : int
  ; strategies : string list
  ; trigger : Compaction_trigger.t
  }

val record_pre_compact_callback
  :  keeper_name:string
  -> checkpoint_bytes:int
  -> message_count:int
  -> strategies:string list
  -> trigger:Compaction_trigger.t
  -> pre_compact_event option

val register_record_pre_compact
  :  (keeper_name:string
      -> checkpoint_bytes:int
      -> message_count:int
      -> strategies:string list
      -> trigger:Compaction_trigger.t
      -> pre_compact_event option)
  -> unit
