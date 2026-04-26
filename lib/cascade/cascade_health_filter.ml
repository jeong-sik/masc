(** Cascade health filtering — classify errors and filter provider lists
    by local health discovery and API key presence.

    Extracted from cascade_config.ml for cohesion.

    @since 0.99.5 *)

(* ── Cascade-level error classification ────────────────── *)

(** Decide whether an error should cascade to the next provider.

    Delegates to [Oas_compat.Http_client.should_cascade] so that the
    exhaustive match over [Llm_provider.Http_client.http_error]
    variants lives in exactly one place. When OAS adds a new error
    variant, only [lib/oas_compat] fails to compile, not this module
    and every other consumer. *)
type cascade_failure_class =
  Oas_compat.Http_client.cascade_failure_class =
  | Local_resource_exhaustion
  | Context_overflow
  | Provider_parse_error
  | Transient_http of int
  | Terminal_http of int
  | Accept_rejected_capability_mismatch
  | Accept_rejected_terminal
  | Cli_transport_required
  | Network_error
  | Provider_terminal

let classify_failure err = Oas_compat.Http_client.classify err

let should_cascade_to_next err = Oas_compat.Http_client.should_cascade err

(* ── Local provider detection ──────────────────────────── *)

let is_local_provider (cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.is_local cfg

(** Check whether a provider has credentials when required. *)
let has_required_api_key (cfg : Llm_provider.Provider_config.t) =
  cfg.api_key <> "" || is_local_provider cfg

(* ── Discovery-aware health filtering ──────────────────── *)

(** Internal: filter healthy + return discovery statuses for throttle. *)
let filter_healthy_internal ~sw ~net (providers : Llm_provider.Provider_config.t list) =
  let initial_count = List.length providers in
  (* Step 0: Remove cloud providers missing required API keys *)
  let providers =
    let with_keys = List.filter has_required_api_key providers in
    if with_keys = [] then providers  (* keep all rather than empty *)
    else begin
      let dropped = initial_count - List.length with_keys in
      if dropped > 0 then
        Llm_provider.Diag.debug "cascade_health_filter" "dropped %d provider(s) missing API keys"
          dropped;
      with_keys
    end
  in
  let local_providers =
    List.filter is_local_provider providers
  in
  let cloud_providers =
    List.filter (fun cfg -> not (is_local_provider cfg)) providers
  in
  if local_providers = [] then
    (providers, [])
  else
    let endpoints =
      local_providers
      |> List.map (fun (cfg : Llm_provider.Provider_config.t) -> cfg.base_url)
      |> List.sort_uniq String.compare
    in
    (* Use refresh_and_sync instead of discover so that the shared
       model_endpoints index is populated. Without this, endpoint_for_model
       always returns None and model-specific routing in
       make_registry_config falls back to round-robin. See #677. *)
    let statuses = Llm_provider.Discovery.refresh_and_sync ~sw ~net ~endpoints in
    if cloud_providers = [] then
      (providers, statuses)
    else
      let any_healthy =
        List.exists (fun (s : Llm_provider.Discovery.endpoint_status) -> s.healthy) statuses
      in
      if any_healthy then
        (providers, statuses)
      else begin
        Llm_provider.Diag.info "cascade_health_filter"
          "all %d local endpoint(s) unhealthy, falling back to %d cloud provider(s)"
          (List.length local_providers) (List.length cloud_providers);
        (cloud_providers, [])
      end

let filter_healthy ~sw ~net providers =
  fst (filter_healthy_internal ~sw ~net providers)

(* ── Inline tests ──────────────────────────────────────── *)
