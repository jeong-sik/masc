(* Stage 08 — declarative catalog loading + boot-time profile
   validation.  Produces a [validation_result] (snapshot + optional
   rejection) or a fatal [rejection] from a [cascade.toml] path.  This
   module does not mutate the cache directly — the resolve layer takes
   the [validation_result] and decides whether to install or fall back
   to LKG. *)

open Keeper_catalog_runtime_cache
module Probe = Keeper_catalog_runtime_probe

type declarative_catalog_info = {
  declarative_snapshot : Keeper_declarative_hotpath.decl_snapshot option;
  declarative_profile_names : string list;
  declarative_parse_errors : Cascade_declarative_parser.parse_error list;
  declarative_errors : Keeper_declarative_adapter.adapter_error list;
}

let render_declarative_parse_error
    (error : Cascade_declarative_parser.parse_error) =
  Printf.sprintf
    "declarative cascade parse error at %s: %s"
    error.path
    error.message

let render_declarative_adapter_error error =
  Printf.sprintf "declarative cascade adapter error: %s"
    (Keeper_declarative_adapter.show_adapter_error error)

let deprecated_logical_profile_name_error ~kind name :
    Cascade_declarative_parser.parse_error option =
  if Keeper_config_loader.is_deprecated_logical_profile_name name then
    Some
      {
        path = Printf.sprintf "%s.%s" kind name;
        message =
          Printf.sprintf
            "deprecated cascade profile name %S is no longer supported as a %s \
             name; use a non-route catalog profile name and point [routes.*] \
             at it"
            name
            kind;
      }
  else None

let deprecated_logical_profile_name_errors
    (_cfg : Cascade_declarative_types.cascade_config) =
  []

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
      let catalog = Keeper_declarative_adapter.adapt_config cfg in
      let snapshot =
        Keeper_declarative_hotpath.adapted_catalog_to_snapshot
          ~source_path:config_path catalog
      in
      let declarative_parse_errors =
        deprecated_logical_profile_name_errors cfg
      in
      let profile_names =
        match snapshot with
        | Some snap ->
            Keeper_declarative_hotpath.decl_snapshot_profile_names snap
        | None -> []
      in
      Some
        {
          declarative_snapshot = snapshot;
          declarative_profile_names = profile_names;
          declarative_parse_errors;
          declarative_errors = catalog.errors;
        }

(* RFC-0066 §3.1 Phase 1: profile name discovery flows through the
   declarative adapter ({!Keeper_declarative_hotpath.try_load_declarative})
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
      names |> List.sort_uniq String.compare
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
      Keeper_declarative_hotpath.decl_snapshot_profile_names snap
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
    Keeper_config_loader.resolve_strategy_config ~config_path ~name
  in
  let strategy_errors =
    match cfg.kind with
    | None -> []
    | Some raw_kind -> (
        match Cascade_strategy.parse_config_kind raw_kind with
        | Error msg ->
            [ Printf.sprintf "unknown strategy %S: %s" raw_kind msg ]
        | Ok _ -> [])
  in
  if strategy_errors <> [] then
    Error strategy_errors
  else
    (* Bypass Cascade_config facade.  Calling through it would create the
       Cascade_config → Keeper_config_resolve → Keeper_routes →
       Cascade_catalog_runtime → Keeper_catalog_runtime_validate →
       Cascade_config cycle. *)
    Ok
      ( Keeper_config_strategy_resolve.resolve_strategy ~config_path ~name (),
        Keeper_config_strategy_resolve.resolve_ollama_max_concurrent
          ~config_path ~name (),
        Keeper_config_strategy_resolve.resolve_cli_max_concurrent
          ~config_path ~name () )

let rejection_of_path ~config_path ~attempted_mtime ~checked_at
    ~(errors : string list) ~(profiles : profile_rejection list) =
  { source_path = config_path; attempted_mtime; checked_at; errors; profiles }

let active_source_state ~config_path =
  Keeper_toml_materializer.source_state ~config_path

let profile_build_of_declarative_profile
    (profile : Keeper_declarative_hotpath.profile) =
  let candidates =
    List.map
      (fun (candidate : Keeper_declarative_hotpath.candidate) ->
        {
          model_string = candidate.model_string;
          provider_cfg = candidate.provider_cfg;
          provider_override = candidate.provider_override;
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
    required_capability_profile = profile.required_capability_profile;
  }

let validate_profile_static ?declarative_snapshot ~config_path name :
    (profile_build, profile_rejection) result =
  let (_ : string) = config_path in
  match declarative_snapshot with
  | Some (snapshot : Keeper_declarative_hotpath.decl_snapshot) -> (
      match
        List.find_opt
          (fun (profile : Keeper_declarative_hotpath.profile) ->
            String.equal profile.name name)
          snapshot.profiles
      with
      | Some profile -> Ok (profile_build_of_declarative_profile profile)
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
    (profile : Keeper_declarative_hotpath.profile) : profile_build =
  let candidates =
    List.map
      (fun (candidate : Keeper_declarative_hotpath.candidate) ->
        {
          model_string = candidate.model_string;
          provider_cfg = candidate.provider_cfg;
          provider_override = candidate.provider_override;
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

(* #19327/#19340 follow-up: [runtime_required_profile_names] and its helper
   [runtime_required_profiles] had no callers (grep on the whole tree returned
   zero matches), and were the only sites in this module that pulled in
   [Keeper_routes.configured_route_targets].  Deleting them removes one of
   the four back-edges into [Keeper_routes] that closed the
   Keeper_routes ↔ Keeper_catalog_runtime_validate module-level cycle.
   See PR cycle resolution section. *)

let config_path_opt () =
  Config_dir_resolver.log_warnings ~context:"CascadeCatalogRuntime" ();
  Config_dir_resolver.cascade_path_opt ()

(* #19327/#19340 follow-up: DI envelope for the post-profile route-target
   cross-check that was previously buried in [validate_path_result] and
   reached up into [Keeper_routes] — the back-edge that closed the
   Keeper_routes ↔ Keeper_catalog_runtime_validate module-level cycle. *)
type route_data = {
  keeper_turn_target : string option;
  route_targets : string list;
  unknown_route_keys : string list;
}

let empty_route_data : route_data =
  { keeper_turn_target = None
  ; route_targets = []
  ; unknown_route_keys = []
  }

let validate_path_result ?sw ?net ~route_data ~config_path () =
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
    match Keeper_config_loader.load_catalog_source config_path with
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
            (* #19327/#19340 follow-up: route-target cross-checks moved out of
               the validate function body and exposed as injected parameters
               (DI).  Internal callers (resolve.ml) pass empty data so they do
               not need [Keeper_routes].  External callers (dashboard) fetch
               from [Keeper_routes] and pass typed [route_data].  This breaks
               the Keeper_routes ↔ Keeper_catalog_runtime_validate cycle.

               Empty defaults preserve internal behavior — the route checks
               were duplicated against [validate_route_data] anyway from the
               dashboard side. *)
            let route_data = route_data in
            let required_default_profile = route_data.keeper_turn_target in
            let route_target_errors =
              route_data.route_targets
              |> List.filter_map (fun target ->
                     if List.mem target profiles then None
                     else
                       Some
                         (Printf.sprintf
                            "cascade route targets missing profile %S"
                            target))
            in
            let route_key_errors =
              route_data.unknown_route_keys
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
              match required_default_profile with
              | None -> base
              | Some profile_name ->
                if List.mem profile_name profiles then base
                else
                  base
                  @ [
                      Printf.sprintf
                        "required default profile %S is missing"
                        profile_name;
                    ]
            in
            let built_profiles, statically_rejected_profiles =
              List.fold_left
                (fun (ok_acc, err_acc) name ->
                  match
                    validate_profile_static ?declarative_snapshot
                      ~config_path name
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
                match required_default_profile with
                | None -> true
                | Some profile_name ->
                  List.exists
                    (fun (profile : profile_snapshot) ->
                      String.equal profile.name profile_name)
                    profile_snapshots
              in
              let snapshot =
                {
                  source_path;
                  mtime = source_mtime;
                  validated_at = checked_at;
                  profiles = profile_snapshots;
                  default_profile_name =
                    (* NDT-OK: sound-partial: optional route target defaults
                       to empty when no routes.keeper_turn is configured. *)
                    Option.value required_default_profile ~default:"";
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
                   Keeper_declarative_hotpath.decl_snapshot_profile_names
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
                         (Keeper_declarative_adapter.show_adapter_error
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
                       (Keeper_declarative_adapter.show_adapter_error e))
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
                              (Option.value required_default_profile
                                 ~default:"");
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

let validate_path ?sw ?net ?clock ~route_data ~config_path () =
  let (_ : float Eio.Time.clock_ty Eio.Resource.t option) = clock in
  match validate_path_result ?sw ?net ~route_data ~config_path () with
  | Ok result -> Ok result.snapshot
  | Error _ as e -> e
