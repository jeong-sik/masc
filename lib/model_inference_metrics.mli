(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper decisions.jsonl files plus inference-level costs.jsonl
    samples and computes per-model aggregates within a configurable time
    window.

    @since 2.259.0
    Extended with cost/tool/error metrics: @since 2.270.0 *)

type recent_entry = {
  re_ts_unix : float;
  re_provider : string option;
  re_outcome : string;
  re_stop_reason : string option;
  re_turn_lane : string option;
  re_input_tokens : int option;
  re_output_tokens : int option;
  re_latency_ms : float option;
  re_prompt_tok_per_sec : float option;
  re_peak_memory_gb : float option;
  re_cost_usd : float option;
  re_tools_count : int;
  re_usage_reported : bool option;
  re_telemetry_reported : bool option;
  re_usage_trust : string option;
  re_usage_anomaly_reasons : string list;
  re_coverage_reason : string option;
  re_coverage_stage : string option;
}

type coverage_reason_count = {
  crc_reason : string;
  crc_count : int;
}

type bucket_metric = {
  b_ts_start : float;
    (** Unix seconds at the floor of the bucket (inclusive start). *)
  b_entry_count : int;
  b_success_count : int;
  b_error_count : int;
  b_p50_latency_ms : float option;
  b_p95_latency_ms : float option;
  b_error_rate : float;
    (** error_count / entry_count; 0.0 when bucket is empty. *)
  b_total_cost_usd : float option;
  b_cache_hit_ratio : float option;
    (** cache_read_tokens / (cache_read_tokens + input_tokens); [Some 0.0]
        when the denominator is explicitly zero, [None] when no bucket entry
        reported either field. *)
}

type model_bucketed = {
  mb_model_id : string;
  mb_buckets : bucket_metric list;
    (** Ordered oldest-first; only non-empty buckets are emitted. *)
}

type latency_bucket = {
  lo_ms : int;
  hi_ms : int option;
  count : int;
}

type model_stats = {
  model_id : string;
  provider : string option;
  entry_count : int;
  avg_tok_per_sec : float option;
  p50_tok_per_sec : float option;
  p95_tok_per_sec : float option;
  prompt_avg_tok_per_sec : float option;
  prompt_p50_tok_per_sec : float option;
  prompt_p95_tok_per_sec : float option;
  hw_decode_avg_tok_per_sec : float option;
  hw_decode_p50_tok_per_sec : float option;
  hw_decode_p95_tok_per_sec : float option;
  max_peak_memory_gb : float option;
  thinking_fraction : float option;
    (** Fraction [0.0, 1.0] of turns in window where the model was sent
        think=true (Keeper_turn_intent adaptive classifier decision).
        [None] when no entry in the window reported [thinking_enabled]
        (older jsonl rows predating the field, or providers that don't
        expose it). Denominator = count of reporting entries. *)
  avg_latency_ms : float option;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  total_input_tokens : int option;
  total_output_tokens : int option;
  total_cache_read_tokens : int option;
  total_reasoning_tokens : int option;
  usage_sample_count : int;
  telemetry_sample_count : int;
  usage_missing_count : int;
  telemetry_missing_count : int;
  coverage_status : string;
  primary_coverage_stage : string option;
  primary_coverage_reason : string option;
  coverage_reason_counts : coverage_reason_count list;
  fallback_count : int;
  success_count : int;
  error_count : int;
  total_cost_usd : float option;
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
  latency_buckets : latency_bucket list;
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

(** Per-provider rollup of {!model_stats} aggregated across every model id
    whose [provider] matches. Feeds {!Dashboard_cascade.health_json}'s
    [providers] array so the UI can render per-provider throughput and
    latency next to the existing behavioural (success_rate, cooldown)
    fields from {!Cascade_health_tracker}.

    All perf fields are [entry_count]-weighted averages of the underlying
    [model_stats] values. Latency percentiles are approximations (a true
    p50/p95 would need to merge raw entries across models; call sites
    that need exact percentiles should compute them from [recent_entries]
    instead of this rollup).

    @since 0.173.0 *)
type provider_stats = {
  ps_provider : string;
  ps_entry_count : int;
  ps_model_count : int;
    (** Number of distinct [model_id]s contributing to this rollup. *)
  ps_avg_tok_per_sec : float option;
    (** Wall-clock throughput, entry-weighted mean across models. *)
  ps_avg_prompt_tok_per_sec : float option;
    (** Prefill throughput (prompt_per_second from OAS inference_timings),
        entry-weighted. [None] when no contributing model reported it
        (Anthropic/Gemini path). *)
  ps_avg_decode_tok_per_sec : float option;
    (** Hardware decode throughput (predicted_per_second), entry-weighted. *)
  ps_avg_latency_ms : float option;
  ps_p50_latency_ms : float option;
    (** Entry-weighted mean of per-model p50. Approximate, not a true
        p50 across all entries. *)
  ps_p95_latency_ms : float option;
    (** Entry-weighted mean of per-model p95. Approximate; see
        {!ps_p50_latency_ms}. *)
  ps_total_cost_usd : float option;
}

val provider_rollup : aggregate -> provider_stats list
(** Group the per-model entries in [aggregate] by [provider] and return
    a rollup sorted by [ps_entry_count] descending. Models with
    [provider = None] are excluded — if this drops a meaningful chunk of
    traffic it usually means an upstream [keeper_hooks_oas.provider_of_model]
    heuristic failed and should be fixed at the source rather than
    guessed at here.

    @since 0.173.0 *)

val provider_stats_to_json : provider_stats -> Yojson.Safe.t
(** JSON shape consumed by {!Dashboard_cascade}:
    {[
      {
        "provider": "ollama",
        "entry_count": 42,
        "model_count": 2,
        "avg_tok_per_sec": 52.1,
        "avg_prompt_tok_per_sec": 210.4,
        "avg_decode_tok_per_sec": 61.8,
        "avg_latency_ms": 1820.0,
        "p50_latency_ms": 1500.0,
        "p95_latency_ms": 3200.0,
        "total_cost_usd": null
      }
    ]}
    Null fields signal "no contributing model reported this metric";
    zero means "reported and equal to zero".

    @since 0.173.0 *)

val compute_cost_latency_json :
  base_path:string -> window_minutes:int -> Yojson.Safe.t
(** [compute_cost_latency_json ~base_path ~window_minutes] reads all
    raw telemetry entries once and returns the composed O4 cost-latency
    payload consumed by [GET /api/v1/dashboard/cost-latency]:

    {[
      {
        "perAgent":      [ { "agent", "in_tok", "out_tok", "cost", "p50_ms", "p95_ms" } ],
        "matrix":        { "providers": [...], "models": [...], "grid": [[...]] },
        "latencyBuckets": [ { "lo", "hi", "n" } ],
        "p50":           number | null,
        "p95":           number | null,
        "total_cost_usd": number,
        "window_minutes": number,
        "generated_at":  unix_seconds
      }
    ]}

    [perAgent] rows are sorted by cost descending and omit models with
    no cost/token signal.  [p50]/[p95] are exact global percentiles
    computed from all raw latency samples in the window (not an average
    of per-model estimates), or [null] when no latency sample
    contributed. Per-agent [p50_ms]/[p95_ms] follow the same null
    semantics. [matrix.grid] is a [providers × models] 2-D array of
    cost values in the same order as the [providers] / [models] index
    arrays.

    @since 2.300.0 *)
