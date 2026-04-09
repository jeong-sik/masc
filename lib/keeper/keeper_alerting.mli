(** Keeper_alerting — alert fanout, signal scoring, skill routing, and
    path safety checks for keeper execution.

    Includes {!Keeper_skill_routing} and {!Keeper_alerting_path} via
    [include] for backward-compatible access by downstream modules.

    @since v2.200.0 *)

open Keeper_types
open Keeper_memory

(** {1 Included: Keeper_skill_routing types} *)

type selection_mode =
  | Heuristic
  | Model_selected of string
  | Model_rejected of string

type keeper_skill_route = {
  primary_skill : string;
  secondary_skill : string option;
  reason : string;
  selection_mode : selection_mode;
}

(** {1 Usage Merging} *)

(** Merge two API usage records by summing all fields. *)
val merge_usage :
  Agent_sdk.Types.api_usage ->
  Agent_sdk.Types.api_usage ->
  Agent_sdk.Types.api_usage

(** {1 Alert Retry Logic} *)

(** Check whether an error message indicates a retryable condition
    (timeout, 429, 502-504, connection errors, etc.). *)
val alert_retryable_error : string -> bool

(** Compute retry delay in seconds with exponential backoff. *)
val alert_retry_delay_seconds : int -> float

(** Run a single alert channel with retry logic. *)
val run_alert_channel_with_retry :
  _ context ->
  channel:string ->
  enabled:bool ->
  send_once:(unit -> bool * string option) ->
  alert_channel_result

(** {1 Alert Deduplication} *)

(** Time window (seconds) for suppressing duplicate alerts. *)
val alert_dedup_window_sec : float

(** Check if an alert was already emitted within the dedup window.
    Records the alert if not deduplicated. *)
val is_alert_deduplicated :
  keeper_name:string -> reasons:string list -> bool

(** {1 Alert Signal Scoring} *)

(** Keyword weights for alert severity scoring. *)
val alert_keyword_weights : (string * float) list

val signal_bonus_guardrail_stop : float
val signal_bonus_handoff_pressure : float
val signal_bonus_low_alignment : float
val signal_bonus_multi_tool : float

val handoff_pressure_threshold : unit -> float
val goal_alignment_floor : float
val response_alignment_floor : float
val multi_tool_min_count : int

(** Compute alert signal score, reasons, and matched keywords.
    Returns [(score, reasons, keywords)]. *)
val keeper_alert_signal :
  message:string ->
  reply:string ->
  context_ratio:float ->
  goal_alignment:float ->
  response_alignment:float ->
  tool_call_count:int ->
  auto_rules:keeper_auto_rule_eval ->
  float * string list * string list

(** Format alert text for fanout channels. *)
val keeper_alert_text :
  meta:keeper_meta ->
  score:float ->
  reasons:string list ->
  keywords:string list ->
  message:string ->
  reply:string ->
  work_kind:string ->
  context_ratio:float ->
  goal_alignment:float ->
  response_alignment:float ->
  string

(** {1 Alert Channel Posting} *)

val post_keeper_alert_board :
  alert_text:string -> bool * string option

val post_keeper_alert_slack :
  alert_text:string -> bool * string option

val post_keeper_alert_slack_dm :
  alert_text:string -> user_id:string -> bool * string option

val post_keeper_alert_github :
  title:string -> body:string -> bool * string option

(** {1 Alert Orchestration} *)

(** Evaluate alert signal and fan out to configured channels
    (board, Slack webhook, Slack DM, GitHub issue).
    Handles dedup, JSONL logging, retry, and dead-letter queuing. *)
val maybe_emit_interesting_alert :
  _ context ->
  meta:keeper_meta ->
  message:string ->
  reply:string ->
  work_kind:string ->
  tool_call_count:int ->
  context_ratio:float ->
  goal_alignment:float ->
  response_alignment:float ->
  auto_rules:keeper_auto_rule_eval ->
  interesting_alert_result

(** {1 Slack API Helpers} *)

val slack_alert_token : unit -> string option

val slack_api_post_json :
  token:string ->
  endpoint:string ->
  payload:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val slack_ok_or_error : Yojson.Safe.t -> (unit, string) result

(** {1 Included: Keeper_skill_routing} *)

val keeper_allowed_skills : string list
val is_valid_keeper_skill : string -> bool
val keeper_skill_priority : string -> int
val route_keeper_skill : message:string -> keeper_skill_route
val format_skill_route_line : keeper_skill_route -> string
val format_skill_route_reason : keeper_skill_route -> string
val strip_skill_route_lines : string -> string
val parse_skill_route_response :
  string -> fallback_route:keeper_skill_route -> keeper_skill_route
val keeper_skill_routing_instructions :
  fallback_route:keeper_skill_route -> string
val skill_route_context_text :
  fallback_route:keeper_skill_route -> string

(** {1 Included: Keeper_alerting_path} *)

val project_root_of_config : Room.config -> string
val normalize_path_for_check : string -> string
val normalize_allowed_path_for_check :
  root:string -> string -> string option
val is_within_root_norm : root_norm:string -> string -> bool
val absolute_allowed_paths :
  config:Room.config -> allowed_paths:string list -> string list
val absolute_allowed_paths_result :
  config:Room.config -> allowed_paths:string list -> (string list, string) result
val resolve_keeper_target_path :
  config:Room.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, string) result
val sanitize_keeper_name : string -> string
val playground_path_of_keeper : string -> string
val playground_mind_path : string -> string
val playground_repos_path : string -> string
val effective_allowed_paths : meta:keeper_meta -> string list
val resolve_keeper_read_path :
  config:Room.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, string) result
val process_status_to_json : Unix.process_status -> Yojson.Safe.t
val extract_user_messages : working_context -> string list

(** {1 Re-exported Utilities} *)

val keeper_model_tools : Types.tool_schema list
val dedup_strings : string list -> string list
val split_csv_nonempty : string -> string list
