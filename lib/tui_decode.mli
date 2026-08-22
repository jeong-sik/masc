type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : Masc_domain.task_status;
  priority : int;
}

type keeper = {
  k_name : string;
  k_trace_id : string;
  k_generation : int;
  k_paused : bool;
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_autonomous_turn_count : int;
  k_autonomous_text_turn_count : int;
  k_autonomous_tool_turn_count : int;
  k_board_reactive_turn_count : int;
  k_mention_reactive_turn_count : int;
  k_noop_turn_count : int;
  k_last_proactive_outcome : string;
  k_last_blocker : string option;
  k_created_at : string;
  k_updated_at : string;
}

val sanitize_terminal_text : string -> string
(** Escape C0, DEL, raw C1 bytes, UTF-8 encoded C1 code points, and malformed
    UTF-8 bytes so external values form one printable terminal row. Call at the
    terminal rendering boundary; decoded records intentionally retain their raw
    typed value for non-terminal consumers. *)

val short_timestamp_for_terminal : string -> string
(** Keep at most the first 19 source bytes, then sanitize the result. Slicing
    before the terminal boundary ensures a split UTF-8 scalar cannot recreate a
    raw C1 byte. Empty timestamps render as [(never)]. *)

val clock_timestamp_for_terminal : string -> string
(** Select the conventional eight-byte clock portion of a timestamp when it is
    present, then sanitize the result. The final sanitizer makes arbitrary
    external timestamp bytes safe even when the byte slice splits UTF-8. *)

val keeper_blocker_for_terminal : keeper -> string
(** Terminal-boundary projection for the raw typed blocker stored in
    {!type-keeper}. Missing blockers render as [-]. *)

type planning_goal = {
  pg_id : string;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
}

type planning_rollup = {
  pr_active : int;
  pr_paused : int;
  pr_verifying : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_done : int;
  pb_cancelled : int;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_generated_at : string;
}

type log_kind =
  | Log_turn
  | Log_heartbeat

type log_channel =
  | Log_channel_turn
  | Log_channel_scheduled_autonomous
  | Log_channel_heartbeat

type log_entry = {
  le_kind : log_kind;
  le_ts : string;
  le_channel : log_channel;
  le_message_count : int option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
}

type context_unavailable_reason =
  | Context_measurement_missing
  | Context_turn_record_undecodable
  | Context_turn_record_read_failed
  | Context_turn_record_without_usage
  | Context_turn_record_trace_mismatch

type context_observation =
  | Context_observed of {
      ratio : float option;
      tokens : int;
      maximum : int option;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of context_unavailable_reason

val decode_agent : Yojson.Safe.t -> (agent, string) result
val task_of_domain : Masc_domain.task -> task
val active_tasks_of_domain : Masc_domain.task list -> task list
val decode_task : Yojson.Safe.t -> (task, string) result
val keeper_of_meta : Keeper_meta_contract.keeper_meta -> keeper
val decode_keeper : Yojson.Safe.t -> (keeper, string) result
val decode_planning_snapshot :
  Yojson.Safe.t -> (planning_snapshot, string) result
val parse_log_entry : string -> (log_entry, string) result
val decode_log_entry : Yojson.Safe.t -> (log_entry, string) result
val decode_context_observation :
  expected_trace_id:string ->
  Yojson.Safe.t ->
  (context_observation, string) result
val context_unavailable_reason_to_string : context_unavailable_reason -> string
val is_success_http_status : int -> bool
val http_status_error : status_code:int -> body:string -> string
val decode_json_response_body :
  allow_empty:bool -> status_code:int -> body:string -> (Yojson.Safe.t, string) result
val required_string_field : Yojson.Safe.t -> string -> (string, string) result
val optional_string_field :
  Yojson.Safe.t -> string -> (string option, string) result
val required_int_field : Yojson.Safe.t -> string -> (int, string) result
val int_field_or : Yojson.Safe.t -> string -> default:int -> (int, string) result
val required_display_field : Yojson.Safe.t -> string -> (string, string) result
val required_display_any_field :
  Yojson.Safe.t -> string list -> (string, string) result
val optional_body_field : Yojson.Safe.t -> (string, string) result
val required_body_field : Yojson.Safe.t -> (string, string) result
val required_list_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val optional_list_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val required_object_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t, string) result
val optional_object_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t option, string) result
val decode_list :
  string -> (Yojson.Safe.t -> ('a, string) result) -> Yojson.Safe.t list -> ('a list, string) result
val bounded_parent_depth :
  ?max_depth:int ->
  id_of:('a -> string) ->
  parent_id_of:('a -> string option) ->
  'a list ->
  'a ->
  int
val parse_keeper_chat_response : string -> (string, string) result
