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

(** Canonical metric name for provider HTTP response counts. *)
let http_status_metric = "masc_llm_provider_http_status_total"

(** Build the OAS Metrics.t sink.

    Currently only [on_http_status] is wired through; the other
    callbacks inherit the default no-op behaviour from
    [Llm_provider.Metrics.noop].  Future extensions (error type
    counters, latency histograms) can add more relays without
    breaking the signature. *)
let make_sink () : Llm_provider.Metrics.t =
  let open Llm_provider.Metrics in
  {
    noop with
    on_http_status =
      (fun ~provider ~model_id ~status ->
        Prometheus.inc_counter http_status_metric
          ~labels:
            [
              ("provider", provider);
              ("model", model_id);
              ("status", string_of_int status);
            ]
          ());
  }

(** Install the sink as the process-wide default.  Idempotent — calling
    [install ()] multiple times overwrites the previous sink with a
    freshly-constructed one pointing at the same counter.  Intended to
    be called once during server bootstrap, before the first keeper
    turn fires an LLM call. *)
let install () : unit =
  Llm_provider.Metrics.set_global (make_sink ())
