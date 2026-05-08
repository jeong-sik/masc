type candidate_probe_status =
  | Probe_ok
  | Probe_skipped of string
  | Probe_not_applicable of string
  | Probe_error of string

let probe_timeout_sec = 5.0

type candidate_probe = {
  model_string : string;
  provider_kind : string;
  model_id : string;
  base_url : string;
  status : candidate_probe_status;
}

type candidate_runtime = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

(* [profile_build] is the validated profile shape. Provider liveness remains
   advisory and never rejects a catalog, but the runtime snapshot carries the
   latest probe evidence observed during validation. *)
type profile_build = {
  name : string;
  weighted_entries : Cascade_config_loader.weighted_entry list;
  inference_params : Cascade_config_loader.inference_params;
  api_key_env_overrides : (string * string) list;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  candidates : candidate_runtime list;
  probes : candidate_probe list;
}

type profile_snapshot = profile_build

type snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile_snapshot list;
}

type profile_rejection = {
  name : string;
  errors : string list;
  probes : candidate_probe list;
}

type rejection = {
  source_path : string;
  attempted_mtime : float option;
  checked_at : float;
  errors : string list;
  profiles : profile_rejection list;
}

type state =
  | Validated of snapshot
  | Validated_with_rejections of {
      snapshot : snapshot;
      rejected_update : rejection;
    }
  | Serving_last_known_good of {
      snapshot : snapshot;
      rejected_update : rejection;
    }

type validation_result = {
  snapshot : snapshot;
  rejected_update : rejection option;
}

type cache = {
  active_snapshot : snapshot option;
  rejected_update : rejection option;
}

let cache = ref { active_snapshot = None; rejected_update = None }
let cache_mu = Mutex.create ()

let with_cache_lock f =
  Mutex.lock cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock cache_mu) f

let reset_cache_for_tests () =
  with_cache_lock (fun () -> cache := { active_snapshot = None; rejected_update = None })

let invalidate_path config_path =
  let keep_snapshot = function
    | Some (snapshot : snapshot) when String.equal snapshot.source_path config_path -> None
    | other -> other
  in
  let keep_rejection = function
    | Some (rejection : rejection) when String.equal rejection.source_path config_path -> None
    | other -> other
  in
  with_cache_lock (fun () ->
      let current = !cache in
      cache :=
        {
          active_snapshot = keep_snapshot current.active_snapshot;
          rejected_update = keep_rejection current.rejected_update;
        })

let install_snapshot_for_tests ~source_path ~profile_names =
  let mtime =
    try (Unix.stat source_path).Unix.st_mtime with
    | Unix.Unix_error _ | Sys_error _ -> 0.0
  in
  let profiles : profile_snapshot list =
    profile_names
    |> List.sort_uniq String.compare
    |> List.map (fun name ->
           {
             name;
             weighted_entries = [];
             inference_params = { temperature = None; max_tokens = None;
                                  keep_alive = None; num_ctx = None;
                                  thinking_enabled = None; thinking_budget = None };
             api_key_env_overrides = [];
             strategy = Cascade_strategy.failover;
             ollama_max_concurrent = None;
             cli_max_concurrent = None;
             candidates = [];
             probes = [];
           })
  in
  let snapshot =
    {
      source_path;
      mtime;
      validated_at = Unix.gettimeofday ();
      profiles;
    }
  in
  with_cache_lock (fun () ->
      cache :=
        {
          active_snapshot = Some snapshot;
          rejected_update = None;
        })

let discover_profiles = function
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (key, value) ->
             match value with
             | `List _ when String.ends_with ~suffix:"_models" key ->
                 let suffix_len = String.length "_models" in
                 let profile =
                   String.sub key 0 (String.length key - suffix_len)
                 in
                 if
                   Cascade_config_loader.is_deprecated_logical_profile_name
                     profile
                 then None
                 else Some profile
             | _ -> None)
      |> List.sort_uniq String.compare
  | _ -> []

let float_opt_to_json = function
  | Some value -> `Float value
  | None -> `Null

let int_opt_to_json = function
  | Some value -> `Int value
  | None -> `Null

let provider_kind_string (cfg : Llm_provider.Provider_config.t) =
  Llm_provider.Provider_config.string_of_provider_kind cfg.kind

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
        candidate_probe_error candidate local_probe_unavailable_reason
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
      if not (Llm_provider.Provider_config.is_local candidate.provider_cfg) then
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
        |> List.concat_map (fun (profile : profile_snapshot) -> profile.candidates)
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
        | _ :: _ -> Llm_provider.Discovery.refresh_and_sync ~sw ~net ~endpoints
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
           | Probe_not_applicable _ | Probe_ok | Probe_error _ -> ());
          Prometheus.set_gauge
            Prometheus.metric_provider_actual_health_status
            ~labels:
              [
                ("provider_name", probe.provider_kind);
                ("profile_name", profile.name);
                ("model_id", probe.model_id);
              ]
            (probe_health_value probe.status))
        profile.probes)
    profiles

let candidate_probe_to_yojson (probe : candidate_probe) =
  `Assoc
    [
      ("model_string", `String probe.model_string);
      ("provider_kind", `String probe.provider_kind);
      ("model_id", `String probe.model_id);
      ("base_url", `String probe.base_url);
      ( "status",
        match probe.status with
        | Probe_ok -> `String "ok"
        | Probe_skipped _ -> `String "skipped"
        | Probe_not_applicable _ -> `String "not_applicable"
        | Probe_error _ -> `String "error" );
      ( "error",
        match probe.status with
        | Probe_ok -> `Null
        | Probe_skipped message -> `String message
        | Probe_not_applicable message -> `String message
        | Probe_error message -> `String message );
    ]

let profile_snapshot_to_yojson (profile : profile_snapshot) =
  `Assoc
    [
      ("name", `String profile.name);
      ("strategy", `String (Cascade_strategy.kind_to_string profile.strategy.kind));
      ( "ollama_max_concurrent",
        int_opt_to_json profile.ollama_max_concurrent );
      ("cli_max_concurrent", int_opt_to_json profile.cli_max_concurrent);
      ( "candidates",
        `List (List.map candidate_probe_to_yojson profile.probes) );
    ]

let snapshot_to_yojson (snapshot : snapshot) =
  `Assoc
    [
      ("source_path", `String snapshot.source_path);
      ("source_mtime", `Float snapshot.mtime);
      ("validated_at", `Float snapshot.validated_at);
      ("profile_count", `Int (List.length snapshot.profiles));
      ( "profiles",
        `List (List.map profile_snapshot_to_yojson snapshot.profiles) );
    ]

let profile_rejection_to_yojson (profile : profile_rejection) =
  `Assoc
    [
      ("name", `String profile.name);
      ("errors", `List (List.map (fun value -> `String value) profile.errors));
      ("candidates", `List (List.map candidate_probe_to_yojson profile.probes));
    ]

let rejection_to_yojson (rejection : rejection) =
  `Assoc
    [
      ("source_path", `String rejection.source_path);
      ("attempted_mtime", float_opt_to_json rejection.attempted_mtime);
      ("checked_at", `Float rejection.checked_at);
      ("errors", `List (List.map (fun value -> `String value) rejection.errors));
      ( "profiles",
        `List (List.map profile_rejection_to_yojson rejection.profiles) );
    ]

let state_to_yojson = function
  | Validated snapshot ->
      `Assoc
        [
          ("status", `String "validated");
          ("serving_last_known_good", `Bool false);
          ("snapshot", snapshot_to_yojson snapshot);
          ("rejected_update", `Null);
        ]
  | Validated_with_rejections { snapshot; rejected_update } ->
      `Assoc
        [
          ("status", `String "validated");
          ("serving_last_known_good", `Bool false);
          ("snapshot", snapshot_to_yojson snapshot);
          ("rejected_update", rejection_to_yojson rejected_update);
        ]
  | Serving_last_known_good { snapshot; rejected_update } ->
      `Assoc
        [
          ("status", `String "serving_last_known_good");
          ("serving_last_known_good", `Bool true);
          ("snapshot", snapshot_to_yojson snapshot);
          ("rejected_update", rejection_to_yojson rejected_update);
        ]

let config_path_opt () =
  Config_dir_resolver.log_warnings ~context:"CascadeCatalogRuntime" ();
  Config_dir_resolver.cascade_path_opt ()

let candidate_key_of_cfg (cfg : Llm_provider.Provider_config.t) =
  Hashtbl.hash
    ( Llm_provider.Provider_config.string_of_provider_kind cfg.kind,
      cfg.model_id,
      cfg.base_url,
      cfg.request_path,
      cfg.api_key,
      cfg.headers,
      cfg.supports_tool_choice_override )

let expand_weighted_entries
    (entries : Cascade_config_loader.weighted_entry list)
    : Cascade_config_loader.weighted_entry list =
  List.concat_map
    (fun (entry : Cascade_config_loader.weighted_entry) ->
      Cascade_config.expand_auto_models [ entry.model ]
      |> List.map (fun model -> { entry with model }))
    entries

let profile_lookup profiles name =
  List.find_opt (fun (profile : profile_snapshot) -> String.equal profile.name name) profiles

let profile_names_of_snapshot (snapshot : snapshot) =
  List.map (fun (profile : profile_snapshot) -> profile.name) snapshot.profiles

let eio_caps ?sw ?net ?clock () =
  let sw =
    match sw with
    | Some value -> Some value
    | None -> Eio_context.get_switch_opt ()
  in
  let net =
    match net with
    | Some value -> Some value
    | None -> Eio_context.get_net_opt ()
  in
  let clock =
    match clock with
    | Some value -> Some value
    | None -> (
        match Masc_eio_env.get_opt () with
        | Some env -> env.clock
        | None -> Eio_context.get_clock_opt ())
  in
  match sw, net, clock with
  | Some sw, Some net, Some clock -> Ok (sw, net, clock)
  | _ ->
      Error
        "catalog validation requires Eio switch/net/clock capabilities"

let validate_strategy ~config_path ~name =
  let cfg =
    Cascade_config_loader.resolve_strategy_config ~config_path ~name
  in
  let strategy_errors =
    match cfg.kind with
    | None -> []
    | Some raw_kind -> (
        match Cascade_strategy.parse_kind raw_kind with
        | Error msg ->
            [
              Printf.sprintf
                "unknown strategy %S: %s"
                raw_kind msg;
            ]
        | Ok Cascade_strategy.Priority_tier -> (
            match cfg.tiers with
            | None ->
                [
                  "priority_tier requires a non-empty <name>_tiers configuration";
                ]
            | Some raw_tiers -> (
                match Cascade_config.normalize_priority_tiers ~config_path ~name raw_tiers with
                | Ok _ -> []
                | Error msg ->
                    [
                      Printf.sprintf
                        "priority_tier normalization failed: %s"
                        msg;
                    ]))
        | Ok _ -> [])
  in
  if strategy_errors <> [] then
    Error strategy_errors
  else
    Ok
      ( Cascade_config.resolve_strategy ~config_path ~name (),
        Cascade_config.resolve_ollama_max_concurrent ~config_path ~name (),
        Cascade_config.resolve_cli_max_concurrent ~config_path ~name () )

let rejection_of_path ~config_path ~attempted_mtime ~checked_at
    ~(errors : string list) ~(profiles : profile_rejection list) =
  { source_path = config_path; attempted_mtime; checked_at; errors; profiles }

let active_source_state ~config_path =
  Cascade_toml_materializer.source_state ~config_path

let validate_profile_static ~config_path name : (profile_build, profile_rejection) result =
  let weighted_entries =
    Cascade_config_loader.load_profile_weighted ~config_path ~name
  in
  if weighted_entries = [] then
    Error
      {
        name;
        errors = [ "profile has no non-empty configured candidates" ];
        probes = [];
      }
  else
    let inference_params =
      Cascade_config_loader.resolve_inference_params ~config_path ~name
    in
    let api_key_env_overrides =
      Cascade_config_loader.resolve_api_key_env ~config_path ~name
    in
    match validate_strategy ~config_path ~name with
    | Error errors -> Error { name; errors; probes = [] }
    | Ok (strategy, ollama_max_concurrent, cli_max_concurrent) ->
        let expanded_entries = expand_weighted_entries weighted_entries in
        let candidates, candidate_errors =
          List.fold_left
            (fun (ok_acc, err_acc) (entry : Cascade_config_loader.weighted_entry) ->
              match
                Cascade_config.parse_weighted_entry_diag
                  ~api_key_env_overrides
                  ?keep_alive:inference_params.keep_alive
                  ?num_ctx:inference_params.num_ctx
                  entry
              with
              | Ok provider_cfg ->
                  ({ model_string = entry.model; provider_cfg } :: ok_acc, err_acc)
              | Error
                  (Cascade_config.Drop_unregistered_scheme { model; scheme }) ->
                  ( ok_acc,
                    Printf.sprintf
                      "candidate %S uses unregistered provider scheme %S"
                      model scheme
                    :: err_acc )
              | Error
                  (Cascade_config.Drop_unavailable_scheme { model; scheme }) ->
                  ( ok_acc,
                    Printf.sprintf
                      "candidate %S uses unavailable provider scheme %S \
                       (missing credential or disabled runtime lane)"
                      model scheme
                    :: err_acc )
              | Error (Cascade_config.Drop_invalid_syntax model) ->
                  ( ok_acc,
                    Printf.sprintf
                      "candidate %S has invalid provider:model syntax"
                      model
                    :: err_acc ))
            ([], [])
            expanded_entries
        in
        let candidates = List.rev candidates in
        let candidate_errors = List.rev candidate_errors in
        if candidate_errors <> [] then
          Error
            {
              name;
              errors = candidate_errors;
              probes = [];
            }
        else
          Ok
            {
              name;
              weighted_entries;
              inference_params;
              api_key_env_overrides;
              strategy;
              ollama_max_concurrent;
              cli_max_concurrent;
              candidates;
              probes = profile_probes candidates;
            }

let runtime_required_profiles ~config_path =
  let keepers_from_catalog =
    match Cascade_config_loader.load_catalog ~config_path with
    | Ok entries ->
        List.filter_map
          (fun (entry : Cascade_config_loader.catalog_entry) ->
            if entry.keeper_assignable then Some entry.name else None)
          entries
    | Error _ -> []
  in
  List.sort_uniq String.compare
    (keepers_from_catalog
     @ Cascade_routes.configured_route_targets ~config_path ())

let runtime_required_profile_names ?config_path () =
  let config_path =
    match config_path with
    | Some path -> path
    | None -> (
        match config_path_opt () with
        | Some path -> path
        | None -> "")
  in
  if String.equal config_path "" then []
  else runtime_required_profiles ~config_path

let validate_path_result ?sw ?net ~config_path () =
  let checked_at = Unix.gettimeofday () in
  let source_state = active_source_state ~config_path in
  let source_path = source_state.info.source_path in
  let attempted_mtime = source_state.source_mtime in
  if not source_state.source_exists then
    Error
      (rejection_of_path ~config_path:source_path ~attempted_mtime ~checked_at
         ~errors:[ Printf.sprintf "active cascade source is missing: %s" source_path ]
         ~profiles:[])
  else
    match Cascade_config_loader.load_json config_path with
    | Error msg ->
        Error
          (rejection_of_path ~config_path:source_path ~attempted_mtime ~checked_at
             ~errors:
               [
                 Printf.sprintf
                   "active cascade source could not be loaded: %s"
                   msg;
               ]
             ~profiles:[])
    | Ok json ->
        let profiles = discover_profiles json in
        let required_default_profile =
          Cascade_routes.cascade_name_for_use
            ~config_path
            Cascade_routes.Keeper_turn
        in
        let route_target_errors =
          Cascade_routes.configured_route_targets ~config_path ()
          |> List.filter_map (fun target ->
                 if List.mem target profiles then None
                 else
                   Some
                     (Printf.sprintf
                        "cascade route targets missing profile %S"
                        target))
        in
        let route_key_errors =
          Cascade_routes.configured_unknown_route_keys ~config_path ()
          |> List.map (fun key ->
                 Printf.sprintf "unknown cascade route key %S" key)
        in
        let top_errors =
          let base =
            if profiles = [] then
              [ "active cascade catalog has no <name>_models profiles" ]
            else
              []
          in
          let base = base @ route_key_errors @ route_target_errors in
          if List.mem required_default_profile profiles then base
          else
            base
            @
            [
              Printf.sprintf
                "required default profile %S is missing"
                required_default_profile;
            ]
        in
        let built_profiles, statically_rejected_profiles =
          List.fold_left
            (fun (ok_acc, err_acc) name ->
              match validate_profile_static ~config_path name with
              | Ok profile -> (profile :: ok_acc, err_acc)
              | Error rejection -> (ok_acc, rejection :: err_acc))
            ([], [])
            profiles
        in
        let built_profiles = List.rev built_profiles in
        let statically_rejected_profiles = List.rev statically_rejected_profiles in
        if top_errors <> [] || built_profiles = [] then
          Error
            (rejection_of_path ~config_path:source_path ~attempted_mtime
               ~checked_at
               ~errors:top_errors ~profiles:statically_rejected_profiles)
        else
          let profile_snapshots : profile_snapshot list =
            attach_probe_results ?sw ?net built_profiles
          in
          let rejected_profiles = statically_rejected_profiles in
          let default_profile_validated =
            List.exists
              (fun (profile : profile_snapshot) ->
                String.equal profile.name required_default_profile)
              profile_snapshots
          in
          let snapshot =
            {
              source_path;
              mtime = Option.value attempted_mtime ~default:0.0;
              validated_at = checked_at;
              profiles = profile_snapshots;
            }
          in
          record_probe_metrics profile_snapshots;
          if rejected_profiles = [] then
            Ok { snapshot; rejected_update = None }
          else
            let rejection =
              rejection_of_path ~config_path:source_path ~attempted_mtime
                ~checked_at
                ~errors:
                  ((if default_profile_validated then
                      []
                    else
                      [
                        Printf.sprintf
                          "required default profile %S failed validation"
                          required_default_profile;
                      ])
                   @
                   [
                     Printf.sprintf
                       "catalog validation rejected %d/%d profile(s)"
                       (List.length rejected_profiles)
                       (List.length profiles);
                   ])
                ~profiles:rejected_profiles
            in
            if profile_snapshots = [] || not default_profile_validated then
              Error rejection
            else
              Ok { snapshot; rejected_update = Some rejection }

let validate_path ?sw ?net ?clock ~config_path () =
  let (_ : float Eio.Time.clock_ty Eio.Resource.t option) = clock in
  match validate_path_result ?sw ?net ~config_path () with
  | Ok result -> Ok result.snapshot
  | Error _ as e -> e

let same_snapshot_key (snapshot : snapshot) ~path ~mtime =
  String.equal snapshot.source_path path && Float.equal snapshot.mtime mtime

let same_rejection_key (rejection : rejection) ~path ~mtime =
  String.equal rejection.source_path path
  &&
  match rejection.attempted_mtime with
  | Some rejection_mtime -> Float.equal rejection_mtime mtime
  | None -> false

let inspect_active ?sw ?net ?clock () =
  match config_path_opt () with
  | None ->
      let checked_at = Unix.gettimeofday () in
      let rejection =
        {
          source_path = "(unresolved)";
          attempted_mtime = None;
          checked_at;
          errors = [ "active cascade catalog path could not be resolved" ];
          profiles = [];
        }
      in
      (match with_cache_lock (fun () -> !cache.active_snapshot) with
       | Some snapshot ->
           with_cache_lock (fun () ->
               cache :=
                 {
                   active_snapshot = Some snapshot;
                   rejected_update = Some rejection;
                 });
           Ok (Serving_last_known_good { snapshot; rejected_update = rejection })
       | None -> Error rejection)
  | Some config_path ->
      let source_state = active_source_state ~config_path in
      let source_path = source_state.info.source_path in
      let current_mtime = source_state.source_mtime in
      let cached_result =
        with_cache_lock (fun () ->
            match !cache.active_snapshot, !cache.rejected_update, current_mtime with
            | Some snapshot, Some rejection, Some mtime
              when same_snapshot_key snapshot ~path:source_path ~mtime
                   && same_rejection_key rejection ~path:source_path ~mtime ->
                Some
                  (Ok
                     (Validated_with_rejections
                        { snapshot; rejected_update = rejection }))
            | Some snapshot, _, Some mtime
              when same_snapshot_key snapshot ~path:source_path ~mtime ->
                Some (Ok (Validated snapshot))
            | Some snapshot, Some rejection, Some mtime
              when same_rejection_key rejection ~path:source_path ~mtime ->
                Some (Ok (Serving_last_known_good { snapshot; rejected_update = rejection }))
            | None, Some rejection, Some mtime
              when same_rejection_key rejection ~path:source_path ~mtime ->
                Some (Error rejection)
            | _ -> None)
      in
      match cached_result with
      | Some result -> result
      | None -> (
          match validate_path_result ?sw ?net ~config_path () with
          | Ok { snapshot; rejected_update = None } ->
              with_cache_lock (fun () ->
                  cache :=
                    {
                      active_snapshot = Some snapshot;
                      rejected_update = None;
                    });
              Ok (Validated snapshot)
          | Ok { snapshot; rejected_update = Some rejection } ->
              with_cache_lock (fun () ->
                  cache :=
                    {
                      active_snapshot = Some snapshot;
                      rejected_update = Some rejection;
                    });
              Ok
                (Validated_with_rejections
                   { snapshot; rejected_update = rejection })
          | Error rejection ->
              (match with_cache_lock (fun () -> !cache.active_snapshot) with
               | Some snapshot ->
                   with_cache_lock (fun () ->
                       cache :=
                         {
                           active_snapshot = Some snapshot;
                           rejected_update = Some rejection;
                         });
                   Ok
                     (Serving_last_known_good
                        { snapshot; rejected_update = rejection })
               | None ->
                   with_cache_lock (fun () ->
                       cache :=
                         {
                           active_snapshot = None;
                           rejected_update = Some rejection;
                         });
                   Error rejection))

let require_snapshot ?sw ?net ?clock () =
  match inspect_active ?sw ?net ?clock () with
  | Ok (Validated snapshot) -> Ok snapshot
  | Ok (Validated_with_rejections { snapshot; _ }) -> Ok snapshot
  | Ok (Serving_last_known_good { snapshot; _ }) -> Ok snapshot
  | Error rejection ->
      let detail =
        if rejection.errors = [] then
          "active catalog validation failed"
        else
          String.concat "; " rejection.errors
      in
      Error detail

let normalize_declared_name raw =
  Keeper_cascade_profile.normalize_declared_name raw

let lookup_active_profile ?sw ?net ?clock raw_name =
  match require_snapshot ?sw ?net ?clock () with
  | Error _ as e -> e
  | Ok snapshot -> (
      let trimmed = String.trim raw_name in
      let normalized =
        if (not (String.equal trimmed ""))
           && Option.is_some (profile_lookup snapshot.profiles trimmed)
        then trimmed
        else normalize_declared_name raw_name
      in
      match profile_lookup snapshot.profiles normalized with
      | Some profile -> Ok (snapshot, normalized, profile)
      | None ->
          let known = profile_names_of_snapshot snapshot |> String.concat ", " in
          Error
            (Printf.sprintf
               "unknown cascade_name %S (active profiles: %s)"
               normalized known))

let resolve_declared_name ?sw ?net ?clock ~raw_name () =
  match lookup_active_profile ?sw ?net ?clock raw_name with
  | Ok (_snapshot, normalized, _profile) -> Ok normalized
  | Error _ as e -> e

let models_of_cascade_name ?sw ?net ?clock raw_name =
  match lookup_active_profile ?sw ?net ?clock raw_name with
  | Error _ as e -> e
  | Ok (_snapshot, _normalized, profile) ->
      Ok
        (expand_weighted_entries profile.weighted_entries
         |> List.map (fun (entry : Cascade_config_loader.weighted_entry) ->
                entry.model))

let resolve_named_providers ?sw ?net ?clock ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy ~cascade_name () =
  match lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ as e -> e
  | Ok (_snapshot, normalized, profile) ->
      let provider_label (c : Llm_provider.Provider_config.t) =
        Printf.sprintf "%s:%s"
          (Llm_provider.Provider_config.string_of_provider_kind c.kind)
          (String.trim c.model_id)
      in
      let ordered_entries =
        Cascade_config.order_weighted_entries
          ~rotation_scope:normalized
          profile.weighted_entries
      in
      let parsed_declared_providers =
        Cascade_config.parse_weighted_entries
             ~api_key_env_overrides:profile.api_key_env_overrides
             ~cascade_name:normalized
          ordered_entries
      in
      let filtered_declared_providers =
        Cascade_config.apply_provider_filter
             ~provider_filter
             ~label:normalized
          parsed_declared_providers
      in
      let providers =
        Provider_tool_support.apply_required_tool_use_filter
          ?runtime_mcp_policy
          ~require_tool_choice_support ~require_tool_support
          ~label:normalized filtered_declared_providers
      in
      if providers = [] then
        Error
          (Printf.sprintf
             "cascade %s resolved to no callable providers"
             normalized)
      else (
        (* Observability for cascade-name -> runtime-provider divergence.  Compare
           against the profile after provider:auto expansion, canonical provider
           parsing, and provider_filter fallback.  The raw declared strings can
           be aliases such as [codex_cli:auto] or [custom:model@url], while
           Provider_config carries concrete/canonical labels.
           See memory/handoff-2026-04-24-masc-runtime-mcp-auth-resolved.md *)
        let declared =
          List.map provider_label filtered_declared_providers
        in
        let returned = List.map provider_label providers in
        let leaked =
          List.filter (fun m -> not (List.mem m declared)) returned
        in
        (if leaked <> [] then
           Log.warn ~ctx:"CascadeCatalog"
             "resolve_named_providers(%s): %d providers NOT in parsed declared \
              profile (parsed_declared=[%s] returned=[%s] leaked=[%s])"
             normalized (List.length leaked)
             (String.concat ", " declared)
             (String.concat ", " returned)
             (String.concat ", " leaked)
         else
           Log.debug ~ctx:"CascadeCatalog"
             "resolve_named_providers(%s) -> [%s]" normalized
             (String.concat ", " returned));
        Ok providers)

let resolve_named_providers_strict ?sw ?net ?clock ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy ~cascade_name () =
  match lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ as e -> e
  | Ok (_snapshot, normalized, profile) ->
      let ordered_entries =
        Cascade_config.order_weighted_entries
          ~rotation_scope:normalized
          profile.weighted_entries
      in
      let parsed_declared_providers =
        Cascade_config.parse_weighted_entries
             ~api_key_env_overrides:profile.api_key_env_overrides
             ~cascade_name:normalized
          ordered_entries
      in
      let filtered_declared_providers =
        match Cascade_config.apply_provider_filter_strict
                ~provider_filter ~label:normalized parsed_declared_providers with
        | Error rejection ->
            Error (Cascade_config.provider_filter_rejection_to_string rejection)
        | Ok ps -> Ok ps
      in
      (match filtered_declared_providers with
       | Error _ as e -> e
       | Ok filtered ->
       let providers =
         Provider_tool_support.apply_required_tool_use_filter
           ?runtime_mcp_policy
           ~require_tool_choice_support ~require_tool_support
           ~label:normalized filtered
       in
       if providers = [] then
         Error
           (Printf.sprintf
              "cascade %s resolved to no callable providers"
              normalized)
       else Ok providers)

type secondary_resolution = {
  providers : Llm_provider.Provider_config.t list;
  secondary_resolver :
    int -> Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t option;
}

let provider_filter_allows_single ~provider_filter ~label provider =
  match provider_filter with
  | None | Some [] -> true
  | Some _ ->
      match
        Cascade_config.apply_provider_filter_strict
          ~provider_filter ~label [ provider ]
      with
      | Ok [ _ ] -> true
      | Ok _ | Error _ -> false

let parse_secondary_from_entry ~api_key_env_overrides
    (entry : Cascade_config_loader.weighted_entry) =
  match entry.secondary with
  | None -> None
  | Some secondary ->
      let secondary_entry : Cascade_config_loader.weighted_entry =
        {
          model = secondary;
          weight = 1;
          supports_tool_choice = entry.secondary_supports_tool_choice;
          secondary = None;
          secondary_supports_tool_choice = None;
        }
      in
      Cascade_config.parse_weighted_entry
        ~api_key_env_overrides secondary_entry

let resolve_named_providers_strict_with_secondary_resolver ?sw ?net ?clock
    ?provider_filter ~cascade_name () =
  match lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ as e -> e
  | Ok (_snapshot, normalized, profile) ->
      let ordered_entries =
        Cascade_config.order_weighted_entries
          ~rotation_scope:normalized
          profile.weighted_entries
      in
      let parsed_pairs =
        ordered_entries
        |> List.filter_map
             (fun (entry : Cascade_config_loader.weighted_entry) ->
                match
                  Cascade_config.parse_weighted_entry
                    ~api_key_env_overrides:profile.api_key_env_overrides
                    entry
                with
                | None -> None
                | Some primary ->
                    Some
                      ( primary,
                        parse_secondary_from_entry
                          ~api_key_env_overrides:
                            profile.api_key_env_overrides
                          entry ))
      in
      let primaries = List.map fst parsed_pairs in
      (match
         Cascade_config.apply_provider_filter_strict
           ~provider_filter ~label:normalized primaries
       with
       | Error rejection ->
           Error (Cascade_config.provider_filter_rejection_to_string rejection)
       | Ok _filtered_primaries ->
           let provider_filter_allows =
             provider_filter_allows_single ~provider_filter ~label:normalized
           in
           let filtered_pairs =
             parsed_pairs
             |> List.filter (fun (primary, _) ->
                    provider_filter_allows primary)
             |> List.map (fun (primary, secondary) ->
                    let secondary =
                      match secondary with
                      | Some cfg when provider_filter_allows cfg -> Some cfg
                      | _ -> None
                    in
                    (primary, secondary))
           in
           let providers = List.map fst filtered_pairs in
           if providers = [] then
             Error
               (Printf.sprintf
                  "cascade %s resolved to no callable providers"
                  normalized)
           else
             let slots = Array.of_list filtered_pairs in
             let secondary_resolver provider_index primary =
               if provider_index < 0 || provider_index >= Array.length slots then
                 None
               else
                 let indexed_primary, secondary = slots.(provider_index) in
                 if candidate_key_of_cfg indexed_primary
                    = candidate_key_of_cfg primary
                 then secondary
                 else None
             in
             Ok { providers; secondary_resolver })

(** RFC-0027 PR-9b dual-track resolution. The [primary] argument is one
    of the providers returned by {!resolve_named_providers}; we walk the
    cascade's parsed weighted entries and, for the entry whose parsed
    {!Llm_provider.Provider_config.t} matches [primary] by [(kind,
    model_id)], read its [secondary] field. When present, the secondary
    string is wrapped in a synthesised {!Cascade_config_loader.weighted_entry}
    (preserving [secondary_supports_tool_choice] -> [supports_tool_choice]
    if set) and parsed via {!Cascade_config.parse_weighted_entry}, which
    applies the cascade's [api_key_env_overrides]. Returns [None] when:
    - the cascade has no entries with a secondary,
    - no entry's primary parse matches [primary],
    - or secondary parsing yields no provider (unregistered/unavailable
      scheme, invalid syntax).
    The function never raises; observability for swap success/failure
    flows through the unified
    [Llm_metric_bridge.emit_fallback_triggered ~kind:"dual_track_swap"]
    counter that the caller in [oas_worker_named_cascade] increments —
    successful swaps tag [~detail:"swapped"], secondary rejections tag
    [~detail:<filter_rejection_reason>]. (#13097 review: removed stale
    [cascade_secondary_swap_total] reference; that name was never
    registered, the unified counter is the SSOT.) *)
let resolve_secondary_provider_for_primary ?sw ?net ?clock
    ~cascade_name ~(primary : Llm_provider.Provider_config.t) () =
  match lookup_active_profile ?sw ?net ?clock cascade_name with
  | Error _ -> None
  | Ok (_snapshot, _normalized, profile) ->
      let same_kind_model
          (cfg : Llm_provider.Provider_config.t) =
        cfg.kind = primary.kind
        && String.trim cfg.model_id = String.trim primary.model_id
      in
      let synth_secondary_entry
          (entry : Cascade_config_loader.weighted_entry)
          (secondary : string) : Cascade_config_loader.weighted_entry =
        {
          model = secondary;
          weight = 1;
          supports_tool_choice = entry.secondary_supports_tool_choice;
          secondary = None;
          secondary_supports_tool_choice = None;
        }
      in
      let try_entry (entry : Cascade_config_loader.weighted_entry) =
        match entry.secondary with
        | None -> None
        | Some secondary ->
            (* Confirm this entry's primary parses to the same provider
               we were called with. We compare on the parsed
               Provider_config rather than on raw strings to handle
               provider:auto expansion (e.g. claude_code:auto could
               expand to several model strings, and the primary we got
               carries the resolved model_id). *)
            let primary_parsed =
              Cascade_config.parse_weighted_entry
                ~api_key_env_overrides:profile.api_key_env_overrides
                entry
            in
            (match primary_parsed with
             | Some parsed when same_kind_model parsed ->
                 Cascade_config.parse_weighted_entry
                   ~api_key_env_overrides:profile.api_key_env_overrides
                   (synth_secondary_entry entry secondary)
             | _ -> None)
      in
      (* Expand provider:auto entries without a rotation scope: this legacy
         lookup may be called after live provider resolution, so it must not
         consume round-robin state just to answer a secondary lookup. New
         execution paths use [resolve_named_providers_strict_with_secondary_resolver]
         to precompute secondaries from the same ordered snapshot. *)
      let expanded = expand_weighted_entries profile.weighted_entries in
      List.find_map try_entry expanded

let resolve_inference_params ?sw ?net ?clock ~name () =
  match lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.inference_params
  | Error _ as e -> e

let resolve_strategy ?sw ?net ?clock ~name () =
  match lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.strategy
  | Error _ as e -> e

let resolve_ollama_max_concurrent ?sw ?net ?clock ~name () =
  match lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.ollama_max_concurrent
  | Error _ as e -> e

let resolve_cli_max_concurrent ?sw ?net ?clock ~name () =
  match lookup_active_profile ?sw ?net ?clock name with
  | Ok (_snapshot, _normalized, profile) -> Ok profile.cli_max_concurrent
  | Error _ as e -> e

let known_profile_names ?sw ?net ?clock () =
  match require_snapshot ?sw ?net ?clock () with
  | Ok snapshot -> Ok (profile_names_of_snapshot snapshot)
  | Error _ as e -> e

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let invalid_profile_errors ?sw ?net ?clock () =
  let of_rejection rejection =
    rejection.profiles
    |> List.filter_map (fun (profile : profile_rejection) ->
           let errors = dedupe_keep_order profile.errors in
           if errors = [] then None else Some (profile.name, errors))
  in
  match inspect_active ?sw ?net ?clock () with
  | Ok (Validated _) -> []
  | Ok (Validated_with_rejections { rejected_update; _ })
  | Ok (Serving_last_known_good { rejected_update; _ })
  | Error rejected_update ->
      of_rejection rejected_update

let resolve_selection_trace ?sw ?net ?clock ~name () =
  match lookup_active_profile ?sw ?net ?clock name with
  | Error _ as e -> e
  | Ok (_snapshot, _normalized, profile) ->
      Ok
        (Cascade_config.selection_trace_of_weighted_entries
           ~source:Cascade_config.Named
           profile.weighted_entries)
