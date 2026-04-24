type candidate_probe_status =
  | Probe_ok
  | Probe_skipped of string
  | Probe_error of string

let probe_timeout_sec = 5.0

type candidate_probe = {
  model_string : string;
  provider_kind : string;
  model_id : string;
  base_url : string;
  status : candidate_probe_status;
}

type profile_snapshot = {
  name : string;
  weighted_entries : Cascade_config_loader.weighted_entry list;
  inference_params : Cascade_config_loader.inference_params;
  api_key_env_overrides : (string * string) list;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  probes : candidate_probe list;
}

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

type candidate_runtime = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

type profile_build = {
  name : string;
  weighted_entries : Cascade_config_loader.weighted_entry list;
  inference_params : Cascade_config_loader.inference_params;
  api_key_env_overrides : (string * string) list;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  candidates : candidate_runtime list;
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
  let profiles =
    profile_names
    |> List.sort_uniq String.compare
    |> List.map (fun name ->
           {
             name;
             weighted_entries = [];
             inference_params = { temperature = None; max_tokens = None;
                                  keep_alive = None; num_ctx = None };
             api_key_env_overrides = [];
             strategy = Cascade_strategy.failover;
             ollama_max_concurrent = None;
             cli_max_concurrent = None;
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
             | `List _ when Base.String.is_suffix ~suffix:"_models" key ->
                 let suffix_len = String.length "_models" in
                 Some (String.sub key 0 (String.length key - suffix_len))
             | _ -> None)
      |> List.sort_uniq String.compare
  | _ -> []

let float_opt_to_json = function
  | Some value -> `Float value
  | None -> `Null

let int_opt_to_json = function
  | Some value -> `Int value
  | None -> `Null

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
        | Probe_error message ->
            `String "error" );
      ( "error",
        match probe.status with
        | Probe_ok -> `Null
        | Probe_skipped message -> `String message
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
    (Keeper_cascade_profile.known_cascades
    @ keepers_from_catalog
    @ [ "governance_judge"; "operator_judge" ])

let runtime_required_profile_names ?config_path () =
  let config_path =
    match config_path with
    | Some path -> path
    | None -> (
        match config_path_opt () with
        | Some path -> path
        | None -> "")
  in
  if String.equal config_path "" then
    Keeper_cascade_profile.known_cascades
    @ [ "governance_judge"; "operator_judge" ]
    |> List.sort_uniq String.compare
  else
    runtime_required_profiles ~config_path

let validate_path_result ~config_path =
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
        let top_errors =
          let base =
            if profiles = [] then
              [ "active cascade catalog has no <name>_models profiles" ]
            else
              []
          in
          if List.mem Keeper_config.default_cascade_name profiles then
            base
          else
            base
            @
            [
              Printf.sprintf
                "required default profile %S is missing"
                Keeper_config.default_cascade_name;
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
          let profile_snapshots =
            List.map
              (fun (profile : profile_build) ->
                {
                  name = profile.name;
                  weighted_entries = profile.weighted_entries;
                  inference_params = profile.inference_params;
                  api_key_env_overrides = profile.api_key_env_overrides;
                  strategy = profile.strategy;
                  ollama_max_concurrent = profile.ollama_max_concurrent;
                  cli_max_concurrent = profile.cli_max_concurrent;
                  probes =
                    List.map
                      (fun (candidate : candidate_runtime) ->
                        candidate_probe_skipped candidate
                          "runtime provider health is advisory; bootstrap skips live probe")
                      profile.candidates;
                })
              built_profiles
          in
          let rejected_profiles = statically_rejected_profiles in
          let default_profile_validated =
            List.exists
              (fun (profile : profile_snapshot) ->
                String.equal profile.name Keeper_config.default_cascade_name)
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
                          Keeper_config.default_cascade_name;
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
  let (_ : Eio.Switch.t option) = sw in
  let (_ : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option) = net in
  let (_ : float Eio.Time.clock_ty Eio.Resource.t option) = clock in
  match validate_path_result ~config_path with
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
          match validate_path_result ~config_path with
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
  let normalized = normalize_declared_name raw_name in
  match require_snapshot ?sw ?net ?clock () with
  | Error _ as e -> e
  | Ok snapshot -> (
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
      let providers =
        Cascade_config.order_weighted_entries
          ~rotation_scope:normalized
          profile.weighted_entries
        |> Cascade_config.parse_weighted_entries
             ~api_key_env_overrides:profile.api_key_env_overrides
             ~cascade_name:normalized
        |> Cascade_config.apply_provider_filter
             ~provider_filter
             ~label:normalized
      in
      let providers =
        Provider_tool_support.apply_required_tool_use_filter
          ?runtime_mcp_policy
          ~require_tool_choice_support ~require_tool_support
          ~label:normalized providers
      in
      if providers = [] then
        Error
          (Printf.sprintf
             "cascade %s resolved to no callable providers"
             normalized)
      else (
        (* Observability for cascade-name -> runtime-provider divergence.
           If the returned provider set ever disagrees with the declared
           weighted_entries of the profile (e.g. under snapshot staleness
           or cache leak across cascades), the mismatch shows up here.
           See memory/handoff-2026-04-24-masc-runtime-mcp-auth-resolved.md *)
        let declared =
          List.map
            (fun (e : Cascade_config_loader.weighted_entry) ->
              String.trim e.model)
            profile.weighted_entries
        in
        let returned =
          List.map
            (fun (c : Llm_provider.Provider_config.t) ->
              Printf.sprintf "%s:%s"
                (Llm_provider.Provider_config.string_of_provider_kind c.kind)
                (String.trim c.model_id))
            providers
        in
        let leaked =
          List.filter (fun m -> not (List.mem m declared)) returned
        in
        (if leaked <> [] then
           Log.warn ~ctx:"CascadeCatalog"
             "resolve_named_providers(%s): %d providers NOT in declared \
              profile (declared=[%s] returned=[%s] leaked=[%s])"
             normalized (List.length leaked)
             (String.concat ", " declared)
             (String.concat ", " returned)
             (String.concat ", " leaked)
         else
           Log.debug ~ctx:"CascadeCatalog"
             "resolve_named_providers(%s) -> [%s]" normalized
             (String.concat ", " returned));
        Ok providers)

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
