(** Keeper_compact_policy — explicit compaction request application.

    Applies a caller-owned typed request. Context observations never admit
    compaction on their own.

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** [Prepared] is structural only; [Applied] requires a durable save. *)
type compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

and compaction_rejection =
  | Retired_deterministic_mode
  | Runtime_unavailable
  | Summarizer_unavailable_or_invalid
  | Structural_noop

val compaction_decision_to_string : compaction_decision -> string
val compaction_decision_prepared : compaction_decision -> bool
val compaction_decision_applied : compaction_decision -> bool

(** Project [meta] to its [(ratio_gate, message_gate, token_gate)]
    tuple. *)
val compaction_policy_of_keeper : Keeper_meta_contract.keeper_meta -> float * int * int

(** [compact_for_request_typed ~meta ~trigger ctx] applies a caller-owned typed
    request through a valid configured-LLM plan. Missing/invalid LLM output and the retired
    deterministic mode preserve the original messages exactly.

    Return triple:
    - the (possibly compacted) working context;
    - [Some trigger] only for a structurally changed [Prepared] candidate;
    - a typed decision tag describing the request outcome. *)
val compact_for_request_typed
  :  meta:Keeper_meta_contract.keeper_meta
  -> trigger:Compaction_trigger.t
  -> Keeper_context_core.working_context
  -> Keeper_context_core.working_context
     * Compaction_trigger.t option
     * compaction_decision

type pre_compact_event = {
  timestamp : float;
  keeper_name : string;
  context_ratio : float;
  message_count : int;
  token_count : int;
  strategies : string list;
  context_window : int;
  is_local_model : bool;
  trigger : Compaction_trigger.t;
}

val record_pre_compact_callback :
  keeper_name:string ->
  context_ratio:float ->
  message_count:int ->
  token_count:int ->
  strategies:string list ->
  context_window:int ->
  is_local_model:bool ->
  trigger:Compaction_trigger.t ->
  pre_compact_event option

(** Replace [record_pre_compact_callback] with [f]. *)
val register_record_pre_compact :
  (keeper_name:string ->
   context_ratio:float ->
   message_count:int ->
   token_count:int ->
   strategies:string list ->
   context_window:int ->
   is_local_model:bool ->
   trigger:Compaction_trigger.t ->
   pre_compact_event option) ->
  unit
