(** Cascade configuration projection for the dashboard.

    Surfaces:
    - [config_json]: validated runtime profiles + keeper -> cascade
      mapping, plus validation summary fields.
    - [raw_config_json]: editable [cascade.toml] source with in-memory
      JSON rendering.
    - [save_raw_config_json]: writes the TOML source and returns the
      refreshed [config_json] snapshot. *)

open Dashboard_cascade_helpers

let sorted_unique_strings values =
  values
  |> List.map String.trim
  |> List.filter (fun value -> not (String.equal value ""))
  |> List.sort_uniq String.compare
;;

let feature_param_json ~key ~scope ~value_type ~example =
  `Assoc
    [ "key", `String key
    ; "scope", `String scope
    ; "value_type", `String value_type
    ; "example", `String example
    ]
;;

let cascade_source_feature_params_json =
  `List
    [ feature_param_json
        ~key:"is-default"
        ~scope:"binding"
        ~value_type:"boolean"
        ~example:"is-default = false"
    ; feature_param_json
        ~key:"max-concurrent"
        ~scope:"binding,tier"
        ~value_type:"integer"
        ~example:"max-concurrent = 2"
    ; feature_param_json
        ~key:"temperature"
        ~scope:"alias"
        ~value_type:"float"
        ~example:"temperature = 0.2"
    ; feature_param_json
        ~key:"max-input"
        ~scope:"alias"
        ~value_type:"integer"
        ~example:"max-input = 32768"
    ; feature_param_json
        ~key:"max-output"
        ~scope:"alias"
        ~value_type:"integer"
        ~example:"max-output = 8192"
    ; feature_param_json
        ~key:"thinking-enabled"
        ~scope:"alias"
        ~value_type:"boolean"
        ~example:"thinking-enabled = true"
    ; feature_param_json
        ~key:"thinking-budget"
        ~scope:"alias"
        ~value_type:"integer"
        ~example:"thinking-budget = 8192"
    ; feature_param_json
        ~key:"keep-alive"
        ~scope:"binding"
        ~value_type:"string"
        ~example:"keep-alive = \"30m\""
    ; feature_param_json
        ~key:"num-ctx"
        ~scope:"binding"
        ~value_type:"integer"
        ~example:"num-ctx = 32768"
    ; feature_param_json
        ~key:"price-input"
        ~scope:"binding"
        ~value_type:"float"
        ~example:"price-input = 0.15"
    ; feature_param_json
        ~key:"price-output"
        ~scope:"binding"
        ~value_type:"float"
        ~example:"price-output = 0.60"
    ; feature_param_json
        ~key:"strategy"
        ~scope:"tier,tier-group"
        ~value_type:"string"
        ~example:"strategy = \"priority_tier\""
    ; feature_param_json
        ~key:"max-cycles"
        ~scope:"tier.cycle-policy"
        ~value_type:"integer"
        ~example:"max-cycles = 3"
    ; feature_param_json
        ~key:"sticky-ttl-ms"
        ~scope:"tier"
        ~value_type:"integer"
        ~example:"sticky-ttl-ms = 30000"
    ]
;;

let parse_error_to_json (error : Cascade_declarative_parser.parse_error) =
  `Assoc [ "path", `String error.path; "message", `String error.message ]
;;

let source_assist_json source_text =
  match Cascade_declarative_parser.parse_string source_text with
  | Error errors ->
    `Assoc
      [ "parse_status", `String "unavailable"
      ; "providers", `List []
      ; "models", `List []
      ; "bindings", `List []
      ; "aliases", `List []
      ; "tiers", `List []
      ; "tier_groups", `List []
      ; "routes", `List []
      ; "feature_params", cascade_source_feature_params_json
      ; "errors", `List (List.map parse_error_to_json errors)
      ]
  | Ok cfg ->
    let bindings =
      cfg.Cascade_declarative_types.bindings
      |> List.map Cascade_declarative_types.binding_key
    in
    let aliases =
      cfg.Cascade_declarative_types.aliases
      |> List.map Cascade_declarative_types.alias_key
    in
    let string_list values = string_list_to_json (sorted_unique_strings values) in
    `Assoc
      [ "parse_status", `String "parsed"
      ; ( "providers"
        , string_list
            (List.map
               (fun (p : Cascade_declarative_types.cascade_provider) -> p.id)
               cfg.providers)
        )
      ; ( "models"
        , string_list
            (List.map
               (fun (m : Cascade_declarative_types.cascade_model_spec) -> m.id)
               cfg.models)
        )
      ; "bindings", string_list bindings
      ; "aliases", string_list aliases
      ; ( "tiers"
        , string_list
            (List.map (fun (t : Cascade_declarative_types.cascade_tier) -> t.name) cfg.tiers)
        )
      ; ( "tier_groups"
        , string_list
            (List.map
               (fun (tg : Cascade_declarative_types.cascade_tier_group) -> tg.name)
               cfg.tier_groups)
        )
      ; ( "routes"
        , string_list
            (List.map (fun (r : Cascade_declarative_types.cascade_route) -> r.name) cfg.routes)
        )
      ; "feature_params", cascade_source_feature_params_json
      ; "errors", `List []
      ]
;;

(** Profiles to surface in the dashboard.

    When the validated runtime snapshot is unavailable (for example
    before first successful validation), fall back to the active
    [cascade.toml] projection so the dashboard still renders a best-effort
    raw view instead of failing hard. *)
let live_profiles ?config_path () = Keeper_cascade_profile.catalog_names ?config_path ()

let keeper_assignable_name_set ?config_path () =
  Keeper_cascade_profile.keeper_catalog_names ?config_path ()
  |> List.fold_left (fun acc name -> StringSet.add name acc) StringSet.empty
;;

let profile_json_of_trace ~keeper_assignable name (trace : CC.selection_trace) =
  `Assoc
    [ "name", `String name
    ; "source", `String (source_to_string trace.source)
    ; "keeper_assignable", `Bool keeper_assignable
    ; "candidates", `List (List.map candidate_to_json trace.candidates)
    ]
;;

let profile_json_runtime ~keeper_assignable_names name =
  match Cascade_catalog_runtime.resolve_selection_trace ~name () with
  | Ok trace ->
    Some
      (profile_json_of_trace
         ~keeper_assignable:(StringSet.mem name keeper_assignable_names)
         name
         trace)
  | Error detail ->
    Log.Keeper.warn "dashboard cascade config: skipping profile %s: %s" name detail;
    None
;;

let profile_json_raw ~config_path ~keeper_assignable_names name =
  let defaults =
    Cascade_runtime.default_model_strings
      ~cascade_name:(Keeper_cascade_profile.Runtime_name name)
  in
  let _models, trace =
    CC.resolve_model_strings_with_trace ?config_path ~name ~defaults ()
  in
  profile_json_of_trace
    ~keeper_assignable:(StringSet.mem name keeper_assignable_names)
    name
    trace
;;

(* Two-column contract consumed by the dashboard's "Keeper → Cascade
   Mapping" table:

   - [cascade_name]: raw value from the keeper meta (TOML / state JSON
     round-trip).  NOT canonicalized here — downstream call sites
     canonicalize at point-of-use.
   - [canonical]: the cascade actually used by [Cascade_runtime] for
     model resolution.

   When the two differ, the UI surfaces that the keeper's declared
   cascade is not a recognized variant (classic parse-don't-validate
   drift).  When they match, the UI renders "—" in the canonical column.

   Exposed as a pure helper so the contract can be exercised without
   synthesizing a full [Keeper_registry.registry_entry]. *)
let keeper_profile_fields ~keeper ~cascade_name : (string * Yojson.Safe.t) list =
  [ "keeper", `String keeper
  ; "cascade_name", `String cascade_name
  ; "canonical", `String (Keeper_cascade_profile.resolve_live cascade_name)
  ]
;;

let keeper_profile_json (entry : Keeper_registry.registry_entry) : Yojson.Safe.t =
  `Assoc
    (keeper_profile_fields
       ~keeper:entry.name
       ~cascade_name:(Keeper_types.cascade_name_of_meta entry.meta))
;;

let invalid_profiles_of_config_path = function
  | None -> []
  | Some path ->
    Cascade_catalog_validator.error_messages_by_profile ~config_path:path
    |> invalid_profiles_with_internal_names
;;

let validation_summary_json ?config_path () =
  let fallback_invalid_profiles = invalid_profiles_of_config_path config_path in
  let of_rejection ~status rejection =
    let rejection_json = Cascade_catalog_runtime.rejection_to_yojson rejection in
    let invalid_profiles =
      match invalid_profiles_of_rejection_json rejection_json with
      | [] -> fallback_invalid_profiles
      | profiles -> profiles
    in
    [ "validation_status", `String status
    ; ( "validation_errors"
      , string_list_to_json (json_string_list (json_assoc_member "errors" rejection_json))
      )
    ; "invalid_profiles", `List (List.map invalid_profile_to_json invalid_profiles)
    ]
  in
  match Cascade_catalog_runtime.inspect_active () with
  | Ok (Cascade_catalog_runtime.Validated _) ->
    [ "validation_status", `String "validated"
    ; "validation_errors", `List []
    ; "invalid_profiles", `List []
    ]
  | Ok (Cascade_catalog_runtime.Validated_with_rejections { rejected_update; _ }) ->
    of_rejection ~status:"validated" rejected_update
  | Ok (Cascade_catalog_runtime.Serving_last_known_good { rejected_update; _ }) ->
    of_rejection ~status:"serving_last_known_good" rejected_update
  | Error rejection -> of_rejection ~status:"invalid" rejection
;;

let config_json ?base_path () =
  let config_path = Cascade_runtime.cascade_config_path () in
  let source : Cascade_toml_materializer.source_info = source_info ?config_path () in
  let keeper_assignable_names = keeper_assignable_name_set ?config_path () in
  let keeper_entries =
    (* Issue #8619: was [with _ -> []] which silently swallowed
       Eio.Cancel.Cancelled. Re-raise cancellation; only fall back
       to empty for non-cancel exceptions (e.g. registry not yet
       initialised). *)
    try Keeper_registry.all ?base_path () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "dashboard_cascade.config_json: Keeper_registry.all failed (treating as empty): \
         %s"
        (Printexc.to_string exn);
      []
  in
  let active_names =
    List.fold_left
      (fun acc (e : Keeper_registry.registry_entry) -> StringSet.add e.name acc)
      StringSet.empty
      keeper_entries
  in
  let offline_keepers_json =
    try
      Config_dir_resolver.keepers_dir ()
      |> Keeper_types_profile.discover_keepers_toml
      |> List.filter_map (fun (name, doc) ->
        if StringSet.mem name active_names
        then None
        else (
          let cascade_name =
            match doc.Keeper_types_profile.cascade_name with
            | Some c -> c
            | None -> (Keeper_config.default_cascade_name ())
          in
          Some (`Assoc (keeper_profile_fields ~keeper:name ~cascade_name))))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "dashboard_cascade: offline_keepers_json failed: %s"
        (Printexc.to_string exn);
      []
  in
  let profiles =
    match Cascade_catalog_runtime.known_profile_names () with
    | Ok names -> List.filter_map (profile_json_runtime ~keeper_assignable_names) names
  | Error detail ->
    Log.Keeper.warn "dashboard cascade config: validated catalog unavailable: %s" detail;
    let invalid_profiles = invalid_profiles_of_config_path config_path in
    let known_internal_profiles =
      match config_path with
      | None -> []
      | Some path ->
        Cascade_catalog_validator.discover_profiles_for_diagnostics ~config_path:path
    in
    let add_profile_name (acc, seen) name =
      let canonical = Keeper_cascade_profile.canonicalize name in
      if StringSet.mem canonical seen
         || Option.is_some
              (invalid_assignment_reasons
                 ~known_internal_profiles
                 ~invalid_profiles
                 canonical)
      then acc, seen
      else canonical :: acc, StringSet.add canonical seen
    in
      let acc_after_catalog, seen_after_catalog =
        List.fold_left
          add_profile_name
          ([], StringSet.empty)
          (live_profiles ?config_path ())
      in
      let names, _ =
        List.fold_left
          (fun (acc, seen) (e : Keeper_registry.registry_entry) ->
             add_profile_name (acc, seen) (Keeper_types.cascade_name_of_meta e.meta))
          (acc_after_catalog, seen_after_catalog)
          keeper_entries
      in
      let names = List.rev names in
      List.map (profile_json_raw ~config_path ~keeper_assignable_names) names
  in
  let fields =
    [ "updated_at", `String (now_iso ())
    ; ( "config_path"
      , match config_path with
        | Some p -> `String p
        | None -> `Null )
    ]
    @ source_json_fields source
    @ validation_summary_json ?config_path ()
    @ [ "profiles", `List profiles
      ; ( "keeper_profiles"
        , `List (List.map keeper_profile_json keeper_entries @ offline_keepers_json) )
      ]
  in
  `Assoc fields
;;

(* RFC-0058 §9.3: empty cascade.toml seed.  "" is the smallest valid
   TOML document (an empty table); previously this was "{}\n" which is
   JSON-shaped and not parseable by the TOML reader. *)
let default_raw_source_text = ""

let load_raw_config_string path =
  if Fs_compat.file_exists path then Fs_compat.load_file path else default_raw_source_text
;;

let invalidate_cascade_config config_path =
  Cascade_config_loader.invalidate_cache_entry config_path;
  Cascade_catalog_runtime.invalidate_path config_path
;;

let save_config_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path content
;;

(* RFC-0058 §9 Phase 9.3: TOML is the only cascade source. Dashboard
   response no longer carries a separate [config_path] for the JSON
   sibling -- there isn't one -- and [raw_json_editable] is gone from the
   schema along with the JSON-native authoring mode it described.
   [raw_json] is rendered in memory from the TOML SSOT on each request. *)
let raw_config_json () =
  Config_dir_resolver.log_warnings ~context:"DashboardCascade" ();
  let source : Cascade_toml_materializer.source_info = source_info () in
  let source_read_error = ref None in
  let source_text =
    try load_raw_config_string source.source_path with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Sys_error msg ->
      Log.Keeper.warn
        "dashboard cascade source config: failed to read %s: %s"
        source.source_path
        msg;
      source_read_error := Some msg;
      ""
  in
  (* RFC-0058 §9 Phase 9.3: TOML is the only cascade source. Render JSON
     in memory from the [source_text] loaded above -- single disk read per
     call, no JSON sibling on disk, no source_kind match. If the source
     read itself failed, surface that as [materialization_error] instead
     of feeding an empty string to the renderer (which would parse as
     [Ok ""]). *)
  let raw_json, materialization_error =
    match !source_read_error with
    | Some msg -> "", Some msg
    | None ->
      (match Cascade_toml_materializer.render_toml_string_to_json_string source_text with
       | Ok json -> json, None
       | Error msg ->
         Log.Keeper.warn
           "DashboardCascade: in-memory materialization failed for %s: %s"
           source.source_path
           msg;
         "", Some msg)
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "source_kind", `String (Cascade_toml_materializer.source_kind_to_string source.kind)
    ; "source_path", `String source.source_path
    ; "source_editable", `Bool (Option.is_none !source_read_error)
    ; "source_text", `String source_text
    ; "assist", source_assist_json source_text
    ; "raw_json", `String raw_json
    ; ( "materialization_error"
      , match materialization_error with
        | Some msg -> `String msg
        | None -> `Null )
    ]
;;

(* RFC-0058 §9 Phase 9.3: dashboard save accepts only TOML payloads now;
   the JSON-native save branch is gone. The save persists the TOML file
   and invalidates the cascade loader's cache. Subsequent reads re-render
   in memory via [render_toml_to_json_string]. *)
let save_raw_config_json raw_json =
  Config_dir_resolver.log_warnings ~context:"DashboardCascade" ();
  let source : Cascade_toml_materializer.source_info = source_info () in
  match Cascade_toml_materializer.render_toml_string_to_json_string raw_json with
  | Error msg -> Error (Printf.sprintf "invalid TOML: %s" msg)
  | Ok _rendered_json ->
    (try
       match save_config_file source.source_path raw_json with
       | Error msg -> Error msg
       | Ok () ->
         (* [Cascade_config_loader.load_toml_in_memory] and
            [Cascade_catalog_runtime] both key their caches on
            [source.source_path] (the TOML path). *)
         invalidate_cascade_config source.source_path;
         Ok (config_json ())
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Sys_error msg -> Error msg)
;;
