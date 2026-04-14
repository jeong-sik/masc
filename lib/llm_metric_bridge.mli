(** Bridge between OAS Llm_provider.Metrics.t and the masc-mcp
    Prometheus counter registry.

    See the implementation docstring for the rationale; briefly,
    this module installs a process-wide sink via
    [Llm_provider.Metrics.set_global] so that keeper cascade calls
    — which do not thread [~metrics] explicitly through
    [Agent.run] — can still observe HTTP responses per provider.

    @since 0.4.x (telemetry chain: oas#804 + oas#807) *)

(** Canonical metric name used when emitting the counter.  Exposed
    for test assertions and dashboard integration. *)
val http_status_metric : string

(** Emit a single HTTP status observation to the Prometheus counter.
    Called by both the global sink built in {!make_sink} and any
    per-call OAS [Metrics.t] literal that wants to forward
    [on_http_status] (e.g. cascade observation captures).  Single
    source of truth for the label shape. *)
val emit_http_status :
  provider:string -> model_id:string -> status:int -> unit

(** Emit a single latency observation to the Prometheus histogram.
    Called by both the global sink built in {!make_sink} and any
    per-call OAS [Metrics.t] literal that wants to forward
    [on_request_end] (e.g. cascade observation captures).  Single
    source of truth for the label shape. *)
val emit_request_latency : model_id:string -> latency_ms:int -> unit

(** Construct the OAS Metrics.t sink without installing it.  Useful
    for tests that want to pass [~metrics] explicitly without
    touching global state. *)
val make_sink : unit -> Llm_provider.Metrics.t

(** Install the bridge as the process-wide default metrics sink.
    Idempotent; should be called once during server bootstrap
    before any keeper turn fires its first LLM call. *)
val install : unit -> unit
