(** Keeper_memory_recall — cost calculation, recall scoring, auto-rules,
    model-aware threshold adjustment, and memory evaluation.

    Pure memory bank operations are provided by [Keeper_memory_bank]
    (included below). This module adds recall-specific logic on top. *)

open Keeper_types

(** {1 Re-exported from Keeper_memory_bank} *)

include module type of Keeper_memory_bank

(** {1 Cost Calculation} *)

val cost_usd_of_usage : Oas.Types.api_usage -> model_id:string -> float

(** {1 File Reading} *)

val read_file_tail_lines : string -> max_bytes:int -> max_lines:int -> string list

val read_keeper_memory_summary
  :  Coord.config
  -> name:string
  -> max_bytes:int
  -> max_lines:int
  -> recent_limit:int
  -> keeper_memory_summary

val read_memory_horizon_counts
  :  Coord.config
  -> name:string
  -> max_bytes:int
  -> max_lines:int
  -> (string * int) list

val read_recent_memory_texts
  :  Coord.config
  -> name:string
  -> horizon:string
  -> max_bytes:int
  -> max_lines:int
  -> limit:int
  -> string list

(** {1 Query Detection} *)

val is_memory_recall_query : string -> bool
val expected_topic_hint : string -> string option

(** {1 Similarity and Normalization} *)

val clean_for_similarity : string -> string
val normalize_for_similarity : string -> string list
val char_ngrams : n:int -> string -> string list
val jaccard_similarity : string -> string -> float

(** {1 Message Extraction} *)

val latest_message_content_by_role
  :  role:Oas.Types.role
  -> Oas.Types.message list
  -> string option

val previous_assistant_message_content : Oas.Types.message list -> string option

(** {1 Goal Alignment} *)

val goal_horizon_candidates : keeper_meta -> string list
val best_goal_similarity : text:string -> goals:string list -> float

val goal_alignment_score
  :  meta:keeper_meta
  -> user_message:string option
  -> assistant_reply:string option
  -> float

(** {1 Repetition Risk} *)

val repetition_risk_score
  :  messages:Oas.Types.message list
  -> candidate_reply:string option
  -> float

(** {1 Auto-Rule Evaluation} *)

type keeper_auto_rule_eval =
  { repetition_risk : float
  ; goal_alignment : float
  ; response_alignment : float
  ; goal_drift : float
  ; reflect : bool
  ; plan : bool
  ; compact : bool
  ; handoff : bool
  ; guardrail_stop : bool
  ; guardrail_reason : string option
  ; reasons : string list
  }

val keeper_auto_rule_eval_to_json : keeper_auto_rule_eval -> Yojson.Safe.t
val keeper_reflection_payload_of_auto_rules : keeper_auto_rule_eval -> Yojson.Safe.t

val keeper_auto_rule_eval_of_measurement
  :  ?events:Keeper_state_machine.event list
  -> Keeper_measurement.measurement_snapshot
  -> keeper_auto_rule_eval

(** {1 Model-Aware Threshold Adjustment} *)

(** Compute threshold multipliers from OAS [Llm_provider.Model_meta] parameters.
    Uses [context_window] and [is_local] instead of model name matching. *)
val model_threshold_multipliers_of_model_id : string -> float * float

val evaluate_keeper_auto_rules
  :  meta:keeper_meta
  -> context_ratio:float
  -> message_count:int
  -> token_count:int
  -> repetition_risk:float
  -> goal_alignment:float
  -> response_alignment:float
  -> ?model_id:string
  -> unit
  -> keeper_auto_rule_eval

(** {1 Prioritized Action} *)

type prioritized_action =
  | Act_guardrail_stop of string
  | Act_reflect
  | Act_plan
  | Act_compact
  | Act_handoff
  | Act_none

val prioritized_action : keeper_auto_rule_eval -> prioritized_action
val prioritized_action_to_string : prioritized_action -> string

(** {1 Learned Policy Auto-Rules} *)

val learned_policy_auto_rules
  :  meta:keeper_meta
  -> context_ratio:float
  -> message_count:int
  -> token_count:int
  -> repetition_risk:float
  -> goal_alignment:float
  -> response_alignment:float
  -> ?model_id:string
  -> unit
  -> keeper_auto_rule_eval

(** {1 User Message Extraction} *)

val recent_user_messages : Oas.Types.message list -> max_n:int -> string list
val load_history_user_messages : path:string -> max_n:int -> string list

val recall_candidates_with_history
  :  checkpoint_messages:Oas.Types.message list
  -> history_path:string
  -> max_checkpoint:int
  -> max_history:int
  -> string list

(** {1 Memory Recall Evaluation} *)

type memory_recall_eval =
  { performed : bool
  ; query_kind : string
  ; expected_topic : string option
  ; candidate_count : int
  ; initial_score : float
  ; final_score : float
  ; threshold : float
  ; passed : bool
  ; best_match : string option
  }

val evaluate_memory_recall
  :  user_message:string
  -> assistant_reply:string
  -> candidates:string list
  -> memory_recall_eval

val memory_eval_to_json
  :  memory_recall_eval
  -> correction_applied:bool
  -> correction_success:bool
  -> correction_skipped_budget:bool
  -> prompt_fallback_applied:bool
  -> prompt_fallback_success:bool
  -> prompt_fallback_skipped_budget:bool
  -> postpass_budget_ms:int
  -> postpass_budget_remaining_ms:int
  -> recall_fallback_applied:bool
  -> Yojson.Safe.t

val work_kind_of_eval : memory_recall_eval -> string
