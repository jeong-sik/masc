(** Keeper_exec_context — shared keeper context utilities: working context,
    checkpoint management, compaction, room presence, system prompts,
    text processing, proactive prompt helpers, and proactive generation.

    Pure types and context operations are provided by
    [Keeper_working_context] (included below). This module adds
    keeper-specific logic on top. *)

open Keeper_types
open Keeper_memory

(** {1 Re-exported from Keeper_working_context} *)

include module type of Keeper_working_context

(** {1 Inference Utilities} *)

val timed : (unit -> 'a) -> 'a * int
val zero_usage : Agent_sdk.Types.api_usage
val usage_of_response : Agent_sdk.Types.api_response -> Agent_sdk.Types.api_usage
val total_tokens : Agent_sdk.Types.api_usage -> int

(** {1 Checkpoint Store Delegation} *)

val save_session_checkpoint : session_context -> checkpoint -> unit
val load_latest_checkpoint : session_context -> checkpoint option

(** {1 Keeper Context Lifecycle} *)

val log_keeper_exn : label:string -> exn -> unit

val checkpoint_max_tokens :
  Agent_sdk.Checkpoint.t -> fallback:int -> int

val context_of_oas_checkpoint :
  Agent_sdk.Checkpoint.t -> primary_model_max_tokens:int -> working_context

val context_of_legacy_checkpoint :
  checkpoint -> primary_model_max_tokens:int -> working_context

val checkpoint_model_of_meta : keeper_meta -> string

val save_oas_checkpoint :
  session:session_context ->
  agent_name:string ->
  model:string ->
  ctx:working_context ->
  generation:int ->
  Agent_sdk.Checkpoint.t

val checkpoint_generation :
  Agent_sdk.Checkpoint.t -> fallback:int -> int

(** {1 Handoff Rollover} *)

type handoff_rollover = {
  updated_meta : keeper_meta;
  handoff_json : Yojson.Safe.t option;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

type compaction_event = {
  applied : bool;
  trigger : string option;
  decision : string;
  before_tokens : int;
  after_tokens : int;
  saved_tokens : int;
}

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_sdk.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  compaction : compaction_event;
  turn_generation : int;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

val maybe_rollover_oas_handoff :
  base_dir:string ->
  meta:keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  checkpoint:Agent_sdk.Checkpoint.t option ->
  handoff_rollover

(** {1 Checkpoint Loading and Saving} *)

val load_context_from_checkpoint :
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  session_context * working_context option

val save_checkpoint :
  session_context -> working_context -> generation:int -> checkpoint

(** {1 Compaction} *)

val compaction_policy_of_keeper : keeper_meta -> float * int * int

val compact_if_needed :
  meta:keeper_meta ->
  now_ts:float ->
  working_context ->
  working_context * string option * string

val apply_post_turn_lifecycle :
  base_dir:string ->
  meta:keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  checkpoint:Agent_sdk.Checkpoint.t option ->
  post_turn_lifecycle

(** {1 Trace and Board Utilities} *)

val generate_trace_id : unit -> string

val keeper_board_write_tool_names : string list

val keeper_write_done : string list -> bool

val keeper_action_kind_of_tool_names : string list -> string

(** {1 Model and Room Utilities} *)

val effective_model_labels_for_turn :
  keeper_meta -> string list

val room_cursor_for : keeper_meta -> string -> int

val set_room_cursor : keeper_meta -> string -> int -> keeper_meta

val room_ids_for_meta : Room.config -> keeper_meta -> string list

val ensure_keeper_room_presence : Room.config -> keeper_meta -> keeper_meta

(** {1 Mention Detection} *)

val exact_direct_mention_present :
  targets:string list -> string -> bool

(** {1 Prompt Delegation} *)

val keeper_constitution : unit -> string

val build_keeper_system_prompt :
  goal:string ->
  short_goal:string ->
  mid_goal:string ->
  long_goal:string ->
  soul_profile:string ->
  will:string ->
  needs:string ->
  desires:string ->
  instructions:string ->
  ?persona_extended:string ->
  unit ->
  string

val append_trait_clause : base:string -> clause:string -> string

val proactive_prompt_for_keeper :
  meta:keeper_meta ->
  idle_seconds:int ->
  keeper_state_snapshot option ->
  string ->
  string

(** {1 Proactive Generation} *)

type proactive_generation_result = {
  reply : string;
  usage : Agent_sdk.Types.api_usage;
  model_used : string;
  latency_ms : int;
  attempts : int;
  total_cost_usd : float;
  fallback_applied : bool;
  tools_used : string list;
}

val proactive_retry_instruction : int -> reason:string -> string
val proactive_temperature : cascade_name:string -> int -> float

(** {1 Text Processing} *)

val strip_state_blocks_text : string -> string
val trim_to_option : string -> string option
val state_snapshot_reply_fallback : keeper_state_snapshot option -> string option
val strip_internal_reply_markup : string -> string
val user_visible_reply_text : ?fallback:string -> string -> string
val normalize_proactive_text : string -> string
val extract_checkin_text : string -> string option

(** {1 Proactive Quality Checks} *)

val proactive_has_terminal_punct : string -> bool
val proactive_has_terminal_korean_ending : string -> bool
val proactive_has_terminal_ending : string -> bool
val proactive_looks_fragmentary : string -> bool
val proactive_fallback_reply : meta:keeper_meta -> idle_seconds:int -> string
val proactive_quality_check : string -> (string, string) result
val looks_fragmentary_history_text : string -> bool

(** {1 Proactive Generation Entry Point} *)

val run_proactive_generation :
  model_labels:string list ->
  config:Room.config ->
  ctx_work:working_context ->
  meta:keeper_meta ->
  continuity_snapshot:keeper_state_snapshot option ->
  continuity_summary:string ->
  idle_seconds:int ->
  proactive_generation_result option

(** {1 Memory Check} *)

val memory_check_default_json : unit -> Yojson.Safe.t
