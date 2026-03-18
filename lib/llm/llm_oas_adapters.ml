(** OAS Cache + Metrics adapters for MASC infrastructure.

    Bridges MASC's two-tier LLM response cache and Prometheus metrics
    to OAS's injected {!Llm_provider.Cache.t} and {!Llm_provider.Metrics.t}
    interfaces.

    @since 2.107.0 — Phase 2 OAS integration *)

(** Build an OAS cache adapter backed by MASC's L1+L2 cache.
    Wraps {!Llm_response_cache} with error handling — errors are
    logged and treated as cache misses to avoid failing completions.

    Currently unused: MASC handles caching at the orchestration layer
    (temperature-aware keys). This adapter is for future full OAS cache
    integration when OAS fingerprint gains temperature awareness. *)
let [@warning "-32"] cache_adapter () : Llm_provider.Cache.t =
  {
    get =
      (fun ~key ->
        match Llm_response_cache.get_json ~key with
        | Ok (Some json) -> Some json
        | Ok None -> None
        | Error e ->
            Log.LlmClient.warn "oas cache adapter: read error: %s" e;
            None);
    set =
      (fun ~key ~ttl_sec json ->
        match
          Llm_response_cache.set_json ~key ~ttl_seconds:ttl_sec json
        with
        | Ok () -> ()
        | Error e ->
            Log.LlmClient.warn "oas cache adapter: write error: %s" e);
  }

(** Build an OAS metrics adapter backed by MASC's Prometheus counters
    and structured logging. *)
let metrics_adapter () : Llm_provider.Metrics.t =
  {
    on_cache_hit =
      (fun ~model_id ->
        ignore model_id;
        Prometheus.inc_counter "masc_llm_cache_hits_total" ());
    on_cache_miss =
      (fun ~model_id ->
        ignore model_id;
        Prometheus.inc_counter "masc_llm_cache_misses_total" ());
    on_request_start =
      (fun ~model_id ->
        Log.LlmClient.debug "oas-metrics: request_start model=%s" model_id);
    on_request_end =
      (fun ~model_id ~latency_ms ->
        Log.LlmClient.debug "oas-metrics: request_end model=%s latency=%dms"
          model_id latency_ms);
    on_error =
      (fun ~model_id ~error ->
        Prometheus.inc_counter "masc_llm_errors_total" ();
        Log.LlmClient.warn "oas-metrics: error model=%s: %s" model_id error);
    on_cascade_fallback =
      (fun ~from_model ~to_model ~reason ->
        Log.LlmClient.info "oas-metrics: cascade fallback %s -> %s: %s"
          from_model to_model reason);
  }
