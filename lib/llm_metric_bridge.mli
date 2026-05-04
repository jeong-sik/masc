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

(** Emit a capability drop observation to the Prometheus counter. *)
val emit_capability_drop : model_id:string -> field:string -> unit

(** Canonical metric name for the §7.3.2 unified fallback counter. *)
val fallback_triggered_metric : string

(** Emit a fallback observation to the unified counter.
    [kind] enumerates the fallback class (cross_cascade | cascade_empty |
    capability_drop | cli_unsupported | provider_error_fallback | …);
    [detail] carries the specific reason within the kind. Detail counters
    (capability_drops, cross_cascade_fallback) remain for per-class
    drill-down — this is the single numerator across all classes. *)
val emit_fallback_triggered : kind:string -> detail:string -> unit

(** Construct the OAS Metrics.t sink without installing it.  Useful
    for tests that want to pass [~metrics] explicitly without
    touching global state. *)
val make_sink : unit -> Llm_provider.Metrics.t

(** Install the bridge as the process-wide default metrics sink.
    Idempotent; should be called once during server bootstrap
    before any keeper turn fires its first LLM call. *)
val install : unit -> unit
