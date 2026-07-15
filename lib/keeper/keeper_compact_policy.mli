(** Keeper_compact_policy — explicit compaction request application.

    Applies a caller-owned typed request. Context observations never admit
    compaction on their own. *)

type compaction_rejection =
  | Retired_deterministic_mode
  | Runtime_identity_unavailable
  | Summarizer_unavailable
  | Plan_unavailable_or_invalid
  | Structurally_unchanged
  | Checkpoint_not_reduced

(** [Prepared] is structural only; [Applied] requires a durable save. *)
type compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

val compaction_rejection_to_string : compaction_rejection -> string
val compaction_decision_to_string : compaction_decision -> string
val compaction_decision_prepared : compaction_decision -> bool
val compaction_decision_applied : compaction_decision -> bool

(** Legacy configuration projection retained until the unused ratio/message/
    token gates are removed from [keeper_meta]. It is not consulted by
    {!compact_for_request_typed}. *)
val compaction_policy_of_keeper : Keeper_meta_contract.keeper_meta -> float * int * int

(** Apply a caller-owned request. Only a valid configured-LLM plan that
    strictly reduces the exact serialized checkpoint byte length is prepared.
    Every refusal preserves the original context and returns a typed reason.
    The caller owns the durable save and promotion from [Prepared] to [Applied]. *)
val compact_for_request_typed
  :  meta:Keeper_meta_contract.keeper_meta
  -> trigger:Compaction_trigger.t
  -> Keeper_context_core.working_context
  -> Keeper_context_core.working_context * compaction_decision

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
