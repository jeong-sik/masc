(** Dashboard projection for cascade configuration and runtime health. *)

module CC = Cascade_config
module Health = Cascade_health_tracker
module StringSet = Set.Make (String)

(* ── Shared helpers ─────────────────────────────────── *)

let now_iso () = Types.now_iso ()

let candidate_to_json (c : CC.candidate_info) : Yojson.Safe.t =
  `Assoc [
    ("model", `String c.model_string);
    ("display_model", `String c.display_model_string);
    ("provider_name", Json_util.string_opt_to_json c.provider_name);
    ("display_provider_name", Json_util.string_opt_to_json c.display_provider_name);
    ("runtime_kind", Json_util.string_opt_to_json c.runtime_kind);
    ("expanded_models", `List (List.map (fun model -> `String model) c.expanded_models));
    ("config_weight", `Int c.config_weight);
    ("effective_weight", `Int c.effective_weight);
    ("success_rate", `Float c.success_rate);
    ("in_cooldown", `Bool c.in_cooldown);
  ]

let source_to_string = function
  | CC.Named -> "named"
  | CC.Default_fallback -> "default_fallback"
  | CC.Hardcoded_defaults -> "hardcoded_defaults"

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let invalid_profile_to_json (name, errors : string * string list) =
  `Assoc
    [
      ("name", `String name);
      ("errors", string_list_to_json errors);
    ]

let json_assoc_member key = function
  | `Assoc fields -> Option.value (List.assoc_opt key fields) ~default:`Null
  | _ -> `Null

let json_string_list = function
  | `List values ->
      List.filter_map
        (function
          | `String value -> Some value
          | _ -> None)
        values
  | _ -> []

let invalid_profiles_of_rejection_json rejection_json =
  match json_assoc_member "profiles" rejection_json with
  | `List profiles ->
      List.filter_map
        (fun profile_json ->
           match json_assoc_member "name" profile_json with
           | `String name ->
               Some (name, json_string_list (json_assoc_member "errors" profile_json))
           | _ -> None)
        profiles
  | _ -> []

let source_info ?config_path () =
  let config_path =
    match config_path with
    | Some path -> path
    | None -> Config_dir_resolver.cascade_path_candidate ()
  in
  Cascade_toml_materializer.source_info ~config_path

let source_json_fields (source : Cascade_toml_materializer.source_info) =
  [
    ( "source_kind",
      `String
        (Cascade_toml_materializer.source_kind_to_string source.kind) );
    ("source_path", `String source.source_path);
  ]

(* ── Config projection ──────────────────────────────── *)

(** Profiles to surface in the dashboard.

    When the validated runtime snapshot is unavailable (for example
    before first successful validation), fall back to the active
    [cascade.json] catalog so the dashboard still renders a best-effort
    raw projection instead of failing hard. *)
let live_profiles ?config_path () =
  Keeper_cascade_profile.catalog_names ?config_path ()

let keeper_assignable_name_set ?config_path () =
  Keeper_cascade_profile.keeper_catalog_names ?config_path ()
  |> List.fold_left
       (fun acc name -> StringSet.add name acc)
       StringSet.empty

let profile_json_of_trace ~keeper_assignable name (trace : CC.selection_trace) =
  `Assoc [
    ("name", `String name);
    ("source", `String (source_to_string trace.source));
    ("keeper_assignable", `Bool keeper_assignable);
    ("candidates", `List (List.map candidate_to_json trace.candidates));
  ]

let profile_json_runtime ~keeper_assignable_names name =
  match Cascade_catalog_runtime.resolve_selection_trace ~name () with
  | Ok trace ->
      Some
        (profile_json_of_trace
           ~keeper_assignable:(StringSet.mem name keeper_assignable_names)
           name trace)
  | Error detail ->
      Log.Keeper.warn
        "dashboard cascade config: skipping profile %s: %s"
        name detail;
      None

let profile_json_raw ~config_path ~keeper_assignable_names name =
  let defaults = Cascade_runtime.default_model_strings ~cascade_name:name in
  let (_models, trace) =
    CC.resolve_model_strings_with_trace ?config_path ~name ~defaults ()
  in
  profile_json_of_trace
    ~keeper_assignable:(StringSet.mem name keeper_assignable_names)
    name trace

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
  [ ("keeper", `String keeper);
    ("cascade_name", `String cascade_name);
    ("canonical", `String (Keeper_cascade_profile.resolve_live cascade_name));
  ]

let keeper_profile_json (entry : Keeper_registry.registry_entry) : Yojson.Safe.t =
  `Assoc
    (keeper_profile_fields
       ~keeper:entry.name
       ~cascade_name:entry.meta.cascade_name)

let invalid_name_set = function
  | None -> StringSet.empty
  | Some path ->
      Cascade_catalog_validator.error_messages_by_profile ~config_path:path
      |> List.fold_left
           (fun acc (name, _reasons) -> StringSet.add name acc)
           StringSet.empty

let invalid_profiles_of_config_path = function
  | None -> []
  | Some path -> Cascade_catalog_validator.error_messages_by_profile ~config_path:path

let validation_summary_json ?config_path () =
  let fallback_invalid_profiles = invalid_profiles_of_config_path config_path in
  let of_rejection ~status rejection =
    let rejection_json = Cascade_catalog_runtime.rejection_to_yojson rejection in
    let invalid_profiles =
      match invalid_profiles_of_rejection_json rejection_json with
      | [] -> fallback_invalid_profiles
      | profiles -> profiles
    in
    [
      ("validation_status", `String status);
      ("validation_errors",
       string_list_to_json (json_string_list (json_assoc_member "errors" rejection_json)));
      ("invalid_profiles", `List (List.map invalid_profile_to_json invalid_profiles));
    ]
  in
  match Cascade_catalog_runtime.inspect_active () with
  | Ok (Cascade_catalog_runtime.Validated _) ->
      [
        ("validation_status", `String "validated");
        ("validation_errors", `List []);
        ("invalid_profiles", `List []);
      ]
  | Ok
      (Cascade_catalog_runtime.Validated_with_rejections
         { rejected_update; _ }) ->
      of_rejection ~status:"validated" rejected_update
  | Ok
      (Cascade_catalog_runtime.Serving_last_known_good
         { rejected_update; _ }) ->
      of_rejection ~status:"serving_last_known_good" rejected_update
  | Error rejection ->
      of_rejection ~status:"invalid" rejection

let config_json () =
  let config_path = Cascade_runtime.cascade_config_path () in
  let source : Cascade_toml_materializer.source_info =
    source_info ?config_path ()
  in
  let keeper_assignable_names = keeper_assignable_name_set ?config_path () in
  let keeper_entries =
    (* Issue #8619: was [with _ -> []] which silently swallowed
       Eio.Cancel.Cancelled. Re-raise cancellation; only fall back
       to empty for non-cancel exceptions (e.g. registry not yet
       initialised). *)
    try Keeper_registry.all ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []
  in
  let profiles =
    match Cascade_catalog_runtime.known_profile_names () with
    | Ok names ->
        List.filter_map
          (profile_json_runtime ~keeper_assignable_names)
          names
    | Error detail ->
        Log.Keeper.warn
          "dashboard cascade config: validated catalog unavailable: %s"
          detail;
        let invalid_names = invalid_name_set config_path in
        let seen = ref StringSet.empty in
        let add_profile_name acc name =
          let canonical = Keeper_cascade_profile.canonicalize name in
          if StringSet.mem canonical invalid_names || StringSet.mem canonical !seen
          then acc
          else (
            seen := StringSet.add canonical !seen;
            canonical :: acc)
        in
        let acc_after_catalog =
          List.fold_left add_profile_name [] (live_profiles ?config_path ())
        in
        let names =
          List.fold_left
            (fun acc (e : Keeper_registry.registry_entry) ->
               add_profile_name acc e.meta.cascade_name)
            acc_after_catalog
            keeper_entries
          |> List.rev
        in
        List.map
          (profile_json_raw ~config_path ~keeper_assignable_names)
          names
  in
  let fields =
    [
      ("updated_at", `String (now_iso ()));
      ("config_path",
       match config_path with
       | Some p -> `String p
       | None -> `Null);
    ]
    @ source_json_fields source
    @ validation_summary_json ?config_path ()
    @ [
        ("profiles", `List profiles);
        ("keeper_profiles", `List (List.map keeper_profile_json keeper_entries));
      ]
  in
  `Assoc fields

let default_raw_config_json = "{}\n"

let load_raw_config_string path =
  if Fs_compat.file_exists path then
    Fs_compat.load_file path
  else
    default_raw_config_json

let invalidate_cascade_config config_path =
  Cascade_config_loader.invalidate_cache_entry config_path;
  Cascade_catalog_runtime.invalidate_path config_path

let save_config_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path content

let raw_config_json () =
  Config_dir_resolver.log_warnings ~context:"DashboardCascade" ();
  let source : Cascade_toml_materializer.source_info = source_info () in
  let config_path = Some source.json_path in
  let _ =
    Cascade_toml_materializer.ensure_materialized_json
      ~config_path:source.json_path
  in
  let source_text =
    try load_raw_config_string source.source_path with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Sys_error msg ->
        Log.Keeper.warn
          "dashboard cascade source config: failed to read %s: %s"
          source.source_path msg;
        ""
  in
  let raw_json =
    match config_path with
    | None -> ""
    | Some path -> (
        try load_raw_config_string path with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Sys_error msg ->
            Log.Keeper.warn
              "dashboard cascade raw config: failed to read %s: %s"
              path msg;
            "")
  in
  `Assoc
    [
      ("updated_at", `String (now_iso ()));
      ("config_path", Json_util.string_opt_to_json config_path);
      ( "source_kind",
        `String
          (Cascade_toml_materializer.source_kind_to_string source.kind) );
      ("source_path", `String source.source_path);
      ("source_editable", `Bool true);
      ("source_text", `String source_text);
      ("raw_json_editable", `Bool source.raw_json_editable);
      ("raw_json", `String raw_json);
    ]

let save_raw_config_json raw_json =
  Config_dir_resolver.log_warnings ~context:"DashboardCascade" ();
  let source : Cascade_toml_materializer.source_info = source_info () in
  let config_path = source.json_path in
  match source.kind with
  | Cascade_toml_materializer.Json ->
      let parse_result =
        try
          let (_ : Yojson.Safe.t) = Yojson.Safe.from_string raw_json in
          Ok ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Yojson.Json_error msg ->
            Error (Printf.sprintf "invalid JSON: %s" msg)
        | exn ->
            Error
              (Printf.sprintf "failed to parse JSON: %s" (Printexc.to_string exn))
      in
      (match parse_result with
       | Error _ as err -> err
       | Ok () -> (
           try
             match save_config_file config_path raw_json with
             | Error msg -> Error msg
             | Ok () ->
                 invalidate_cascade_config config_path;
                 Ok (config_json ())
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | Sys_error msg -> Error msg))
  | Cascade_toml_materializer.Toml -> (
      match Cascade_toml_materializer.render_toml_string_to_json_string raw_json with
      | Error msg ->
          Error (Printf.sprintf "invalid TOML: %s" msg)
      | Ok _rendered_json -> (
          try
            match save_config_file source.source_path raw_json with
            | Error msg -> Error msg
            | Ok () -> (
                match
                  Cascade_toml_materializer.ensure_materialized_json
                    ~config_path:config_path
                with
                | Error msg -> Error msg
                | Ok _ ->
                    invalidate_cascade_config config_path;
                    Ok (config_json ()))
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Sys_error msg -> Error msg))

(* ── Health projection ──────────────────────────────── *)

let provider_info_to_json (info : Health.provider_info) : Yojson.Safe.t =
  `Assoc [
    ("provider_key", `String info.provider_key);
    ("success_rate", `Float info.success_rate);
    ("consecutive_failures", `Int info.consecutive_failures);
    ("in_cooldown", `Bool info.in_cooldown);
    ("cooldown_expires_at",
     match info.cooldown_expires_at with
     | Some t -> `Float t
     | None -> `Null);
    ("events_in_window", `Int info.events_in_window);
    (* rejected_in_window ⊆ events_in_window: responses that arrived
       but were rejected by the cascade's accept predicate.  Split out
       so dashboards can distinguish "provider down" from "provider
       returns unusable output". *)
    ("rejected_in_window", `Int info.rejected_in_window);
  ]

let health_json () =
  let providers = Health.all_providers Health.global in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    (* Health tracker is the SSOT for these values; reading env here would
       diverge from what the tracker actually applied (e.g. if the operator
       sets a malformed value that falls back to the default, the tracker
       has the fallback but a second env read would pick up the malformed
       string). *)
    ("window_sec", `Float Health.window_sec);
    ("cooldown_threshold", `Int Health.cooldown_threshold);
    ("cooldown_sec", `Float Health.cooldown_sec);
    ("hard_quota_cooldown_sec", `Float Health.hard_quota_cooldown_sec);
    ("providers", `List (List.map provider_info_to_json providers));
  ]

(* ── Client capacity projection ─────────────────────── *)

(** Classify a capacity registry key for the dashboard.  Both sentinel
    predicates come from {!Masc_network_defaults}: CLI transports via
    {!Masc_network_defaults.is_cli_sentinel_url} (matches the [cli:]
    prefix) and ollama endpoints via
    {!Masc_network_defaults.is_ollama_url} (matches the well-known
    port).  Everything else is reported as [other] so operators can
    spot surprise registrations (e.g. a manually-registered HTTP
    slot). *)
let classify_capacity_key url =
  if Masc_network_defaults.is_cli_sentinel_url url then "cli"
  else if Masc_network_defaults.is_ollama_url url then "ollama"
  else "other"

let client_capacity_entry_to_json (url, info : string * Cascade_throttle.capacity_info)
  : Yojson.Safe.t =
  `Assoc [
    ("key", `String url);
    ("kind", `String (classify_capacity_key url));
    ("total", `Int info.total);
    ("active", `Int info.process_active);
    ("available", `Int info.process_available);
  ]

let client_capacity_json () =
  let entries = Cascade_client_capacity.snapshot () in
  (* Stable ordering by (kind, key) so the dashboard table doesn't
     reshuffle on every poll.  Hashtbl iteration is unordered, so we
     sort here rather than depend on insertion order. *)
  let sorted =
    List.sort
      (fun (k1, _) (k2, _) ->
         let c1 = classify_capacity_key k1 in
         let c2 = classify_capacity_key k2 in
         match String.compare c1 c2 with
         | 0 -> String.compare k1 k2
         | n -> n)
      entries
  in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("entries", `List (List.map client_capacity_entry_to_json sorted));
  ]

(* ── Client capacity history projection ─────────────────── *)

let event_kind_to_string = function
  | Cascade_client_capacity_history.Acquired -> "acquired"
  | Released -> "released"
  | Rejected_full -> "rejected_full"

let history_event_to_json (ev : Cascade_client_capacity_history.event)
  : Yojson.Safe.t =
  `Assoc [
    ("ts", `Float ev.ts);
    ("key", `String ev.key);
    ("kind", `String (event_kind_to_string ev.kind));
    ("active_after", `Int ev.active_after);
  ]

let client_capacity_history_json ?limit ?kind ?since_ts () =
  let events =
    Cascade_client_capacity_history.snapshot ?limit ?kind ?since_ts ()
  in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("total_events", `Int (List.length events));
    ("events", `List (List.map history_event_to_json events));
  ]

let strategy_trace_event_to_json (ev : Cascade_strategy_trace.event)
  : Yojson.Safe.t =
  `Assoc [
    ("ts", `Float ev.ts);
    ("cascade_name", `String ev.cascade_name);
    ("strategy", `String ev.strategy);
    ("cycle", `Int ev.cycle);
    ("candidates_in", `Int ev.candidates_in);
    ("candidates_out", `Int ev.candidates_out);
    ("backoff_ms", `Int ev.backoff_ms);
    ("kind", `String (Cascade_strategy_trace.kind_to_string ev.kind));
  ]

let strategy_trace_json ?limit ?cascade () =
  let events = Cascade_strategy_trace.snapshot ?limit ?cascade () in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("total_events", `Int (List.length events));
    ("events", `List (List.map strategy_trace_event_to_json events));
  ]

(* ── SLO projection (LT-11) ─────────────────────────────────

   Targets mirror infrastructure/monitoring/cascade-slo.yml.  Computed
   in-process from the live Cascade_strategy_trace ring so the MASC
   dashboard can render SLO status without reaching Prometheus. *)

let slo_sample_limit = 1000
let slo_target_ordered_ratio = 0.99
let slo_target_exhaustion_count = 10
let slo_target_burn_rate = 1.0

let compute_slo_counts (events : Cascade_strategy_trace.event list) =
  List.fold_left
    (fun (total, ordered, exhausted) (ev : Cascade_strategy_trace.event) ->
       match ev.kind with
       | Ordered -> (total + 1, ordered + 1, exhausted)
       | Filtered_empty -> (total + 1, ordered, exhausted)
       | Exhausted -> (total + 1, ordered, exhausted + 1))
    (0, 0, 0) events

let slo_json () =
  let events = Cascade_strategy_trace.snapshot ~limit:slo_sample_limit () in
  let total, ordered, exhausted = compute_slo_counts events in
  let ordered_ratio =
    if total = 0 then 1.0
    else float_of_int ordered /. float_of_int total
  in
  let burn_rate = (1.0 -. ordered_ratio) /. 0.01 in
  let ratio_violated = ordered_ratio < slo_target_ordered_ratio in
  let exhaustion_violated = exhausted > slo_target_exhaustion_count in
  let burn_violated = burn_rate > slo_target_burn_rate in
  let violations =
    List.filter_map (fun (name, violated) ->
      if violated then Some (`String name) else None)
      [
        "ordered_ratio", ratio_violated;
        "exhaustion_count", exhaustion_violated;
        "burn_rate", burn_violated;
      ]
  in
  let status =
    if ratio_violated || exhaustion_violated then "violated"
    else if burn_violated then "warn"
    else "ok"
  in
  `Assoc [
    "updated_at", `String (now_iso ());
    "window_sample_size", `Int slo_sample_limit;
    "targets", `Assoc [
      "ordered_ratio_min", `Float slo_target_ordered_ratio;
      "exhaustion_count_max", `Int slo_target_exhaustion_count;
      "burn_rate_max", `Float slo_target_burn_rate;
    ];
    "current", `Assoc [
      "ordered_ratio", `Float ordered_ratio;
      "exhaustion_count", `Int exhausted;
      "burn_rate", `Float burn_rate;
      "total_events", `Int total;
    ];
    "status", `String status;
    "violations", `List violations;
  ]
