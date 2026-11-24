(** Per-Turn Keeper Context Inspector & Tool Calls wire codecs.

    Reuses LIVE {!Turn_record.of_json} and {!Keeper_cache_outcome_reading.of_json}
    from [masc.masc_types] directly and strictly decodes all 8 live Keeper
    context/tool-call routes verified against [origin/main]. *)

open Masc_tui_core

(** {1 Endpoint Builders} *)

val keeper_turn_records_path :
  keeper:string -> ?limit:int -> ?turn_ref:string -> unit -> string

val keeper_provider_input_path : keeper:string -> turn_ref:string -> string

val keeper_provider_input_part_path :
  keeper:string -> turn_ref:string -> index:int -> string

val keeper_cache_outcome_path : keeper:string -> turn_ref:string -> string
val keeper_next_request_path : keeper:string -> string
val keeper_turn_transcript_path : keeper:string -> turn_ref:string -> string
val keeper_tool_stats_path : keeper:string -> ?window_hours:int -> unit -> string

val keeper_tool_calls_path :
  keeper:string ->
  ?limit:int ->
  ?execution_ids:string list ->
  unit ->
  string

val keeper_tool_result_path :
  keeper:string ->
  execution_id:string ->
  ?offset:int ->
  ?max_bytes:int ->
  ?source_id:string ->
  unit ->
  string

val keeper_metrics_path : keeper:string -> string
val keeper_sandbox_logs_path : keeper:string -> ?tail:int -> unit -> string
val oauth_providers_path : string
val oauth_attached_tools_path : keeper:string -> string
val oauth_attempt_status_path :
  keeper:string -> provider:string -> attempt_id:string -> string
val oauth_login_path : keeper:string -> string
val oauth_identity_refresh_path : keeper:string -> string
val oauth_identity_switch_path : keeper:string -> string
val oauth_disconnect_path : string
val github_identity_path : keeper:string -> string
val github_login_path : keeper:string -> string
val github_token_path : keeper:string -> string

(** {1 Turn Records ([GET /api/v1/keepers/:name/turn-records])} *)

type turn_block_diff = {
  added : Turn_record.prompt_block list;
  removed : Turn_record.prompt_block list;
  changed : (Turn_record.prompt_block * Turn_record.prompt_block) list;
}

type turn_record_entry = {
  record : Turn_record.t;
  diff_vs_prev : turn_block_diff option;
}

type turn_records_page = {
  keeper : string;
  count : int;
  skipped_rows : int;
  health : string option;
  stale_reason : string option;
  live_turn_in_progress : bool;
  entries : turn_record_entry list; (** Newest-first after decoding. *)
}

val decode_turn_records : Yojson.Safe.t -> (turn_records_page, string) result

(** {1 Provider Input Snapshot ([/provider-input] & [/provider-input/part])} *)

type provider_part_kind =
  | Part_system_prompt
  | Part_message of { role : string }
  | Part_tool_schema of { name : string }

type provider_input_part = {
  part_index : int;
  part_kind : provider_part_kind;
  part_bytes : int;
  part_sha256 : string;
}

type provider_input_manifest = {
  keeper : string;
  trace_id : string;
  absolute_turn : int;
  turn_ref : string;
  runtime_profile : string;
  captured_at_unix : float;
  wire_body_bytes : int option;
  wire_endpoint : string option;
  wire_phase : string option;
  wire_capture_id : string option;
  wire_provider : string option;
  wire_model : string option;
  wire_http_codec : string option;
  wire_stream : bool option;
  wire_body_sha256 : string option;
  parts : provider_input_part list;
}

type provider_input_part_content = {
  keeper : string;
  turn_ref : string;
  part : provider_input_part;
  text : string;
}

val decode_provider_input_manifest :
  Yojson.Safe.t -> (provider_input_manifest, string) result

val decode_provider_input_part :
  Yojson.Safe.t -> (provider_input_part_content, string) result

(** {1 Cache Outcome ([/cache-outcome])} *)

val decode_cache_outcome :
  Yojson.Safe.t -> (Keeper_cache_outcome_reading.reading, string) result

(** {1 Next-Request Forecast ([/next-request])} *)

type forecast_rest =
  | Forecast_serving
  | Forecast_resting of { release_at_unix : float; release_basis : string }

type forecast_place = {
  walks_at : int;
  declared_at : int option;
  rest : forecast_rest;
}

type forecast_lane =
  | Forecast_agent_core
  | Forecast_not_applicable of string

type forecast_measured_parts = {
  reserved_measured_on_turn : int;
  reserved_bytes : int;
  instructions_bytes : int;
  schemas_bytes : int;
  pinned_measured_on_turn : int;
  pinned_measured_on_runtime : string;
  pinned_bytes : int;
  pinned_blocks : (string * int) list;
}

type forecast_parts =
  | Forecast_parts_ok of forecast_measured_parts
  | Forecast_parts_error of string

type forecast_carried = {
  first_atom : int;
  kept_atoms : int;
  transmitted_bytes : int;
  preamble_bytes : int option;
  origin_label : string;
  counted_tokens : int option;
}

type forecast_slot =
  | Slot_system_prompt of { bytes : int }
  | Slot_tools of { bytes : int }
  | Slot_preamble of { bytes : int }
  | Slot_history of { atoms : int; of_atoms : int; bytes : int }
  | Slot_wake_line of { bytes : int }
  | Slot_system_context of { bytes : int; blocks : (string * int) list }

type forecast_candidate = {
  runtime_id : string;
  lane : forecast_lane;
  parts : forecast_parts;
  history_atoms : int;
  carried : forecast_carried option;
  assembly : forecast_slot list option;
  place : forecast_place;
}

type forecast_walk =
  | Walk_order of { lane_id : string; declared : string list }
  | Walk_refused of string

type next_request_forecast = {
  keeper : string;
  trace_id : string;
  checkpoint_messages : int;
  wake_line_bytes : int;
  walk : forecast_walk;
  candidates : forecast_candidate list;
}

val decode_next_request_forecast :
  Yojson.Safe.t -> (next_request_forecast, string) result

(** {1 Turn Transcript ([/turn-transcript])} *)

type transcript_line = {
  role : string;
  content : string;
  ts_unix : float;
}

type turn_transcript = {
  keeper : string;
  turn_ref : string;
  found : bool;
  user : transcript_line list;
  assistant : transcript_line list;
}

val decode_turn_transcript : Yojson.Safe.t -> (turn_transcript, string) result

(** {1 Per-Keeper Tool Stats, Tool Calls & Tool Result} *)

type keeper_tool_stat_row = {
  name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  avg_duration_ms : int;
  p95_duration_ms : int;
  max_duration_ms : int;
  last_used_at : string;
}

type keeper_tool_hourly_bucket = {
  hour : string;
  call_count : int;
  error_count : int;
}

type keeper_tool_stats = {
  keeper : string;
  window_hours : int;
  total_entries : int;
  health : string option;
  stale_reason : string option;
  tools : keeper_tool_stat_row list;
  timeline : keeper_tool_hourly_bucket list;
}

type tool_call_entry = {
  ts_unix : float;
  tool : string;
  execution_id : string option;
  tool_use_id : string option;
  turn_kind : string option;
  duration_ms : float option;
  ok : bool option;
  disposition : string option;
  failure_class : string option;
  execution_mode : string option;
  batch_index : int option;
  batch_size : int option;
  definition_source : string option;
  input : Yojson.Safe.t;
  output : string;
  original_bytes : int option;
  truncated_to : int option;
  raw : Yojson.Safe.t;
}

type keeper_tool_calls_page = {
  keeper : string;
  count : int;
  health : string option;
  stale_reason : string option;
  coverage_gaps_count : int;
  entries : tool_call_entry list;
}

type tool_result_response =
  | Tool_result_pending
  | Tool_result_unavailable of string
  | Tool_result_page of {
      keeper : string;
      execution_id : string;
      source_id : string;
      body_sha256 : string;
      recorded_bytes : int;
      is_error : bool;
      offset : int;
      next_offset : int;
      total_bytes : int;
      eof : bool;
      content : string;
      encoding : string;
    }

val decode_keeper_tool_stats : Yojson.Safe.t -> (keeper_tool_stats, string) result
val decode_keeper_tool_calls : Yojson.Safe.t -> (keeper_tool_calls_page, string) result
val decode_tool_result : Yojson.Safe.t -> (tool_result_response, string) result

val unfold_json_strings : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively unfold JSON-in-string fields ([{...}] or [[...]]) so nested
    tool call payloads render cleanly in {!Masc_tui_ui.Json_tree}. *)

(** {1 Wave 3: Keeper Logs/Metrics & OAuth/GitHub Identity} *)

type keeper_metrics_point = {
  ts_unix : float;
  trace_id : string;
  channel : string;
  latency_ms : int;
  cost_usd : float option;
  work_kind : string;
  tool_call_count : int;
  tools_used : string list;
  message_count : int option;
}

type keeper_metrics_snapshot = {
  keeper : string;
  sample_points : int;
  turn_points : int;
  heartbeat_points : int;
  proactive_points : int;
  tool_call_count : int;
  scanned_rows : int;
  skipped_rows : int;
  top_tools : (string * int) list;
  series : keeper_metrics_point list;
}

type sandbox_log_instance = {
  instance_id : string;
  instance_name : string;
  running : bool option;
  stdout : string;
  stderr : string;
  error : string option;
}

type keeper_sandbox_logs = {
  keeper : string;
  backend : string option;
  state : string;
  reason : string option;
  tail : int;
  instances : sandbox_log_instance list;
}

type oauth_provider_row = {
  id : string;
  label : string;
  app_state_kind : string;
  problem : string option;
  callback_url : string option;
}

type oauth_providers_snapshot = {
  providers : oauth_provider_row list;
  callback_url : string option;
  callback_problem : string option;
}

type oauth_attached_provider = {
  provider : string;
  provider_label : string;
  attached : bool;
  app_state_kind : string;
  enabled : bool option;
  switch_problem : string option;
  also_on : string list;
  discovered_at : float option;
  tools : string list;
  problem : string option;
}

type oauth_attached_tools_snapshot = {
  keeper : string;
  providers : oauth_attached_provider list;
}

type oauth_attempt_status = {
  kind : string;
  expires_at : float option;
  detail : string option;
}

type oauth_login_result =
  | Oauth_login_exchange of {
      provider : string;
      provider_label : string;
      authorize_url : string;
      attempt_id : string;
      expires_at : float option;
    }
  | Oauth_login_direct of {
      provider : string;
      provider_label : string;
      tool_count : int;
      message : string;
    }

type github_auth_probe = {
  authenticated : bool;
  login : string option;
  scopes : string list;
  error : string option;
}

type github_identity_observation = {
  keeper : string;
  hostname : string;
  config_dir : string;
  projected_token_env_names : string list;
  stored : github_auth_probe;
  effective : github_auth_probe;
  effective_probe_scope : string;
  checked_at_unix : float;
}

val decode_keeper_metrics :
  Yojson.Safe.t -> (keeper_metrics_snapshot, string) result
val decode_keeper_sandbox_logs :
  Yojson.Safe.t -> (keeper_sandbox_logs, string) result
val decode_oauth_providers :
  Yojson.Safe.t -> (oauth_providers_snapshot, string) result
val decode_oauth_attached_tools :
  Yojson.Safe.t -> (oauth_attached_tools_snapshot, string) result
val decode_oauth_attempt_status :
  Yojson.Safe.t -> (oauth_attempt_status, string) result
val decode_oauth_login_result :
  Yojson.Safe.t -> (oauth_login_result, string) result
val decode_github_identity :
  Yojson.Safe.t -> (github_identity_observation, string) result

val encode_oauth_provider_body : provider:string -> Yojson.Safe.t
val encode_oauth_switch_body : provider:string -> enabled:bool -> Yojson.Safe.t
val encode_oauth_disconnect_body :
  keeper:string -> provider:string -> Yojson.Safe.t
val encode_github_token_body :
  token:string -> ?hostname:string -> unit -> Yojson.Safe.t
