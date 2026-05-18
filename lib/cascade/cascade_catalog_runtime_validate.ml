(* Stage 08 — declarative catalog loading + boot-time profile
   validation.  Produces a [validation_result] (snapshot + optional
   rejection) or a fatal [rejection] from a [cascade.toml] path.  This
   module does not mutate the cache directly — the resolve layer takes
   the [validation_result] and decides whether to install or fall back
   to LKG. *)

open Cascade_catalog_runtime_cache
module Probe = Cascade_catalog_runtime_probe

type declarative_catalog_info = {
  declarative_snapshot : Cascade_declarative_hotpath.decl_snapshot option;
  declarative_profile_names : string list;
  declarative_parse_errors : Cascade_declarative_parser.parse_error list;
  declarative_errors : Cascade_declarative_adapter.adapter_error list;
}

let render_declarative_parse_error
    (error : Cascade_declarative_parser.parse_error) =
  Printf.sprintf
    "declarative cascade parse error at %s: %s"
    error.path
    error.message

let render_declarative_adapter_error error =
  Printf.sprintf "declarative cascade adapter error: %s"
    (Cascade_declarative_adapter.show_adapter_error error)

(* RFC-0058 Phase 8.3: operator opt-in flag for cold-boot tolerance of
   partial cascade catalogs. Default is [false], preserving the existing
   all-or-nothing boot semantics. When set, [validate_path_result] and
   [discover_profile_names] surface the resolvable subset (via the
   Phase 8.1 partial-aware adapter) instead of failing closed.

   This is a footgun: leaving it on means operators may not notice
   degraded cascade.toml until dispatch fails. The dashboard banner and
   periodic WARN are the mitigations.

   Env var: [MASC_CASCADE_PARTIAL_BOOT=1] (or "true"/"yes").
   Default: false. *)
let allow_partial_boot () =
  Env_config_core.get_bool ~default:false "MASC_CASCADE_PARTIAL_BOOT"

let load_declarative_catalog_info ~config_path =
  match Cascade_declarative_parser.parse_file config_path with
  | Error errors ->
      Some
        {
          declarative_snapshot = None;
          declarative_profile_names = [];
          declarative_parse_errors = errors;
          declarative_errors = [];
        }
  | Ok cfg ->
      let catalog = Cascade_declarative_adapter.adapt_config cfg in
      let snapshot =
        Cascade_declarative_hotpath.adapted_catalog_to_snapshot
          ~source_path:config_path catalog
      in
      let profile_names =
        match snapshot with
        | Some snap ->
            Cascade_declarative_hotpath.decl_snapshot_profile_names snap
        | None -> []
      in
      Some
        {
          declarative_snapshot = snapshot;
          declarative_profile_names = profile_names;
          declarative_parse_errors = [];
          declarative_errors = catalog.errors;
        }

(* RFC-0066 §3.1 Phase 1: profile name discovery flows through the
   declarative adapter ({!Cascade_declarative_hotpath.try_load_declarative})
   reading [cascade.toml] as the sole SSOT (RFC-0058 §9.4). *)
let discover_profile_names ~config_path ~json : string list =
  match load_declarative_catalog_info ~config_path with
  | Some { declarative_parse_errors = errors; _ } when errors <> [] ->
      ignore json;
      Cascade_metrics.on_declarative_parse_error ();
      List.iter
        (fun err ->
          Log.Misc.warn
            "[CascadeProfileDiscovery] declarative parse error: %s"
            (render_declarative_parse_error err))
        errors;
      Cascade_metrics.on_profile_discovery ~path:"declarative_parse_error";
      []
  | Some { declarative_profile_names = names; declarative_errors = []; _ } ->
      Cascade_metrics.on_profile_discovery ~path:"declarative";
      names
      |> List.filter (fun profile ->
             if
               Cascade_config_loader.is_deprecated_logical_profile_name
                 profile
             then begin
               Cascade_metrics.on_deprecated_profile_name_filter
                 ~name:profile;
               false
             end
             else true)
      |> List.sort_uniq String.compare
  | Some
      {
        declarative_snapshot = Some snap;
        declarative_errors = (_ :: _ as errs);
        _;
      }
    when allow_partial_boot () ->
      (* RFC-0058 Phase 8.3: opt-in partial-boot tolerance. Declarative
         parser ran with adapter errors, but [MASC_CASCADE_PARTIAL_BOOT]
         is set, so surface the resolvable subset of profiles and emit
         a structured WARN per error. Source names from the snapshot
         (not [declarative_profile_names], which is built from
         catalog.profiles before empty/unresolvable profiles are
         removed). Otherwise route-target/default validation can pass
         for profiles that are no longer in the snapshot, surfacing
         only later as dispatch failures. *)
      Cascade_metrics.on_declarative_parse_error ();
      List.iter
        (fun err ->
          Log.Misc.warn
            "partial-boot mode: declarative adapter error \
             (continuing with valid subset): %s"
            (render_declarative_adapter_error err))
        errs;
      Cascade_metrics.on_profile_discovery
        ~path:"declarative_partial_boot";
      Cascade_declarative_hotpath.decl_snapshot_profile_names snap
      |> List.filter (fun profile ->
             not
               (Cascade_config_loader.is_deprecated_logical_profile_name
                  profile))
      |> List.sort_uniq String.compare
  | Some { declarative_errors = errs; _ } ->
      (* Declarative parser ran but produced adapter errors.  Do not fall
         through to the retired flat TOML reader: cascade.toml is now
         declarative-only, so adapter errors are fail-closed instead of
         returning a partial profile set. *)
      Cascade_metrics.on_declarative_parse_error ();
      List.iter
        (fun err ->
          Log.Misc.warn
            "[CascadeProfileDiscovery] declarative parse error: %s"
            (render_declarative_adapter_error err))
        errs;
      Cascade_metrics.on_profile_discovery ~path:"declarative_error";
      []
  | None ->
      ignore json;
      Cascade_metrics.on_profile_discovery ~path:"declarative_missing";
      []

let validate_strategy ~config_path ~name =
  let cfg =
    Cascade_config_loader.resolve_strategy_config ~config_path ~name
  in
  let strategy_errors =
    match cfg.kind with
    | None -> []
    | Some raw_kind -> (
        match Cascade_strategy.parse_config_kind raw_kind with
        | Error msg ->
            [ Printf.sprintf "unknown strategy %S: %s" raw_kind msg ]
        | Ok Cascade_strategy.Priority_tier -> (
            match cfg.tiers with
            | None ->
                [
                  "priority_tier requires a non-empty <name>_tiers \
                   configuration";
                ]
            | Some raw_tiers -> (
                match
                  Cascade_config.normalize_priority_tiers ~config_path
                    ~name raw_tiers
                with
                | Ok _ -> []
                | Error msg ->
                    [
                      Printf.sprintf
                        "priority_tier normalization failed: %s" msg;
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

let profile_build_of_declarative_profile ~required_capability_profile
    (profile : Cascade_declarative_hotpath.profile) =
  let candidates =
    List.map
      (fun (candidate : Cascade_declarative_hotpath.candidate) ->
        {
          model_string = candidate.model_string;
          provider_cfg = candidate.provider_cfg;
        })
      profile.candidates
  in
  {
    name = profile.name;
    weighted_entries = profile.weighted_entries;
    inference_params = profile.inference_params;
    api_key_env_overrides = [];
    strategy = profile.strategy;
    ollama_max_concurrent = profile.ollama_max_concurrent;
    cli_max_concurrent = profile.cli_max_concurrent;
    candidates;
    probes = Probe.profile_probes candidates;
    required_capability_profile;
  }

let validate_profile_static ?declarative_snapshot ~config_path
    ~required_capability_profile name :
    (profile_build, profile_rejection) result =
  let (_ : string) = config_path in
  match declarative_snapshot with
  | Some (snapshot : Cascade_declarative_hotpath.decl_snapshot) -> (
      match
        List.find_opt
          (fun (profile : Cascade_declarative_hotpath.profile) ->
            String.equal profile.name name)
          snapshot.profiles
      with
      | Some profile ->
          Ok
            (profile_build_of_declarative_profile
               ~required_capability_profile profile)
      | None ->
          Error
            {
              name;
              errors = [ "profile has no non-empty configured candidates" ];
              probes = [];
            })
  | None ->
      Error
        {
          name;
          errors = [ "profile has no non-empty configured candidates" ];
          probes = [];
        }

let profile_build_of_declarative
    (profile : Cascade_declarative_hotpath.profile) : profile_build =
  let candidates =
    List.map
      (fun (candidate : Cascade_declarative_hotpath.candidate) ->
        {
          model_string = candidate.model_string;
          provider_cfg = candidate.provider_cfg;
        })
      profile.candidates
  in
  {
    name = profile.name;
    weighted_entries = profile.weighted_entries;
    inference_params = profile.inference_params;
    api_key_env_overrides = [];
    strategy = profile.strategy;
    ollama_max_concurrent = profile.ollama_max_concurrent;
    cli_max_concurrent = profile.cli_max_concurrent;
    candidates;
    probes = Probe.profile_probes candidates;
    required_capability_profile = None;
  }

let runtime_required_profiles ~config_path =
  let keepers_from_catalog =
    match load_declarative_catalog_info ~config_path with
    | Some { declarative_profile_names; _ } -> declarative_profile_names
    | None -> []
  in
  List.sort_uniq String.compare
    (keepers_from_catalog
    @ Cascade_routes.configured_route_targets ~config_path ())

let config_path_opt () =
  Config_dir_resolver.log_warnings ~context:"CascadeCatalogRuntime" ();
  Config_dir_resolver.cascade_path_opt ()

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
      (rejection_of_path ~config_path:source_path ~attempted_mtime
         ~checked_at
         ~errors:
           [
             Printf.sprintf "active cascade source is missing: %s"
               source_path;
           ]
         ~profiles:[])
  else
    match attempted_mtime with
    | None ->
        Error
          (rejection_of_path ~config_path:source_path ~attempted_mtime
             ~checked_at
             ~errors:
               [
                 Printf.sprintf
                   "active cascade source mtime is unavailable: %s"
                   source_path;
               ]
             ~profiles:[])
    | Some source_mtime -> (
    match Cascade_config_loader.load_catalog_source config_path with
    | Error msg ->
        Error
          (rejection_of_path ~config_path:source_path ~attempted_mtime
             ~checked_at
             ~errors:
               [
                 Printf.sprintf
                   "active cascade source could not be loaded: %s" msg;
               ]
             ~profiles:[])
    | Ok json ->
        let declarative_info = load_declarative_catalog_info ~config_path in
        let declarative_snapshot =
          match declarative_info with
          | Some { declarative_snapshot = Some snapshot; _ } -> Some snapshot
          | Some { declarative_snapshot = None; _ } | None -> None
        in
        let declarative_parse_errors =
          match declarative_info with
          | Some { declarative_parse_errors; _ } -> declarative_parse_errors
          | None -> []
        in
        let declarative_errors =
          match declarative_info with
          | Some { declarative_errors; _ } -> declarative_errors
          | None -> []
        in
        let fatal_declarative_errors =
          List.map render_declarative_parse_error declarative_parse_errors
          @ List.map render_declarative_adapter_error declarative_errors
        in
        (* RFC-0058 Phase 8.3: partial-boot tolerance.

           Parser-level errors (declarative_parse_errors) are always
           fatal — the toml could not be tokenised, no snapshot exists.
           Adapter-level errors (declarative_errors) are tolerable under
           [MASC_CASCADE_PARTIAL_BOOT=1] iff a non-empty snapshot is
           available.

           When tolerated, we emit a structured WARN per error and fall
           through to the normal profile-resolution path; the snapshot
           already excludes unresolvable entries (Phase 8.1 invariant). *)
        let parser_fatal = declarative_parse_errors <> [] in
        let adapter_only_errors =
          declarative_parse_errors = [] && declarative_errors <> []
        in
        let tolerate_adapter_errors =
          adapter_only_errors
          && declarative_snapshot <> None
          && allow_partial_boot ()
        in
        if tolerate_adapter_errors then
          List.iter
            (fun err ->
              Log.Misc.warn
                "partial-boot mode: declarative adapter error in %s \
                 (continuing): %s"
                source_path (render_declarative_adapter_error err))
            declarative_errors;
        if
          (parser_fatal
          || (adapter_only_errors && not tolerate_adapter_errors))
          && fatal_declarative_errors <> []
        then
          Error
            (rejection_of_path ~config_path:source_path ~attempted_mtime
               ~checked_at ~errors:fatal_declarative_errors ~profiles:[])
        else
          let profiles = discover_profile_names ~config_path ~json in
          if profiles = [] then
            Error
              (rejection_of_path ~config_path:source_path ~attempted_mtime
                 ~checked_at
                 ~errors:[ "active cascade catalog declares no profiles" ]
                 ~profiles:[])
          else
            let required_default_profile =
              Cascade_routes.cascade_name_for_use ~config_path
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
            (* Emit per-class schema-error counters so operators can tell
               "typo storm" (unknown_route_key) from "deleted profile"
               (missing_target_profile) on the dashboard.  Detail (the
               specific route key / target name) stays in the rejection
               error string; the counter only quantifies frequency. *)
            Cascade_metrics.on_route_config_error
              ~error_type:"missing_target_profile"
              ~count:(List.length route_target_errors);
            Cascade_metrics.on_route_config_error
              ~error_type:"unknown_route_key"
              ~count:(List.length route_key_errors);
            let top_errors =
              let base =
                if profiles = [] then
                  [ "active cascade catalog declares no profiles" ]
                else []
              in
              let base = base @ route_key_errors @ route_target_errors in
              if List.mem required_default_profile profiles then base
              else
                base
                @ [
                    Printf.sprintf
                      "required default profile %S is missing"
                      required_default_profile;
                  ]
            in
            let built_profiles, statically_rejected_profiles =
              List.fold_left
                (fun (ok_acc, err_acc) name ->
                  match
                    validate_profile_static ?declarative_snapshot
                      ~config_path
                      ~required_capability_profile:None name
                  with
                  | Ok profile -> (profile :: ok_acc, err_acc)
                  | Error rejection -> (ok_acc, rejection :: err_acc))
                ([], []) profiles
            in
            let built_profiles = List.rev built_profiles in
            let statically_rejected_profiles =
              List.rev statically_rejected_profiles
            in
            if top_errors <> [] || built_profiles = [] then
              Error
                (rejection_of_path ~config_path:source_path
                   ~attempted_mtime ~checked_at ~errors:top_errors
                   ~profiles:statically_rejected_profiles)
            else
              let profile_snapshots : profile_snapshot list =
                Probe.attach_probe_results ?sw ?net built_profiles
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
                  mtime = source_mtime;
                  validated_at = checked_at;
                  profiles = profile_snapshots;
                  default_profile_name = required_default_profile;
                }
              in
              Probe.record_probe_metrics profile_snapshots;
              (* RFC-0058 Phase 3: parallel declarative validation.

                 The JSON-shape discovery path and the typed declarative
                 parser both produce a profile-name set; we cross-check
                 them to catch silent drift.  Both sides are sorted +
                 deduplicated before [<>] comparison — without that the
                 list-equality check flips on declaration-order
                 differences and produces spurious "profile name mismatch"
                 WARNs ([decl_snapshot_profile_names] now applies
                 [sort_uniq] internally, but we sort [json_names] here as
                 well to make the contract obvious at the call site).

                 Each branch emits a Prometheus counter so operators can
                 alert on drift / adapter faults without scraping logs. *)
              (match declarative_snapshot with
               | Some decl_snap ->
                 let json_names =
                   List.map (fun (p : profile_build) -> p.name)
                     profile_snapshots
                   |> List.sort_uniq String.compare
                 in
                 let decl_names =
                   Cascade_declarative_hotpath.decl_snapshot_profile_names
                     decl_snap
                 in
                 if json_names <> decl_names then (
                   Cascade_metrics.on_parallel_validation
                     ~result:"mismatch";
                   let only_in xs ys =
                     List.filter (fun x -> not (List.mem x ys)) xs
                   in
                   let json_only = only_in json_names decl_names in
                   let decl_only = only_in decl_names json_names in
                   Log.Misc.warn
                     "[CascadeDeclarative] profile name mismatch: \
                      json=[%s] decl=[%s] (json_only=[%s] decl_only=[%s])"
                     (String.concat ", " json_names)
                     (String.concat ", " decl_names)
                     (String.concat ", " json_only)
                     (String.concat ", " decl_only))
                 else (
                   Cascade_metrics.on_parallel_validation ~result:"ok";
                   Log.Misc.info
                     "[CascadeDeclarative] parallel validation OK, %d \
                      profiles"
                     (List.length decl_names));
                 if declarative_errors <> [] then begin
                   Cascade_metrics.on_parallel_validation
                     ~result:"adapter_error";
                   List.iter
                     (fun e ->
                       Log.Misc.warn
                         "[CascadeDeclarative] adapter error: %s"
                         (Cascade_declarative_adapter.show_adapter_error
                            e))
                     declarative_errors
                 end
               | None when declarative_errors <> [] ->
                 Cascade_metrics.on_parallel_validation
                   ~result:"adapter_error";
                 List.iter
                   (fun e ->
                     Log.Misc.warn
                       "[CascadeDeclarative] adapter error: %s"
                       (Cascade_declarative_adapter.show_adapter_error e))
                   declarative_errors
               | None ->
                 Cascade_metrics.on_parallel_validation
                   ~result:"no_decl");
              if rejected_profiles = [] then
                Ok { snapshot; rejected_update = None }
              else
                let rejection =
                  rejection_of_path ~config_path:source_path
                    ~attempted_mtime ~checked_at
                    ~errors:
                      ((if default_profile_validated then []
                        else
                          [
                            Printf.sprintf
                              "required default profile %S failed \
                               validation"
                              required_default_profile;
                          ])
                      @ [
                          Printf.sprintf
                            "catalog validation rejected %d/%d \
                             profile(s)"
                            (List.length rejected_profiles)
                            (List.length profiles);
                        ])
                    ~profiles:rejected_profiles
                in
                if profile_snapshots = [] || not default_profile_validated
                then Error rejection
                else Ok { snapshot; rejected_update = Some rejection })

let validate_path ?sw ?net ?clock ~config_path () =
  let (_ : float Eio.Time.clock_ty Eio.Resource.t option) = clock in
  match validate_path_result ?sw ?net ~config_path () with
  | Ok result -> Ok result.snapshot
  | Error _ as e -> e
