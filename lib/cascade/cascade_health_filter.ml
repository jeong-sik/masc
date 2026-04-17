(** Cascade health filtering — classify errors and filter provider lists
    by local health discovery and API key presence.

    Extracted from cascade_config.ml for cohesion.

    @since 0.99.5 *)

(* ── Cascade-level error classification ────────────────── *)

(** Case-insensitive substring check. Scans at most [max_scan] bytes
    of [haystack] to avoid O(n*m) on very large error bodies. *)
let contains_ci ?(max_scan = 512) ~haystack ~needle () =
  let h = String.lowercase_ascii
    (if String.length haystack > max_scan
     then String.sub haystack 0 max_scan else haystack)
  in
  let n = String.lowercase_ascii needle in
  let nlen = String.length n in
  let hlen = String.length h in
  if nlen = 0 || nlen > hlen then false
  else
    let rec scan i =
      if i > hlen - nlen then false
      else if String.sub h i nlen = n then true
      else scan (i + 1)
    in
    scan 0

(** Workaround for Ollama failing on large request bodies (~175KB+).
    Returns 400 with "can't find closing '}'". Root cause is oversized
    context — the proper fix is context compaction before sending to any
    provider. This cascade fallthrough is a temporary workaround so
    keeper turns are not blocked while compaction is implemented. *)
let is_provider_parse_error (body : string) : bool =
  contains_ci ~haystack:body ~needle:"can't find closing" ()

(** Decide whether an error should cascade to the next provider.
    Local resource exhaustion (port/FD limits) stops the cascade
    because every subsequent provider will hit the same bottleneck.
    Provider-specific error normalization (e.g. GLM quota → 429) is
    handled upstream in OAS backend modules, so cascade only needs
    to check HTTP codes, not body text. *)
let should_cascade_to_next err =
  if Llm_provider.Http_client.is_local_resource_exhaustion err then false
  else match err with
  | Llm_provider.Http_client.HttpError { code; body }
    when List.mem code [400; 422]
         && (Llm_provider.Retry.is_context_overflow_message body
             || is_provider_parse_error body) ->
    true
  | Llm_provider.Http_client.HttpError { code; _ } ->
    List.mem code Llm_provider.Constants.Http.cascadable_codes
  | Llm_provider.Http_client.AcceptRejected _ -> false
  | Llm_provider.Http_client.CliTransportRequired _ -> true
  | Llm_provider.Http_client.NetworkError _ -> true

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
