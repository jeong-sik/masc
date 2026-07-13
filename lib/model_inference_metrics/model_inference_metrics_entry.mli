(** Shared types and small helpers for model inference metrics. *)

module StringMap : module type of Set_util.StringMap
module IntMap : Map.S with type key = int

val model_id_unknown : string

type recent_entry =
  { re_ts_unix : float
  ; re_provider : string option
  ; re_outcome : string
  ; re_stop_reason : string option
  ; re_turn_lane : string option
  ; re_input_tokens : int option
  ; re_output_tokens : int option
  ; re_cache_read_tokens : int option
  ; re_cache_creation_tokens : int option
  ; re_latency_ms : float option
  ; re_prompt_tok_per_sec : float option
  ; re_peak_memory_gb : float option
  ; re_cost_usd : float option
  ; re_tools_count : int
  ; re_usage_reported : bool option
  ; re_telemetry_reported : bool option
  ; re_usage_trust : string option
  ; re_usage_anomaly_reasons : string list
  ; re_coverage_reason : string option
  ; re_coverage_stage : string option
  ; re_streaming_ttfrc_ms : float option
  ; re_streaming_inter_chunk_count : int option
  ; re_streaming_inter_chunk_avg_ms : float option
  }

type coverage_reason_count =
  { crc_reason : string
  ; crc_count : int
  }

type bucket_metric =
  { b_ts_start : float
  ; b_entry_count : int
  ; b_success_count : int
  ; b_error_count : int
  ; b_p50_latency_ms : float option
  ; b_p95_latency_ms : float option
  ; b_error_rate : float
  ; b_total_cost_usd : float option
  ; b_cache_hit_ratio : float option
  }

type model_bucketed =
  { mb_model_id : string
  ; mb_buckets : bucket_metric list
  }

type model_stats =
  { model_id : string
  ; provider : string option
  ; entry_count : int
  ; avg_tok_per_sec : float option
  ; p50_tok_per_sec : float option
  ; p95_tok_per_sec : float option
  ; prompt_avg_tok_per_sec : float option
  ; prompt_p50_tok_per_sec : float option
  ; prompt_p95_tok_per_sec : float option
  ; hw_decode_avg_tok_per_sec : float option
  ; hw_decode_p50_tok_per_sec : float option
  ; hw_decode_p95_tok_per_sec : float option
  ; max_peak_memory_gb : float option
  ; thinking_fraction : float option
  ; avg_latency_ms : float option
  ; p50_latency_ms : float option
  ; p95_latency_ms : float option
  ; total_input_tokens : int option
  ; total_output_tokens : int option
  ; total_cache_read_tokens : int option
  ; total_cache_creation_tokens : int option
  ; total_reasoning_tokens : int option
  ; usage_sample_count : int
  ; telemetry_sample_count : int
  ; usage_missing_count : int
  ; telemetry_missing_count : int
  ; coverage_status : string
  ; primary_coverage_stage : string option
  ; primary_coverage_reason : string option
  ; coverage_reason_counts : coverage_reason_count list
  ; fallback_count : int
  ; success_count : int
  ; error_count : int
  ; total_cost_usd : float option
  ; avg_tool_calls_per_turn : float
  ; total_tool_calls : int
  ; top_tools : (string * int) list
  ; recent_entries : recent_entry list
  ; buckets : bucket_metric list
  }

type latency_bucket =
  { lo_ms : int
  ; hi_ms : int option
  ; count : int
  }

type aggregate =
  { window_minutes : int
  ; bucket_minutes : int
  ; models : model_stats list
  ; total_entries : int
  ; total_error_entries : int
  ; latency_buckets : latency_bucket list
  }

type provider_stats =
  { ps_provider : string
  ; ps_entry_count : int
  ; ps_model_count : int
  ; ps_avg_tok_per_sec : float option
  ; ps_avg_prompt_tok_per_sec : float option
  ; ps_avg_decode_tok_per_sec : float option
  ; ps_avg_latency_ms : float option
  ; ps_p50_latency_ms : float option
  ; ps_p95_latency_ms : float option
  ; ps_total_cost_usd : float option
  }

type raw_entry =
  { model : string
  ; provider : string option
  ; ts_unix : float
  ; outcome : string
  ; stop_reason : string option
  ; turn_lane : string option
  ; tok_per_sec : float option
  ; prompt_tok_per_sec : float option
  ; hw_decode_tok_per_sec : float option
  ; peak_memory_gb : float option
  ; thinking_enabled : bool option
  ; latency_ms : float option
  ; input_tokens : int option
  ; output_tokens : int option
  ; cache_read_tokens : int option
  ; cache_creation_tokens : int option
  ; reasoning_tokens : int option
  ; fallback_applied : bool
  ; cost_usd : float option
  ; tool_call_count : int
  ; tools_used : string list
  ; usage_reported : bool option
  ; telemetry_reported : bool option
  ; usage_trust : string option
  ; usage_anomaly_reasons : string list
  ; coverage_reason : string option
  ; coverage_stage : string option
  ; is_error : bool
  ; streaming_ttfrc_ms : float option
  ; streaming_inter_chunk_count : int option
  ; streaming_inter_chunk_avg_ms : float option
  }

type parse_error =
  | Not_assoc
  | Missing_ts_unix
  | Out_of_window
  | No_telemetry_object
  | Missing_outcome
  | Missing_success_model
  | Missing_error_model_attribution
  | Missing_cost_model

val parse_error_label : parse_error -> string
val parse_error_is_schema_violation : parse_error -> bool
val percentile : float array -> float -> float
val average_opt : float array -> float option
val percentile_opt : float array -> float -> float option
val count_if : ('a -> bool) -> 'a list -> int
val take : int -> 'a list -> 'a list
val sum_int_opt : int list -> int option
val sum_float_opt : float list -> float option

val json_float_field_opt :
  string -> (string * Yojson.Safe.t) list -> float option

val json_positive_float_field_opt :
  string -> (string * Yojson.Safe.t) list -> float option

val json_int_field_opt : string -> (string * Yojson.Safe.t) list -> int option
val json_bool_field_opt : string -> (string * Yojson.Safe.t) list -> bool option
val json_string_field_opt : string -> (string * Yojson.Safe.t) list -> string option
val json_string_list_field : string -> (string * Yojson.Safe.t) list -> string list

val infer_usage_trust_from_fields :
  (string * Yojson.Safe.t) list ->
  usage_reported:bool option ->
  input_tokens:int option ->
  output_tokens:int option ->
  string option * string list
