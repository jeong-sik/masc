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
    (* Health tracker is the SSOT for these values; reading env here would
       diverge from what the tracker actually applied (e.g. if the operator
       sets a malformed value that falls back to the default, the tracker
       has the fallback but a second env read would pick up the malformed
       string). *)
    ("window_sec", `Float Health.window_sec);
    ("cooldown_threshold", `Int Health.cooldown_threshold);
    ("cooldown_sec", `Float Health.cooldown_sec);
    ("providers", `List (List.map provider_info_to_json providers));
  ]

(* ── Client capacity projection ─────────────────────── *)

(** Classify a capacity registry key for the dashboard.  CLI sentinels
    use the [cli:] prefix; ollama uses the well-known [:11434] port.
    Everything else is reported as [other] so operators can spot
    surprise registrations (e.g. a manually-registered HTTP slot). *)
let classify_capacity_key url =
  if String.length url > 4 && String.sub url 0 4 = "cli:" then "cli"
  else
    let len = String.length url in
    let needle = ":11434" in
    let nlen = String.length needle in
    let rec scan i =
      if i + nlen > len then false
      else if String.sub url i nlen = needle then true
      else scan (i + 1)
    in
    if scan 0 then "ollama" else "other"

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
