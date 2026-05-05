(** Bridge between OAS Llm_provider.Metrics.t and the masc-mcp
    Prometheus counter registry.

    OAS exposes a set of callback hooks on every LLM HTTP call
    (on_request_start, on_request_end, on_error, on_http_status, …).
    The host application installs a single process-wide sink via
    [Llm_provider.Metrics.set_global], and OAS's Complete.complete
    resolves it at call time for every code path that does not
    explicitly thread [~metrics].

    This module constructs the sink.  Each callback relays into
    [Prometheus.inc_counter] on a named metric.  No other state —
    the sink is pure forwarding, so there is no need to guard against
    concurrent fiber access beyond what Prometheus already provides.

    @since 0.4.x (telemetry chain: oas#804 + oas#807) *)

(** Canonical metric name for provider HTTP response counts.

    Label cardinality (practical upper bound as of v0.4.x):
    - [provider]: fixed enum of 6 canonical values (ollama, glm,
      glm-coding, anthropic, openai, gemini, claude_code)
    - [model]: bounded by entries in [config/cascade.json], typically
      under 10 distinct values per deployment
    - [status]: small set of HTTP codes the provider actually emits
      (usually 200, 400, 401, 429, 500, 503)

    Upper bound ≈ 6 × 10 × 10 = 600 series.  No runtime cardinality
    guard; if a deployment introduces unbounded custom model ids,
    revisit with an allowlist or drop the [model] label. *)
let http_status_metric = Prometheus.metric_llm_provider_http_status

(** Canonical metric name for silent capability drops. *)
let capability_drop_metric = Prometheus.metric_llm_provider_capability_drops
let cache_hit_metric = Prometheus.metric_llm_provider_cache_hits
let cache_miss_metric = Prometheus.metric_llm_provider_cache_misses
let request_start_metric = Prometheus.metric_llm_provider_requests_started
let error_metric = Prometheus.metric_llm_provider_errors
let retry_metric = Prometheus.metric_llm_provider_retries
let input_tokens_metric = Prometheus.metric_llm_provider_input_tokens
let output_tokens_metric = Prometheus.metric_llm_provider_output_tokens

(** Emit a single HTTP status observation to the Prometheus counter.

    Exposed so that per-call metrics sinks (e.g. the cascade-observation
    capture in [Oas_worker_cascade]) can forward [on_http_status] to the
    same counter without duplicating the label shape.  This is the
    single source of truth for the label key names. *)
let emit_http_status ~provider ~model_id ~status =
  Prometheus.inc_counter http_status_metric
    ~labels:
      [
        ("provider", provider);
        ("model", model_id);
        ("status", string_of_int status);
      ]
    ()

(** Emit a capability drop observation to the Prometheus counter. *)
let emit_capability_drop ~model_id ~field =
  Prometheus.inc_counter capability_drop_metric
    ~labels:[("model", model_id); ("field", field)]
    ()

let emit_cache_hit ~model_id =
  Prometheus.inc_counter cache_hit_metric
    ~labels:[("model", model_id)]
    ()

let emit_cache_miss ~model_id =
  Prometheus.inc_counter cache_miss_metric
    ~labels:[("model", model_id)]
    ()

let emit_request_start ~model_id =
  Prometheus.inc_counter request_start_metric
    ~labels:[("model", model_id)]
    ()

let emit_error ~model_id =
  Prometheus.inc_counter error_metric
    ~labels:[("model", model_id)]
    ()

let emit_retry ~provider ~model_id ~attempt =
  Prometheus.inc_counter retry_metric
    ~labels:
      [
        ("provider", provider);
        ("model", model_id);
        ("attempt", string_of_int attempt);
      ]
    ()

let emit_token_usage ~provider ~model_id ~input_tokens ~output_tokens =
  if input_tokens > 0 then
    Prometheus.inc_counter input_tokens_metric
      ~labels:[("provider", provider); ("model", model_id)]
      ~delta:(Float.of_int input_tokens)
      ();
  if output_tokens > 0 then
    Prometheus.inc_counter output_tokens_metric
      ~labels:[("provider", provider); ("model", model_id)]
      ~delta:(Float.of_int output_tokens)
      ()

(** Canonical metric name for the unified fallback counter (§7.3.2 Zero
    Silent Failure). Per-class counters (capability_drops,
    cross_cascade_fallback) remain for drill-down; this is the single
    numerator across all classes for the dashboard panel. *)
let fallback_triggered_metric = Prometheus.metric_fallback_triggered

(** Emit a fallback observation to the unified counter.
    [kind]   one of: cross_cascade | cascade_empty | capability_drop
                   | cli_unsupported | provider_error_fallback | …
    [detail] free-form drill-down (rejection_reason, target provider,
             dropped field, …). Cardinality bounded by callers. *)
let emit_fallback_triggered ~kind ~detail =
  Prometheus.inc_counter fallback_triggered_metric
    ~labels:[("kind", kind); ("detail", detail)]
    ()

(** Per-HTTP-request latency histogram.  Distinct from
    [masc_llm_inference_duration_seconds] (turn-scope, populated by the
    keeper AfterTurn hook): this metric is per provider HTTP call, so
    streaming retries / cascade fallbacks each add an observation.

    Populated unconditionally by the OAS [on_request_end] callback,
    which fires for every completed HTTP request regardless of whether
    the AfterTurn hook later runs.  Provides redundant latency
    observability so a broken hook does not blank out the dashboard. *)
let request_latency_metric = Prometheus.metric_llm_provider_request_latency

(** Emit a single latency observation to the Prometheus histogram.

    Exposed so that per-call metrics sinks (e.g. the cascade-observation
    capture in [Oas_worker_cascade]) can forward [on_request_end] to the
    same histogram without duplicating the label shape.  This is the
    single source of truth for the label key names. *)
let emit_request_latency ~model_id ~latency_ms =
  let seconds = Float.of_int latency_ms /. 1000.0 in
  Prometheus.observe_histogram request_latency_metric
    ~labels:[("model", model_id)] seconds

(** Build the OAS Metrics.t sink.

    Currently wired through:
    - [on_cache_hit]    → masc_llm_provider_cache_hits_total
    - [on_cache_miss]   → masc_llm_provider_cache_misses_total
    - [on_request_start] → masc_llm_provider_requests_started_total
    - [on_http_status]   → masc_llm_provider_http_status_total
    - [on_request_end]   → masc_llm_provider_request_latency_seconds
    - [on_error]        → masc_llm_provider_errors_total
    - [on_retry]        → masc_llm_provider_retries_total
    - [on_token_usage]  → masc_llm_provider_{input,output}_tokens_total *)
let make_sink () : Llm_provider.Metrics.t =
  {
    on_cache_hit = emit_cache_hit;
    on_cache_miss = emit_cache_miss;
    on_request_start = emit_request_start;
    on_http_status =
      (fun ~provider ~model_id ~status ->
        emit_http_status ~provider ~model_id ~status);
    on_request_end =
      (fun ~model_id ~latency_ms ->
        emit_request_latency ~model_id ~latency_ms);
    on_capability_drop =
      (fun ~model_id ~field ->
        emit_capability_drop ~model_id ~field);
    on_error = (fun ~model_id ~error:_ -> emit_error ~model_id);
    on_retry = emit_retry;
    on_token_usage = emit_token_usage;
  }

(** Install the sink as the process-wide default.  Idempotent — calling
    [install ()] multiple times overwrites the previous sink with a
    freshly-constructed one pointing at the same counter.  Intended to
    be called once during server bootstrap, before the first keeper
    turn fires an LLM call. *)
let install () : unit =
  Llm_provider.Metrics.set_global (make_sink ())
