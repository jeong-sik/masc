(* Stage 08 — provider liveness probe helpers.  These construct
   [candidate_probe] records for each candidate in a profile and update
   the corresponding Prometheus counters/gauges.  Probe results are
   advisory: they never reject a validated catalog. *)

open Cascade_catalog_runtime_cache

let provider_kind_string (cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.string_of_provider_kind cfg.kind

(* External-observability labels.  The Runtime Lens redaction lives here
   (record_probe_metrics below); the boot-log JSON keeps real provider
   identity (see [Cascade_catalog_runtime_json]). *)
let public_runtime_provider_label = "runtime"
let public_runtime_model_label = "runtime"

let candidate_probe_error (candidate : candidate_runtime) message =
  {
    model_string = candidate.model_string;
    provider_kind = provider_kind_string candidate.provider_cfg;
    model_id = candidate.provider_cfg.model_id;
    base_url = candidate.provider_cfg.base_url;
    status = Probe_error message;
  }

let candidate_probe_ok (candidate : candidate_runtime) =
  {
    model_string = candidate.model_string;
    provider_kind = provider_kind_string candidate.provider_cfg;
    model_id = candidate.provider_cfg.model_id;
    base_url = candidate.provider_cfg.base_url;
    status = Probe_ok;
  }

let candidate_probe_skipped (candidate : candidate_runtime) reason =
  {
    model_string = candidate.model_string;
    provider_kind = provider_kind_string candidate.provider_cfg;
    model_id = candidate.provider_cfg.model_id;
    base_url = candidate.provider_cfg.base_url;
    status = Probe_skipped reason;
  }

let candidate_probe_not_applicable (candidate : candidate_runtime) reason =
  {
    model_string = candidate.model_string;
    provider_kind = provider_kind_string candidate.provider_cfg;
    model_id = candidate.provider_cfg.model_id;
    base_url = candidate.provider_cfg.base_url;
    status = Probe_not_applicable reason;
  }

let local_probe_unavailable_reason =
  "local provider health probe requires Eio runtime capabilities"

let cloud_probe_not_applicable_reason =
  "cloud provider live health is not an auth-free bootstrap probe; \
   credential/config validation is handled before execution"

let profile_probes (profile_candidates : candidate_runtime list) =
  List.map
    (fun candidate ->
      if Llm_provider.Provider_config.is_local candidate.provider_cfg then
        candidate_probe_skipped candidate local_probe_unavailable_reason
      else
        candidate_probe_not_applicable candidate
          cloud_probe_not_applicable_reason)
    profile_candidates

let normalize_endpoint_url url =
  let trimmed = String.trim url in
  let rec drop_trailing_slash s =
    let len = String.length s in
    if len > 0 && s.[len - 1] = '/' then
      drop_trailing_slash (String.sub s 0 (len - 1))
    else
      s
  in
  drop_trailing_slash trimmed

let endpoint_status_for_candidate statuses (candidate : candidate_runtime) =
  let target = normalize_endpoint_url candidate.provider_cfg.base_url in
  List.find_opt
    (fun (status : Llm_provider.Discovery.endpoint_status) ->
      String.equal target (normalize_endpoint_url status.url))
    statuses

let profile_probes_from_statuses statuses profile_candidates =
  List.map
    (fun (candidate : candidate_runtime) ->
      if not (Llm_provider.Provider_config.is_local candidate.provider_cfg)
      then
        candidate_probe_not_applicable candidate
          cloud_probe_not_applicable_reason
      else
        match endpoint_status_for_candidate statuses candidate with
        | Some status when status.healthy -> candidate_probe_ok candidate
        | Some status ->
            candidate_probe_error candidate
              (Printf.sprintf "local endpoint unhealthy: %s" status.url)
        | None ->
            candidate_probe_error candidate
              (Printf.sprintf "local endpoint was not probed: %s"
                 candidate.provider_cfg.base_url))
    profile_candidates

let attach_probe_results ?sw ?net (profiles : profile_snapshot list) =
  match sw, net with
  | Some sw, Some net ->
      let endpoints =
        profiles
        |> List.concat_map (fun (profile : profile_snapshot) ->
               profile.candidates)
        |> List.filter (fun (candidate : candidate_runtime) ->
               Llm_provider.Provider_config.is_local candidate.provider_cfg)
        |> List.map (fun (candidate : candidate_runtime) ->
               candidate.provider_cfg.base_url)
        |> List.map normalize_endpoint_url
        |> List.sort_uniq String.compare
      in
      let statuses =
        match endpoints with
        | [] -> []
        | _ :: _ ->
            Llm_provider.Discovery.refresh_and_sync ~sw ~net ~endpoints
      in
      List.map
        (fun (profile : profile_snapshot) ->
          {
            profile with
            probes = profile_probes_from_statuses statuses profile.candidates;
          })
        profiles
  | _ ->
      List.map
        (fun (profile : profile_snapshot) ->
          { profile with probes = profile_probes profile.candidates })
        profiles

let probe_health_value = function
  | Probe_skipped _ -> 0.0
  | Probe_not_applicable _ -> 0.0
  | Probe_ok -> 1.0
  | Probe_error _ -> 3.0

let record_probe_metrics (profiles : profile_snapshot list) =
  List.iter
    (fun (profile : profile_snapshot) ->
      List.iter
        (fun (probe : candidate_probe) ->
          (match probe.status with
           | Probe_skipped _ ->
               Prometheus.inc_counter
                 Prometheus.metric_provider_health_probe_skipped
                 ~labels:
                   [
                     ("provider_name", probe.provider_kind);
                     ("profile_name", profile.name);
                   ]
                 ()
           | Probe_error _ ->
               (* Counter complement to the per-probe gauge below.
                  The gauge only retains the LAST observed status,
                  so flapping or sustained probe failures were
                  invisible to operators; a [rate()] query over this
                  counter quantifies provider liveness churn. *)
               Prometheus.inc_counter
                 Prometheus.metric_provider_health_probe_error
                 ~labels:
                   [
                     ("provider_name", probe.provider_kind);
                     ("profile_name", profile.name);
                   ]
                 ()
           | Probe_not_applicable _ | Probe_ok -> ());
          Prometheus.set_gauge
            Prometheus.metric_provider_actual_health_status
            ~labels:
              [
                ("provider_name", public_runtime_provider_label);
                ("profile_name", profile.name);
                ("model_id", public_runtime_model_label);
              ]
            (probe_health_value probe.status))
        profile.probes)
    profiles
