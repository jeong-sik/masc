(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, proactive/explicit room behavior, and keepalive runtime.

    Internal helpers (proactive quality checks, explicit room replies,
    autonomous execution) are hidden. Only externally-called functions
    and types are exposed.
*)

open Keeper_types

(** {1 Error Logging} *)

(** Log a keeper exception with a descriptive label. *)
val log_keeper_exn : label:string -> exn -> unit

(** {1 Types} *)

(** Social board event for proactive room behavior. *)
type social_board_event = {
  kind : [ `Board_post | `Board_comment ];
  post_id : string;
  comment_id : string option;
  author : string;
  content : string;
  created_at : float;
}

(** Outcome of a social turn attempt. *)
type social_turn_outcome = {
  outcome : [ `Acted | `Passed ];
  summary : string;
  reason : string;
  action_kind : string;
  tools_used : string list;
  decision_reason : string option;
  failure_reason : string option;
}

(** {1 Context and Checkpoint} *)

(** Load keeper context from checkpoint for resumption. *)
val load_context_from_checkpoint :
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  Context_manager.session_context * Context_manager.working_context option

(** Save a checkpoint for the current context. *)
val save_checkpoint :
  Context_manager.session_context ->
  Context_manager.working_context ->
  generation:int ->
  Context_manager.checkpoint

(** Ensure keeper is joined to all configured rooms. *)
val ensure_keeper_room_presence : Room.config -> keeper_meta -> keeper_meta

(** Default JSON for memory check tool. *)
val memory_check_default_json : unit -> Yojson.Safe.t

(** {1 Keepalive Runtime} *)

(** Emit proactive message if conditions are met (idle time, soul profile). *)
val maybe_emit_proactive : _ context -> keeper_meta -> keeper_meta

(** Emit explicit room replies if trigger mode requires it. *)
val maybe_emit_explicit_room_replies : _ context -> keeper_meta -> keeper_meta

(** {1 Compaction} *)

(** Extract compaction policy tuple from keeper metadata. *)
val compaction_policy_of_keeper : keeper_meta -> float * int * int

(** Compact context if thresholds are exceeded.
    Returns updated context, optional summary, and compaction label. *)
val compact_if_needed :
  meta:keeper_meta ->
  now_ts:float ->
  Context_manager.working_context ->
  Context_manager.working_context * string option * string

(** {1 Trace and Model} *)

(** Generate unique trace ID for a keeper turn. *)
val generate_trace_id : unit -> string

(** Resolve effective model labels for a turn. *)
val effective_model_labels_for_turn :
  keeper_meta -> inline_models:string list -> string list

(** {1 Room Cursor} *)

(** Get last-seen sequence number for a room. *)
val room_cursor_for : keeper_meta -> string -> int

(** Set last-seen sequence number for a room. *)
val set_room_cursor : keeper_meta -> string -> int -> keeper_meta

(** {1 Mention Detection} *)

(** Check if any target mention is directly present in content. *)
val exact_direct_mention_present : targets:string list -> string -> bool

(** {1 System Prompt and Identity} *)

(** Build system prompt for keeper agent. *)
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
  string

(** Append trait clause to existing trait string. *)
val append_trait_clause : base:string -> clause:string -> string

(** Apply self-model drift to keeper metadata.
    Returns updated meta, whether drift occurred, and optional reason. *)
val apply_self_model_drift :
  meta:keeper_meta ->
  user_message:string ->
  work_kind:string ->
  keeper_meta * bool * string option

(** {1 Text Processing} *)

(** Remove [STATE]..[/STATE] blocks from text. *)
val strip_state_blocks_text : string -> string

(** Extract user-visible reply text, stripping internal markup. *)
val user_visible_reply_text : ?fallback:string -> string -> string

(** Check if text appears fragmentary (incomplete sentence fragments). *)
val looks_fragmentary_history_text : string -> bool

(** {1 Proactive Behavior} *)

(** Generate proactive prompt for idle keeper. *)
val proactive_prompt_for_keeper :
  meta:keeper_meta ->
  idle_seconds:int ->
  Keeper_memory.keeper_state_snapshot option ->
  string ->
  string

(** Generate retry instruction for proactive attempt. *)
val proactive_retry_instruction : int -> reason:string -> string

(** Get temperature for proactive attempt. *)
val proactive_temperature : int -> float

(** {1 Social Board} *)

(** Execute a social board event turn. *)
val run_social_board_event_turn :
  _ context ->
  meta:keeper_meta ->
  event:social_board_event ->
  (keeper_meta * social_turn_outcome, string) result
