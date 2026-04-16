(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper decisions.jsonl files and computes per-model aggregates
    within a configurable time window.

    @since 2.259.0
    Extended with cost/tool/error metrics: @since 2.270.0 *)

type recent_entry = {
  re_ts_unix : float;
  re_input_tokens : int;
  re_output_tokens : int;
  re_latency_ms : float;
  re_cost_usd : float;
  re_tools_count : int;
}

type bucket_metric = {
  b_ts_start : float;
    (** Unix seconds at the floor of the bucket (inclusive start). *)
  b_entry_count : int;
  b_success_count : int;
  b_error_count : int;
  b_p50_latency_ms : float;
  b_p95_latency_ms : float;
  b_error_rate : float;
    (** error_count / entry_count; 0.0 when bucket is empty. *)
  b_total_cost_usd : float;
  b_cache_hit_ratio : float;
    (** cache_read_tokens / (cache_read_tokens + input_tokens); 0.0 when
        denominator is zero (do not return NaN). *)
}

type model_bucketed = {
  mb_model_id : string;
  mb_buckets : bucket_metric list;
    (** Ordered oldest-first; only non-empty buckets are emitted. *)
}

type model_stats = {
  model_id : string;
  entry_count : int;
  avg_tok_per_sec : float;
  p50_tok_per_sec : float;
  p95_tok_per_sec : float;
  hw_decode_avg_tok_per_sec : float option;
  hw_decode_p50_tok_per_sec : float option;
  hw_decode_p95_tok_per_sec : float option;
  avg_latency_ms : float;
  p50_latency_ms : float;
  p95_latency_ms : float;
  total_input_tokens : int;
  total_output_tokens : int;
  total_cache_read_tokens : int;
  total_reasoning_tokens : int;
  fallback_count : int;
  success_count : int;
  error_count : int;
  total_cost_usd : float;
  avg_tool_calls_per_turn : float;
  total_tool_calls : int;
  top_tools : (string * int) list;
  recent_entries : recent_entry list;
  buckets : bucket_metric list;
}

type aggregate = {
  window_minutes : int;
  bucket_minutes : int;
  models : model_stats list;
  total_entries : int;
  total_error_entries : int;
}

val compute : base_path:string -> window_minutes:int -> aggregate
(** [compute ~base_path ~window_minutes] reads all keeper decisions.jsonl
    files, filters entries within the last [window_minutes], and returns
    per-model aggregate statistics sorted by entry count descending.
    Error turns (outcome="error") are counted separately per model.

    The returned [model_stats] record carries an empty [buckets] list and
    the enclosing [aggregate.bucket_minutes] is [0]. To include a
    time-bucketed series, call {!compute_with_buckets} instead. *)

val compute_with_buckets :
  base_path:string ->
  window_minutes:int ->
  bucket_minutes:int ->
  aggregate
(** Same as {!compute} but each returned [model_stats] additionally carries
    a [buckets] list produced by {!aggregate_buckets}. *)

val aggregate_buckets :
  base_path:string ->
  window_min:int ->
  bucket_min:int ->
  model_bucketed list
(** [aggregate_buckets ~base_path ~window_min ~bucket_min] splits the last
    [window_min] minutes into [bucket_min]-minute buckets, groups entries
    per model, and for each non-empty bucket computes:
    p50/p95 latency, error_rate, total_cost_usd, cache_hit_ratio.

    - Buckets are keyed by [floor(ts_unix / (bucket_min * 60))].
    - Only buckets with at least one entry are emitted.
    - Buckets are returned oldest-first within each model.
    - [cache_hit_ratio] is [0.0] when the denominator is zero (never NaN).
    - A non-positive [bucket_min] is treated as [1]. *)

val to_json : aggregate -> Yojson.Safe.t
(** Serialize [aggregate] to JSON for API responses. *)

val model_stats_to_json : model_stats -> Yojson.Safe.t
(** Serialize a single [model_stats] entry to JSON. *)
