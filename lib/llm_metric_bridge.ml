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
let http_status_metric = "masc_llm_provider_http_status_total"

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

(** Per-HTTP-request latency histogram.  Distinct from
    [masc_llm_inference_duration_seconds] (turn-scope, populated by the
    keeper AfterTurn hook): this metric is per provider HTTP call, so
    streaming retries / cascade fallbacks each add an observation.

    Populated unconditionally by the OAS [on_request_end] callback,
    which fires for every completed HTTP request regardless of whether
    the AfterTurn hook later runs.  Provides redundant latency
    observability so a broken hook does not blank out the dashboard. *)
let request_latency_metric = "masc_llm_provider_request_latency_seconds"

(** Build the OAS Metrics.t sink.

    Currently wired through:
    - [on_http_status]   → masc_llm_provider_http_status_total
    - [on_request_end]   → masc_llm_provider_request_latency_seconds

    Other callbacks ([on_cache_hit/miss], [on_request_start], [on_error],
    [on_cascade_fallback]) inherit the default no-op from
    [Llm_provider.Metrics.noop].  Add more relays here as their
    consuming dashboards land. *)
let make_sink () : Llm_provider.Metrics.t =
  let open Llm_provider.Metrics in
  {
    noop with
    on_http_status =
      (fun ~provider ~model_id ~status ->
        emit_http_status ~provider ~model_id ~status);
    on_request_end =
      (fun ~model_id ~latency_ms ->
        let seconds = Float.of_int latency_ms /. 1000.0 in
        Prometheus.observe_histogram request_latency_metric
          ~labels:[("model", model_id)] seconds);
  }

(** Install the sink as the process-wide default.  Idempotent — calling
    [install ()] multiple times overwrites the previous sink with a
    freshly-constructed one pointing at the same counter.  Intended to
    be called once during server bootstrap, before the first keeper
    turn fires an LLM call. *)
let install () : unit =
  Llm_provider.Metrics.set_global (make_sink ())
