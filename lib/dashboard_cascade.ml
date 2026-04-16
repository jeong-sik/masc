(** Dashboard projection for cascade configuration and runtime health. *)

module CC = Cascade_config
module Health = Cascade_health_tracker

(* ── Shared helpers ─────────────────────────────────── *)

let now_iso () = Types.now_iso ()

let candidate_to_json (c : CC.candidate_info) : Yojson.Safe.t =
  `Assoc [
    ("model", `String c.model_string);
    ("config_weight", `Int c.config_weight);
    ("effective_weight", `Int c.effective_weight);
    ("success_rate", `Float c.success_rate);
    ("in_cooldown", `Bool c.in_cooldown);
  ]

let source_to_string = function
  | CC.Named -> "named"
  | CC.Default_fallback -> "default_fallback"
  | CC.Hardcoded_defaults -> "hardcoded_defaults"

(* ── Config projection ──────────────────────────────── *)

(** Profiles to surface in the dashboard.

    We don't try to enumerate every possible profile name the loader might
    accept — the dashboard cares about the profiles that keepers actively use,
    plus a few standard ones. Listing them explicitly avoids loading the raw
    JSON and reimplementing key-name heuristics.

    Keepers run through [Keeper_cascade_profile.canonicalize], so any unknown
    keeper [cascade_name] from the registry also shows up below by virtue of
    being included in [keeper_profiles]. *)
let standard_profiles = Keeper_cascade_profile.known_cascades

let profile_json ~config_path name =
  let defaults = Cascade_runtime.default_model_strings ~cascade_name:name in
  let (_models, trace) =
    CC.resolve_model_strings_with_trace ?config_path ~name ~defaults ()
  in
  `Assoc [
    ("name", `String name);
    ("source", `String (source_to_string trace.source));
    ("candidates", `List (List.map candidate_to_json trace.candidates));
  ]

let keeper_profile_json (entry : Keeper_registry.registry_entry) : Yojson.Safe.t =
  `Assoc [
    ("keeper", `String entry.name);
    ("cascade_name", `String entry.meta.cascade_name);
    ("canonical", `String (Keeper_cascade_profile.canonicalize entry.meta.cascade_name));
  ]

let config_json () =
  let config_path = Cascade_runtime.cascade_config_path () in
  let seen = Hashtbl.create 16 in
  let add_profile acc name =
    let canonical = Keeper_cascade_profile.canonicalize name in
    if Hashtbl.mem seen canonical then acc
    else begin
      Hashtbl.add seen canonical ();
      profile_json ~config_path canonical :: acc
    end
  in
  (* Start with the standard profiles, then append any runtime-drifted
     keeper cascade_name values (e.g. a keeper TOML pointing at a
     non-standard profile). Both paths go through [add_profile] so
     duplicates are filtered by canonical name. *)
  let keeper_entries =
    try Keeper_registry.all () with _ -> []
  in
  let acc_after_standard =
    List.fold_left add_profile [] standard_profiles
  in
  let acc_after_keepers =
    List.fold_left
      (fun acc (e : Keeper_registry.registry_entry) ->
         add_profile acc e.meta.cascade_name)
      acc_after_standard
      keeper_entries
  in
  let profiles = List.rev acc_after_keepers in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("config_path",
     match config_path with
     | Some p -> `String p
     | None -> `Null);
    ("profiles", `List profiles);
    ("keeper_profiles", `List (List.map keeper_profile_json keeper_entries));
  ]

(* ── Health projection ──────────────────────────────── *)

let float_env ~default key =
  match Sys.getenv_opt key with
  | Some s -> (try Float.of_string s with _ -> default)
  | None -> default

let int_env ~default key =
  match Sys.getenv_opt key with
  | Some s -> (try int_of_string s with _ -> default)
  | None -> default

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
  ]

let health_json () =
  let providers = Health.all_providers Health.global in
  `Assoc [
    ("updated_at", `String (now_iso ()));
    ("window_sec",
     `Float (float_env ~default:300.0 "OAS_CASCADE_HEALTH_WINDOW_SEC"));
    ("cooldown_threshold",
     `Int (int_env ~default:3 "OAS_CASCADE_COOLDOWN_THRESHOLD"));
    ("cooldown_sec",
     `Float (float_env ~default:60.0 "OAS_CASCADE_COOLDOWN_SEC"));
    ("providers", `List (List.map provider_info_to_json providers));
  ]
